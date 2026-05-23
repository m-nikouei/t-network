# Persistent /rw/config for the sys-split proxy.
# Apply INSIDE the proxy, then restart it:
#   sudo qubesctl --skip-dom0 --targets=sys-split state.apply t-network.config
#   qvm-shutdown --wait sys-split && qvm-start sys-split
{% for f, mode in [('torrc', '0644'), ('rc.local', '0755'), ('qubes-firewall-user-script', '0755')] %}
/rw/config/{{ f }}:
  file.managed:
    - source: salt://t-network/files/{{ f }}
    - user: root
    - group: root
    - mode: '{{ mode }}'
{% endfor %}
# NOTE: /rw/config/wg0.conf is your ProtonVPN secret. Install it by hand
# (qvm-copy from agent-staging, then chmod 600). NEVER manage it in Salt.
