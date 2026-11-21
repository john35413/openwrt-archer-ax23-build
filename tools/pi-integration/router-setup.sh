#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Run ON THE ROUTER once the base system is validated:
#   scp router-setup.sh pi-monitor.acl.json root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/router-setup.sh "<pi pubkey line>"'
# Creates:
#  * rpcd login "pi-monitor" limited to the read-only ubus calls in
#    pi-monitor.acl.json (no uci write, no file write, no exec)
#  * a backup-only SSH key: forced command `sysupgrade -b -`, no PTY,
#    no forwarding; dropbear listens on the LAN interface only
# Nothing is exposed on WAN: fw4's wan zone rejects input; uhttpd/dropbear
# are additionally bound to the LAN address.
set -eu
PUB="${1:?usage: router-setup.sh '<ssh-ed25519 AAAA... pi>'}"
install -m 0644 /tmp/pi-monitor.acl.json /usr/share/rpcd/acl.d/pi-monitor.json
PW=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
HASH=$(uhttpd -m "$PW")
uci -q delete rpcd.pi_monitor || true
uci set rpcd.pi_monitor=login
uci set rpcd.pi_monitor.username='pi-monitor'
uci set rpcd.pi_monitor.password="$HASH"
uci add_list rpcd.pi_monitor.read='pi-monitor'
uci commit rpcd
/etc/init.d/rpcd restart
# bind web/ssh to LAN only
LANIP=$(uci get network.lan.ipaddr)
uci set uhttpd.main.listen_http="$LANIP:80"
uci -q delete uhttpd.main.listen_https || true
uci commit uhttpd; /etc/init.d/uhttpd restart
uci set dropbear.@dropbear[0].Interface='lan'; uci commit dropbear
K=/etc/dropbear/authorized_keys
grep -v ' pi-backup$' "$K" 2>/dev/null > "$K.new" || true
# Dropbear does not implement OpenSSH's from="..." option (an unknown
# option invalidates the line), so source restriction is the LAN-only
# dropbear binding plus fw4, not the key line.
echo "command=\"sysupgrade -b -\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ${PUB% *} pi-backup" >> "$K.new"
mv "$K.new" "$K"; chmod 600 "$K"
echo "rpcd user: pi-monitor"
echo "rpcd password (store it on the Pi in ~/.config/ax23/rpc.pass, mode 600): $PW"
