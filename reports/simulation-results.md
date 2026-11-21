# Simulation and offline test results

**Everything in this file is offline: simulation, static analysis or emulation.
None of it shows that the physical AX23 v2 works.** QEMU and network
namespaces do not emulate the IPQ5018, its radios or Q6 firmware, the
RTL8367S-VB switch, the 2.5G UNIPHY trunk or the NAND/U-Boot.

Run it all with `./tools/test-dev.sh`. Raw logs: `logs/test-*.log`, `logs/network/`.

## 1. Build reproduction (static)

| Variant | Result | Evidence |
|---|---|---|
| baseline (Sply-Dev `93028b4` on OpenWrt `98b1185`) | PASS: builds from scratch with pinned feeds | `logs/baseline/`, `artifacts/ram-only/baseline/{SHA256SUMS,BUILDINFO}` |
| dev (baseline + 9 patches) | see `artifacts/ram-only/dev/BUILDINFO` and `reports/artifacts-dev.txt` | `logs/dev/` |

Problems found and fixed while reproducing the build: GNU tar refuses to configure as root
(`FORCE_UNSAFE_CONFIGURE=1`); `docs/BUILD.md`'s `patch -p1` step for the 777 series is wrong
(the patches must be copied into `pending-6.18`); and two bugs in my own pipeline (an `errexit`
that was ignored inside `if`, and a premature DTB check), both fixed.

Determinism: the staged commit's SHA differs between runs because it embeds the commit time,
but its tree content is identical. Image checksums depend on `SOURCE_DATE_EPOCH`, which comes from
the OpenWrt commit, so rebuilding the same tree should give the same images. **A bit-for-bit
second-machine rebuild has not been performed.**

## 2. Artifact validation (`tools/validate-artifacts.sh`)

Baseline (`reports/artifacts-baseline.txt`): FIT has `config@mp02.1`; load address 0x41000000;
decompressed kernel 22.8 MB, well below the 48 MiB gap to the FIT at 0x44000000; FIT below the
Q6 region; DTB extracted; partition map, read-only flags, both radios, FW memory mode 2, PD2,
BDF addresses inside `q6_region`, switch and 2500base-x all PASS. **FAIL: Wi-Fi LED triggers
reversed (D3, a baseline defect).** Board data ABSENT, so Wi-Fi is BLOCKED (the same `-12` as
on hardware). No sysupgrade interlock.

## 3. Unit tests

| Test | Result | What it shows |
|---|---|---|
| `test_tools.py` (12 cases) | PASS | board-2.bin parse/pack/lookup in ath11k name order; `NAME=FILE` with `=` inside names (a real packer bug, found and fixed); U-Boot env CRC/size detection; DTB checker catches writable ART and overlapping partitions |
| `test_caldata_regdomain.sh` | PASS | **base caldata.sh: bug reproduced** (all 5 words zeroed); patched: only the regdomain words are cleared |
| `test_mac_derivation.sh` | PASS | OpenWrt's `get_mac_binary`/`macaddr_add` give lan=base, wan=+1, 2G=−1, 5G=−2, with byte carry and borrow; a missing file gives no MAC |
| `test_bdf_extract.sh` | PASS | synthetic UBI→squashfs stock-slot image: the extractor refuses to choose between regional copies and packs the chosen EU file under the exact AX23 name |

## 4. Static checks (`tests/static/run-static.sh`)

Shell syntax and shellcheck (warning level and above) clean on all project scripts; Python
byte-compiles; the dev series applies with `git am` on the staged baseline; all modified OpenWrt
board scripts pass `sh -n`; no `.orig`/`.rej` leftovers; DTB checks on the built DTBs.

## 5. Emulated userspace: the image's own scripts under qemu-user

`tests/network/gen-fw4-ruleset.sh` runs the **built aarch64 rootfs** in a chroot via qemu-user:

| Step | Result |
|---|---|
| `/bin/board_detect` (runs the AX23 `board.d` scripts) | PASS: board.json produced |
| `/bin/config_generate` | PASS: `br-lan` ports `lan1 lan2 lan3 lan4`, `wan` device `wan` |
| LED netdev triggers in board.json | PASS: `white:lan`, `white:wan` |
| `uci batch` of `configs/uci/10-guest-iot-networks.uci` | PASS |
| `fw4 print` | PASS: 264-line ruleset (zones lan/wan/guest/iot) |

## 6. Network namespace simulation (`tests/network/run-netns-tests.sh`)

The suite runs in a QEMU x86-64 VM with Ubuntu kernel 6.8 (bridge VLAN filtering, 8021q, nftables,
netem, CAKE), because the build host's kernel has no bridge support. The ruleset is **the output
of the image's own fw4** (§5), with device names mapped to the namespaces. A second run with the
hand-written reference ruleset (`tests/network/fw4-reference.nft`) gave the same pass/fail result.

| ID | Test | Result | Measurement (veth, NOT hardware) |
|---|---|---|---|
| N01 | WAN DHCP client | PASS | lease from simulated ISP |
| N02 | ruleset loads into the kernel | PASS | fw4-generated |
| N03-N05 | DHCP on LAN (VLAN 1), guest (VLAN 20), IoT (VLAN 30) | PASS | |
| N06 | DNS forwarder | PASS | |
| N07 | client → router | PASS | |
| N08 | client ↔ client switched at L2, not routed | PASS | router forwarded 0 packets |
| N09 | LAN → Internet NAT (source rewritten to the WAN address) | PASS | |
| N10/N11 | TCP (HTTP) and UDP through NAT | PASS | |
| N12 | sustained TCP + concurrent ping | PASS | 580-690 Mbit/s, 0 % ping loss (VM/veth figure) |
| N13 | UDP 200 Mbit/s | PASS | 1-9 % loss (VM CPU-bound) |
| N14-N21 | guest → Internet only; guest ↛ LAN/router SSH; guest DNS ok; IoT ↛ Internet/LAN/guest; LAN → IoT | PASS | |
| N22 | no L2 leakage guest VLAN → LAN ports | PASS | 0 frames |
| N23-N25 | SSH blocked from WAN; unsolicited WAN→LAN rejected; Allow-Ping | PASS | |
| N26-N29 | IPv6 SLAAC, routing, UDP; SSH blocked from WAN over v6 | PASS | |
| N31 | 5 MB transfer intact over 5 % loss / 40±10 ms | PASS | sha256 identical |
| N32 | CAKE 50 Mbit/s egress shaping | PASS | 43-46 Mbit/s |
| N33/N34 | failover to second uplink on carrier loss; recovery | PASS | 0.5-0.7 s |

**33/33 PASS (simulation).** Not simulated: PPPoE, mwan3 policy routing, DSA tagging, the switch's
VLAN 4k table, Wi-Fi of any kind, and flow offload with fw4 (fw4 omits the flowtable when the
kernel module isn't visible in the chroot; the reference ruleset run showed offloaded conntrack
entries).

## 7. What could not be done offline

- Any check of the radios, Q6 firmware, board data, RF or regulatory behaviour.
- Booting the AX23 kernel. The ipq50xx kernel has no virtual-machine platform; booting it in QEMU
  `virt` would only test generic code and was not attempted.
- Switch, trunk, PHY and real NAT throughput; NAND; U-Boot.
