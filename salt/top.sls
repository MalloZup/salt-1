base:
  '*':
    - repositories
    - motd
    - users
{% if salt['pillar.get']('infrastructure', 'libvirt') == 'cloud' %}
    - hosts
{% endif %}
  'roles:ca':
    - match: grain
    - ca
  'roles:kube-(master|minion)':
    - match: grain_pcre
    - cert
    - etcd-proxy
  'roles:kube-master':
    - match: grain
    - kubernetes-master
    - flannel
    - docker
    - reboot
  'roles:kube-minion':
    - match: grain
    - flannel
    - docker
    - kubernetes-minion
