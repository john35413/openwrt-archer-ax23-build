# Raspberry Pi integration and validation

Labels as in `wifi-root-cause.md`. The owner has a Raspberry Pi running real
services (OASA Live, Pi-hole/DNS, Tailscale, Docker containers). This report states
exactly what was done, what is **blocked** and why, and how the Pi is used safely —
without touching any of those services.

## 1. Status: BLOCKED on hardware, design + offline checks complete

**No Raspberry Pi is attached to this environment** (cloud container; the owner's Pi
is on their own network). Therefore:
- **No command has been run on the owner's Pi.** Everything below is design,
  static-checked scripts, and a plan. **UNVERIFIED on the Pi.**
- Nothing here connects to, scans, or probes the Pi or the owner's network. Any
  execution happens only when the owner runs the scripts themselves, over an
  existing authorized SSH session, after reading them.

This honours every Pi constraint the owner set: do not stop Docker containers, do
not modify OASA Live / Pi-hole / DNS / Tailscale / firewall / routes, do not reboot,
do not change boot config, do not install global packages without approval, do not
overwrite files, do not use the Pi's system disk, exclude secrets from reports.

## 2. What the Pi is for (two independent, least-privilege roles)

### 2.1 Router **monitor** (read-only, pull)
`tools/pi-integration/ax23-monitor.py` runs **on the Pi** and polls the router's ubus
JSON-RPC over the **LAN only** using a dedicated rpcd login `pi-monitor` whose ACL
(`pi-monitor.acl.json`) grants **only read** ubus calls (system/board, network
status, wireless status, `/proc` meminfo via a read method) — **no `uci` write, no
file write, no exec**. It reports MemAvailable, OOM count, radio/trunk state and
optional ntfy alerts. **Static-checked offline** (`ax23-monitor.py` parses;
`router-setup.sh`/`backup-router.sh` pass shellcheck).

Why this is Pi-side and safe: the **router** is the device under test; the Pi is an
**observer**. The monitor cannot change the router (read-only ACL) and does nothing
to the Pi beyond running one Python process the owner starts. It writes only under
`~/.config/ax23/` on the Pi (a path the owner creates), never the system disk.

### 2.2 Router **backup** (pull, forced-command key)
`tools/pi-integration/backup-router.sh` on the Pi pulls a sysupgrade backup from the
router via an SSH key whose **router-side** `authorized_keys` entry is pinned to a
**forced command** (`sysupgrade -b -`), no PTY, no forwarding. The key can do nothing
on the router but emit a backup tarball. Backups are stored under a Pi directory the
owner chooses. This backs up **OpenWrt config**, not flash partitions (flash backup
is the read-only `tests/hardware/backup-flash-ro.sh`, run from a PC during bring-up).

### 2.3 Optional: Pi as **TFTP server for the UART RAM boot**
During bring-up the Pi can serve the RAM-boot `.itb` over TFTP
(`dnsmasq --enable-tftp` **in a throwaway config**, or a userspace TFTP in a
container the owner starts) on the **bring-up LAN only**. This must **not** change the
Pi's existing dnsmasq/Pi-hole: use a separate interface/subnet or a temporary
container, never edit the running Pi-hole config. Documented as owner-run, not
automated.

## 3. Isolation: the Pi lives on the IoT VLAN, not the LAN

The guest/IoT profile (`configs/uci/10-guest-iot-networks.uci`, twin test W26) puts
home-automation / IoT devices on `br-iot` (192.168.30.0/24), isolated from guest and
(optionally) reachable from LAN. The twin verifies **"LAN can reach IoT device (e.g.
Pi home automation)"** (W26 PASS) while **guest cannot reach LAN/router** (W22/W23).
So the Pi's services can run on a segregated VLAN with only the access the owner
wants. **SIM** (twin); the real switch VLAN isolation is a hardware acceptance item
(`ethernet-nat-validation.md` §4).

## 4. What must happen on real hardware (owner-run, in order)
1. Owner confirms an existing authorized SSH session to the Pi (we never fetch or
   store Pi credentials).
2. Owner reads `tools/pi-integration/*` and runs `router-setup.sh` **on the router**
   (not the Pi) to create the read-only `pi-monitor` login and the forced-command
   backup key. This changes the **router**, which is the device under test, not the
   Pi's services.
3. Owner starts `ax23-monitor.py` on the Pi under their own user, writing only to
   `~/.config/ax23/` — no global package install (its only deps are Python 3 stdlib;
   `requests` optional, else urllib). If a package is needed the owner approves it.
4. Backups land in an owner-chosen Pi directory with free-space checked first; the
   script refuses if the target is low on space (no excessive disk use).
5. None of OASA Live, Pi-hole, DNS, Tailscale, Docker, firewall or routes is touched;
   the monitor only **reads** the router and **writes** its own small state dir.

## 5. Verdict
- **Design + offline checks: complete.** Scripts are least-privilege (read-only ACL,
  forced-command key, LAN-only binding) and pass static analysis.
- **Hardware validation: BLOCKED** — requires the owner's Pi, which is correctly not
  reachable from here, and must be done by the owner over their own authorized
  session. No step requires modifying the Pi's existing services; the heavy lifting
  (device under test) is the router, not the Pi.
