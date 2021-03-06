{#- Get a list of nodes seem to be down or unresponsive #}
{#- This sends a "are you still there?" message to all #}
{#- the nodes and wait for a response, so it takes some time. #}
{#- Hopefully this list will not be too long... #}
{%- set nodes_down = salt.saltutil.runner('manage.down') %}
{%- if nodes_down|length >= 1 %}
# {{ nodes_down|join(',') }} seem to be down: skipping
  {%- do salt.caasp_log.debug('CaaS: nodes "%s" seem to be down: ignored', nodes_down|join(',')) %}
  {%- set is_responsive_node_tgt = 'not L@' + nodes_down|join(',') %}
{%- else %}
# all nodes seem to be up
  {%- do salt.caasp_log.debug('CaaS: all nodes seem to be up') %}
  {#- we cannot leave this empty (it would produce many " and <empty>" targets) #}
  {%- set is_responsive_node_tgt = '*' %}
{%- endif %}

{#- some other targets: #}

{#- the regular nodes (ie, not the CA or the admin node) #}
{%- set is_regular_node_tgt = 'P@roles:(etcd|kube-(master|minion))' + ' and ' + is_responsive_node_tgt %}
{#- machines that need to be updated #}
{%- set is_updateable_tgt = 'G@tx_update_reboot_needed:true' %}

{#- all the other nodes classes #}
{#- (all of them are required to be responsive nodes) #}
{%- set is_etcd_tgt              = is_responsive_node_tgt + ' and G@roles:etcd' %}
{%- set is_master_tgt            = is_responsive_node_tgt + ' and G@roles:kube-master' %}
{%- set is_worker_tgt            = is_responsive_node_tgt + ' and G@roles:kube-minion' %}
{%- set is_updateable_master_tgt = is_updateable_tgt + ' and ' + is_master_tgt %}
{%- set is_updateable_worker_tgt = is_updateable_tgt + ' and ' + is_worker_tgt %}
{%- set all_masters = salt.saltutil.runner('mine.get', tgt=is_master_tgt, fun='network.interfaces', tgt_type='compound').keys() %}
{%- set super_master = all_masters|first %}

# Ensure all nodes with updates are marked as upgrading. This will reduce the time window in which
# the update-etc-hosts orchestration can run in between machine restarts.
set-update-grain:
  salt.function:
    - tgt: '( {{ is_regular_node_tgt }} and {{ is_updateable_tgt }} ) or {{ super_master }}'
    - tgt_type: compound
    - name: grains.setval
    - arg:
      - update_in_progress
      - true

# this will load the _pillars/velum.py on the master
sync-pillar:
  salt.runner:
    - name: saltutil.sync_pillar
    - require:
      - set-update-grain

update-data:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - names:
      - saltutil.refresh_pillar
      - saltutil.refresh_grains
      - mine.update
    - require:
      - sync-pillar

update-modules:
  salt.function:
    - name: saltutil.sync_all
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - kwarg:
        refresh: True
    - require:
      - update-data

# Generate sa key (we should refactor this as part of the ca highstate along with its counterpart
# in orch/kubernetes.sls)
generate-sa-key:
  salt.state:
    - tgt: 'roles:ca'
    - tgt_type: grain
    - sls:
      - kubernetes-common.generate-serviceaccount-key
    - require:
      - update-modules

admin-apply-haproxy:
  salt.state:
    - tgt: 'roles:admin'
    - tgt_type: grain
    - batch: 1
    - sls:
      - etc-hosts
      - haproxy
    - require:
      - generate-sa-key

admin-setup:
  salt.state:
    - tgt: 'roles:admin'
    - tgt_type: grain
    - highstate: True
    - require:
      - admin-apply-haproxy

# Perform any migrations necessary before starting the update orchestration. All services and
# machines should be running and we can migrate some data on the whole cluster and then proceed
# with the real update.
pre-orchestration-migration:
  salt.state:
    - tgt: '{{ is_regular_node_tgt }}'
    - tgt_type: compound
    - batch: 3
    - sls:
      - cni.update-pre-orchestration
      - kubelet.update-pre-orchestration
      - etcd.update-pre-orchestration
    - require:
      - admin-setup

# NOTE: Remove me for 4.0
#
# During an upgrade from 2.0 to 3.0, as we go master by master first, the first master will not
# succeed on the orchestration if it doesn't have an etcd member. Assume M{1,2,3}, W{1,2}. Assume
# etcd members are running on M2, W1 and W2.
#
# M1 updates its configurations on highstate and refers to the etcd nodes with the new names
# (hostnames) instead of machine-ids, but M2, W1 and W2 still didn't run anything to refresh their
# certificates and their etcd instances, what will make M1 fail because it cannot connect to any
# etcd instance (as all certificates look invalid at this point for M2.hostname, W1.hostname and
# W2.hostname). This makes the apiserver on M1 fail restarting itself until the orchestration reaches
# M2 [there's no hard dependency on states between masters], but the orchestration already failed on
# M1, so the global result will be failure nevertheless.
#
# Let's force etcd to refresh certificates on all machines, restarting the etcd service so we can
# continue with the upgrade, as certificates will be valid for the old and the new SAN.
etcd-setup:
  salt.state:
    - tgt: '{{ is_etcd_tgt }}'
    - tgt_type: compound
    - sls:
      - etcd
    - batch: 1
    - require:
      - pre-orchestration-migration
# END NOTE

# Get list of masters needing reboot
{%- set masters = salt.saltutil.runner('mine.get', tgt=is_updateable_master_tgt, fun='network.interfaces', tgt_type='compound') %}
{%- for master_id in masters.keys() %}

{{ master_id }}-clean-shutdown:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - container-feeder.stop
      - kube-apiserver.stop
      - kube-controller-manager.stop
      - kube-scheduler.stop
      - cri.stop
      - etcd.stop
    - require:
        - etcd-setup

# Perform any migratrions necessary before services are shutdown
{{ master_id }}-pre-reboot:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - etc-hosts.update-pre-reboot
      - cni.update-pre-reboot
      - etcd.update-pre-reboot
    - require:
      - {{ master_id }}-clean-shutdown

# Reboot the node
{{ master_id }}-reboot:
  salt.function:
    - tgt: '{{ master_id }}'
    - name: cmd.run
    - arg:
      - sleep 15; systemctl reboot
    - kwarg:
        bg: True
    - require:
      - {{ master_id }}-pre-reboot

# Wait for it to start again
{{ master_id }}-wait-for-start:
  salt.wait_for_event:
    - name: salt/minion/*/start
    - timeout: 1200
    - id_list:
      - {{ master_id }}
    - require:
      - {{ master_id }}-reboot

# Perform any migratrions necessary before salt starts doing
# "real work" again
{{ master_id }}-post-reboot:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - etc-hosts.update-post-reboot
    - require:
      - {{ master_id }}-wait-for-start

# Early apply haproxy configuration
{{ master_id }}-apply-haproxy:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - haproxy
    - require:
      - {{ master_id }}-post-reboot

# Start services
{{ master_id }}-start-services:
  salt.state:
    - tgt: '{{ master_id }}'
    - highstate: True
    - require:
      - {{ master_id }}-apply-haproxy

# Perform any migratrions after services are started
{{ master_id }}-post-start-services:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - cni.update-post-start-services
      - kubelet.update-post-start-services
    - require:
      - {{ master_id }}-start-services

{{ master_id }}-reboot-needed-grain:
  salt.function:
    - tgt: '{{ master_id }}'
    - name: grains.delval
    - arg:
      - tx_update_reboot_needed
    - kwarg:
        destructive: True
    - require:
      - {{ master_id }}-post-start-services

{% endfor %}

{%- set workers = salt.saltutil.runner('mine.get', tgt=is_updateable_worker_tgt, fun='network.interfaces', tgt_type='compound') %}
{%- for worker_id, ip in workers.items() %}

# Call the node clean shutdown script
{{ worker_id }}-clean-shutdown:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - container-feeder.stop
      - kubelet.stop
      - kube-proxy.stop
      - cri.stop
      - etcd.stop
    - require:
      - pre-orchestration-migration
      # wait until all the masters have been updated
{%- for master_id in masters.keys() %}
      - {{ master_id }}-reboot-needed-grain
{%- endfor %}

# Perform any migrations necessary before rebooting
{{ worker_id }}-pre-reboot:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - etc-hosts.update-pre-reboot
      - cni.update-pre-reboot
    - require:
      - {{ worker_id }}-clean-shutdown

# Reboot the node
{{ worker_id }}-reboot:
  salt.function:
    - tgt: '{{ worker_id }}'
    - name: cmd.run
    - arg:
      - sleep 15; systemctl reboot
    - kwarg:
        bg: True
    - require:
      - {{ worker_id }}-pre-reboot

# Wait for it to start again
{{ worker_id }}-wait-for-start:
  salt.wait_for_event:
    - name: salt/minion/*/start
    - timeout: 1200
    - id_list:
      - {{ worker_id }}
    - require:
      - {{ worker_id }}-reboot

# Perform any migratrions necessary before salt starts doing
# "real work" again
{{ worker_id }}-post-reboot:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - etc-hosts.update-post-reboot
    - require:
      - {{ worker_id }}-wait-for-start

# Early apply haproxy configuration
{{ worker_id }}-apply-haproxy:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - haproxy
    - require:
      - {{ worker_id }}-post-reboot

# Start services
{{ worker_id }}-start-services:
  salt.state:
    - tgt: '{{ worker_id }}'
    - highstate: True
    - require:
      - salt: {{ worker_id }}-apply-haproxy

# Perform any migratrions after services are started
{{ worker_id }}-update-post-start-services:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - cni.update-post-start-services
      - kubelet.update-post-start-services
    - require:
      - {{ worker_id }}-start-services

{{ worker_id }}-update-reboot-needed-grain:
  salt.function:
    - tgt: '{{ worker_id }}'
    - name: grains.delval
    - arg:
      - tx_update_reboot_needed
    - kwarg:
        destructive: True
    - require:
      - {{ worker_id }}-update-post-start-services

# Ensure the node is marked as finished upgrading
{{ worker_id }}-remove-update-grain:
  salt.function:
    - tgt: '{{ worker_id }}'
    - name: grains.delval
    - arg:
      - update_in_progress
    - kwarg:
        destructive: True
    - require:
      - {{ worker_id }}-update-reboot-needed-grain

{% endfor %}

# At this point in time, all workers have been removed the `update_in_progress` grain, so the
# update-etc-hosts orchestration can potentially run on them. We need to keep the masters locked
# (at least the one that we will use to run other tasks in [super_master]). In any case, for the
# sake of simplicity we keep all of them locked until the very end of the orchestration, when we'll
# release all of them (removing the `update_in_progress` grain).

kubelet-setup:
  salt.state:
    - tgt: '{{ is_regular_node_tgt }}'
    - tgt_type: compound
    - sls:
      - kubelet.configure-taints
      - kubelet.configure-labels
    - require:
      - pre-orchestration-migration
# wait until all the machines in the cluster have been upgraded
{%- for master_id in masters.keys() %}
      # We use the last state within the masters loop, which is different
      # on masters and minions.
      - {{ master_id }}-reboot-needed-grain
{%- endfor %}
{%- for worker_id in workers.keys() %}
      - {{ worker_id }}-remove-update-grain
{%- endfor %}

# (re-)apply all the manifests
# this will perform a rolling-update for existing daemonsets
services-setup:
  salt.state:
    - tgt: '{{ super_master }}'
    - sls:
      - addons
      - addons.psp
      - cni
      - addons.dns
      - addons.tiller
      - addons.dex
    - require:
      - kubelet-setup

# Wait for deployments to have the expected number of pods running.
super-master-wait-for-services:
  salt.state:
    - tgt: {{ super_master }}
    - sls:
      - addons.dns.deployment-wait
      - addons.tiller.deployment-wait
      - addons.dex.deployment-wait
    - require:
      - services-setup

# Velum will connect to dex through the local haproxy instance in the admin node (because the
# /etc/hosts include the external apiserver pointing to 127.0.0.1). Make sure that before calling
# the orchestration done, we can access dex from the admin node as Velum would do.
admin-wait-for-services:
  salt.state:
    - tgt: 'roles:admin'
    - tgt_type: grain
    - batch: 1
    - sls:
      - addons.dex.wait
    - require:
      - super-master-wait-for-services

# Remove the now defuct caasp_fqdn grain (Remove for 4.0).
remove-caasp-fqdn-grain:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - name: grains.delval
    - arg:
      - caasp_fqdn
    - kwarg:
        destructive: True
    - require:
      - admin-wait-for-services

remove-update-grain:
  salt.function:
    - tgt: 'update_in_progress:true'
    - tgt_type: grain
    - name: grains.delval
    - arg:
      - update_in_progress
    - kwarg:
        destructive: True
    - require:
      - remove-caasp-fqdn-grain
