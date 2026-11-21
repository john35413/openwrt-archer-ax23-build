#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs on the Pi (systemd timer / cron). Pulls a config backup through the
# forced-command key installed by router-setup.sh and keeps the last N.
set -euo pipefail
ROUTER="${ROUTER:-192.168.1.1}"; KEY="${KEY:-$HOME/.ssh/ax23_backup}"
DIR="${DIR:-$HOME/router-backups}"; KEEP="${KEEP:-30}"
mkdir -p "$DIR"; chmod 700 "$DIR"
f="$DIR/ax23-$(date +%Y%m%d-%H%M%S).tar.gz"
ssh -i "$KEY" -o BatchMode=yes "root@$ROUTER" >"$f.part"   # forced command: sysupgrade -b -
gzip -t "$f.part" && tar -tzf "$f.part" >/dev/null && mv "$f.part" "$f"
chmod 600 "$f"; ls -1t "$DIR"/ax23-*.tar.gz | tail -n +"$((KEEP+1))" | xargs -r rm --
echo "saved $f"
