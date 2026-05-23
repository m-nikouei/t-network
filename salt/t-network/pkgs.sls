# Packages for the split-proxy template.
# Apply INSIDE the template (it has the Qubes update proxy):
#   sudo qubesctl --skip-dom0 --targets=t-split state.apply t-network.pkgs
#   qvm-shutdown --wait t-split
split-proxy-packages:
  pkg.installed:
    - pkgs:
      - tor
      - wireguard
      - nftables

tor-not-autostarted:
  service.disabled:
    - name: tor
    - require:
      - pkg: split-proxy-packages
