# dom0 structure: the proxy, the untrusted agent, the offline vault + staging, and
# the qrexec data policy. Prerequisite (run once, then highstate):
#   qvm-clone debian-13-xfce t-split
# Apply:
#   sudo qubesctl state.apply t-network.dom0

sys-split:
  qvm.present:
    - template: t-split
    - label: red
  qvm.prefs:
    - provides_network: true
    - netvm: sys-firewall
    - maxmem: 1024
    - memory: 600
    - require:
      - qvm: sys-split

agent-vm:
  qvm.present:
    - template: debian-13-xfce
    - label: orange
  qvm.prefs:
    - netvm: sys-split
    - require:
      - qvm: agent-vm
      - qvm: sys-split

# Offline vault for extracted data (netvm: "" means no network).
agent-out:
  qvm.present:
    - template: debian-13-xfce
    - label: black
  qvm.prefs:
    - netvm: ""
    - require:
      - qvm: agent-out

# Offline staging qube for authoring agent inputs (e.g. task JSON).
agent-staging:
  qvm.present:
    - template: debian-13-xfce
    - label: gray
  qvm.prefs:
    - netvm: ""
    - require:
      - qvm: agent-staging

/etc/qubes/policy.d/30-agent-data.policy:
  file.managed:
    - source: salt://t-network/files/30-agent-data.policy
    - user: root
    - group: root
    - mode: '0644'
