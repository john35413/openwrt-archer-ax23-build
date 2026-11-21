# Real memory budget for the Archer AX23 v2 (256 MiB)

Labels as in `wifi-root-cause.md`. Supersedes the budget table in
`stability-risks.md` §1 with the ath11k ring numbers after patches 0002 **and**
0012, the digital-twin low-memory matrix, and the cross-device anchors. The only
truly authoritative figure — a hardware `free`/`/proc/buddyinfo` with both radios up
— is **not yet available** (no AX23 has booted this image). Everything below is
labelled.

## 1. Fixed reservations (what Linux never sees), STATIC

| Item | Size | Source |
|---|---|---|
| Physical RAM | 256 MiB | 3P (U-Boot "256 MiB") |
| OpenWrt no-map reserved (incl. 48 MiB Q6 `q6_region` @0x4b000000) | 58 MiB | STATIC (ipq5018.dtsi + qcn6122.dtsi) |
| → kernel-reported **MemTotal at boot** | **≈173,056 kB** | **3P boot log** |
| Stock equivalent (for contrast): NSS 8 + TZ 4 + Q6/WCSS 42 MiB | 54 MiB | STATIC (official 1.2.1 `fdt@mp02.1`) |

The AX23 reserves slightly more than stock (58 vs 54 MiB) because OpenWrt's Q6
region is 48 MiB vs stock's 42; this is upstream ipq50xx policy, not ours, and is the
same on every in-tree IPQ5018+QCN6122 board.

## 2. ath11k host DMA, the part our patches change (STATIC estimate; effect HYP)

Per-radio host rings, **before** any client associates:

| Ring group | Default | 0002 (RX) + 0012 (TX) | Saving |
|---|---|---|---|
| RX pre-posted buffers (×~2.8 KiB skb) | ~25 MiB/radio | ~4.6 MiB per radio (RXDMA buf 1024 after 0018; 512 before) | ~41 MiB both |
| **TX completion ring** DMA (2 MiB) + FIFO kmalloc (1 MiB) | **3 MiB/radio** | **192 KiB/radio** | **~5.6 MiB both** |
| WBM link-descriptor banks (32768 × 128 B, 2 × order-9 blocks) + idle ring (order-7) | ~4.3 MiB/radio | ~4.3 MiB/radio (unchanged; no reference profile reduces it) | 0 |
| REO/WBM/TCL fixed rings (REO dst 4×2048, REO status 2048, TCL data 512, …) | ~0.4 MiB/radio | same | 0 |
| **total host DMA, both radios** | **~65 MiB** | **~19 MiB** | **~46 MiB** |

**Correction (adversarial review):** an earlier version of this table omitted the WBM
link-descriptor banks. They are allocated in `ath11k_dp_alloc()` at firmware-ready
time as **two order-9 (2 MiB) coherent blocks per radio**. So 0012 removes the TX
ring's order-9 + order-8 allocations, but **four order-9 allocations remain** across
both radios. They are unchanged upstream and in every reference profile, and EX511 v2
(256 MiB, both radios) runs with them (REL). Whether they succeed on our unit is
exactly what `ax23-selfdiag.sh` M.4 (free blocks of order ≥ 8) and M.10/S3.8
(allocation failures) show on the first boot, ideally compared between
`ax23_radios=seq` and `both`.

**The allocation-order point matters more than the byte total** (`ath11k-low-memory-analysis.md` §4): the default TX ring needs an **order-9 (2 MiB)
physically contiguous block per radio at firmware-ready time**. On a fragmented
256 MiB system that single allocation can fail even with tens of MiB free — the
`-ENOMEM` other 256 MiB boards hit. 0012 drops it to order-5 (128 KiB). This is why
the TX-ring change is necessary and not just a nicety.

## 3. Projected RAM-boot budget (HYP; only hardware confirms)

```
MemTotal (boot)                                    ≈ 173,056 kB   [3P]
− initramfs rootfs held in RAM (RAM boot only)     ≈  29,000 kB   [STATIC, artifacts-dev.txt]
− kernel + base userspace working set              ≈  30,000 kB   [HYP, twin-anchored]
− ath11k host DMA both radios (0002+0012+0018)     ≈  19,000 kB   [STATIC estimate, incl. 8.6 MiB link descriptors]
− conntrack/fw4/dnsmasq/hostapd×4/LuCI peak        ≈  10,000 kB   [HYP, twin-anchored]
----------------------------------------------------------------
≈ 75–90 MiB MemAvailable idle, both radios up      [HYP; corrected in the adversarial review: link descriptors were omitted before]
A NAND install frees most of the ~29 MiB initramfs share.
```
**Cross-device sanity (REL):** EX511 v2 (256 MiB, mode 2 both radios, but with NSS
enabled and default TX ring) reported "**barely 16 MiB free** ... both radios up" and
OOM-panicked writing a 12 MiB file — *before* a TX-ring reduction and *with* an 8 MiB
NSS region we do **not** reserve. Our configuration (no NSS, reduced RX **and** TX
rings) should sit well above that, but **only a hardware reading proves it.**

## 4. coherent_pool: why we keep 2M (not EX511's 512K)

EX511 v2 cut `coherent_pool` from 2M to 512K after measuring the three atomic DMA
pools at 8 MiB on a 256 MiB board and proving only its **vendor MPD firmware loader**
(`mdt_load_split_segment_dma`, GFP_DMA → atomic) drew on it, which it fixed with a
`GFP_KERNEL` patch. **We keep 2M** because:
- Our Q6 load path is **ath11k upstream + OpenWrt remoteproc**, not EX511's
  out-of-tree vendor MPD loader; their 512K+loader-patch result does not transfer
  without the same measurement on our stack.
- 2M is the **3P-tested** value on the AX23 (v0.2–v0.5 boots).
- Reclaiming ~6 MiB via `coherent_pool` is a **follow-up optimisation to attempt on
  hardware** (read `/sys/kernel/debug/dma_pools` after boot, as EX511 did), not a
  bring-up change. `ax23-selfdiag.sh` M.7 records the setting for exactly this.

## 5. Digital-twin low-memory matrix (SIM only — NOT ath11k memory)

`tests/twin/memory-matrix.sh` runs the full 48-check twin at several **router RAM
sizes** and samples `MemAvailable` every 10 s, with a LuCI/DNS/DHCP-churned load
phase and an optional 30-min soak. **What it does and does not show:**
- **Shows (SIM):** whether the OpenWrt **userspace + kernel** stack (netifd,
  hostapd×4, dnsmasq, fw4/conntrack, LuCI, mac80211_hwsim) boots and stays
  responsive, and how `MemAvailable` trends, as total RAM shrinks toward and below
  the AX23's ~173 MiB. A clean pass at ≤176 MiB is **evidence the non-driver memory
  pressure is survivable**; a leak would show as a negative `MemAvailable` slope or
  an OOM line.
- **Does NOT show:** ath11k/Qualcomm firmware DMA (hwsim has none), so the ~8 MiB of
  §2 and the order-9 allocation risk are **absent** from the twin. The twin cannot
  falsify or confirm the driver-memory hypothesis — only the host-stack part.

Results so far (`logs/twin/matrix/summary.tsv`):
- **200 MiB baseline:** 48/48, MemAvailable ≈73 MiB with 4 SSIDs + 2 clients, 0 OOM.
- **176 MiB + 30-min soak:** **49/49 PASS, 0 FAIL**, MemAvailable ≈46 MiB with 4
  SSIDs + 2 clients; the 30-minute mixed load (iperf both bands + wired NAT +
  LuCI/DNS/DHCP churn) held with **0% LAN ping loss, 0 OOM, 0 kernel error**, and
  reboot recovery in 111 s. (This run predated the memory-sampler fix, so its
  per-10 s `MemAvailable` trend/slope was not captured; later runs record it.)
- **160 MiB:** **49/49 PASS**, MemAvailable 33.8 MiB at steady state, minimum
  27.7 MiB under load, 0 OOM. The −65 MB/h "slope" covers only the 3-minute load
  window and reflects buffers filling as load starts, not a leak; leak detection
  needs the long soak with the (now fixed) sampler.
- **128 MiB:** the twin kernel **panics while unpacking its initramfs**
  (`do_populate_rootfs: write error`), because the armsr twin kernel reserves
  32 MiB of CMA, leaving 46 MiB, less than the compressed image plus the unpacked
  rootfs. This is a twin-kernel artifact (the AX23 kernel has no CMA, and HW-3P AX23
  boots of the same-size initramfs worked). The real lesson: **a RAM boot needs
  about twice the rootfs size free at unpack time**, which the AX23's ~173 MiB
  MemTotal covers.
- **200 MiB** (the earlier baseline, not repeated): 48/48 ×3, MemAvailable ≈73 MiB.

So the OpenWrt **host stack** stays responsive and OOM-free at **176 MiB**, below the
AX23's ~173 MiB MemTotal — evidence that the non-driver memory pressure is survivable.
This says nothing about the ~8 MiB of ath11k host DMA (§2), which hwsim does not
model; only hardware settles that.

## 6. The single hardware observation that settles this
One RAM boot of the dev image, then over SSH (captured by `ax23-selfdiag.sh`):
```
free -m; grep -E 'MemTotal|MemAvailable|Slab' /proc/meminfo     # before `wifi up`
cat /proc/buddyinfo                                             # orders >=5 free?  (M.3/M.4)
wifi up; sleep 20
free -m; dmesg | grep -iE 'ath11k|-12|ENOMEM|alloc'             # S3.8 / M.5 / M.6
```
If both radios register (two `fw_build_id`, no `failed to …board…`, no page-allocation
failure) and MemAvailable stays comfortably positive, the budget is confirmed and the
memory risk (R1 in `stability-risks.md`) is closed. Until then it is **HYP**, with
strong REL/SRC support from §2–§3.
