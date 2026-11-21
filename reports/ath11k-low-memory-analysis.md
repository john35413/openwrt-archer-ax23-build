# ath11k low-memory DP rings: the upstream patch, our adaptation, and proof

Labels as in `wifi-root-cause.md`. This report covers the P0 task: locate the
upstream low-memory ath11k patch, determine its status, compare it with what our
tree already carries, and justify our adapted backport (patches 0002 + 0012).

## 1. The upstream patch

- **Title:** `[PATCH ath-next] wifi: ath11k: use smaller DP rings on low-memory systems`
- **Author:** Eduard Hart `<eduard.hart@etik.com>`, 2026-09-30
- **Message-Id:** `20260930165052.4998-1-eduard.hart@etik.com`
- **Tested-on (author):** IPQ5018 + QCN6122, `WLAN.HK.2.7.0.1-01744`, on the **RE700X**
  (the same board whose OpenWrt DTS keeps Wi-Fi disabled "together with the ath11k
  patch that selects smaller rings on low-memory boards"). **SRC.**
- **Fetched:** `scratchpad/lkml/lkml.html` (lkml.iu.edu, 200) and
  `scratchpad/lkml/thread.mbox.gz` (lore.kernel.org `t.mbox.gz`, 200).

### Status (what is and is not knowable offline)
- The lore thread mbox contains **one message** (the patch); no replies, acks or
  revisions were captured. The lore HTML thread view and patchwork are **not
  reachable** from this environment (lore `/T/` returns 403 through the proxy;
  patchwork.kernel.org is not an allowed host), so an authoritative upstream
  merge/revision state **cannot be confirmed offline** — recorded as such, not
  guessed. **UNVERIFIED (status).**
- **What we can verify (BUILD):** the patch's mechanism — a `struct
  ath11k_dp_profile_params`, `ath11k_dp_get_profile()`, and selection by
  `si_meminfo()` `totalram < SZ_256M` — is **absent from OpenWrt main's
  backports-7.2** as of our fetch `6bd48701` (2026-11-21). So our project's kernel
  does **not** already include an equivalent, and neither does current OpenWrt main.
  Our patches are the only low-memory DP-ring change in our tree.

### What the patch changes (read from the diff, `lkml.html`)
A per-profile struct selected at `ath11k_dp_alloc()` time, with two profiles:

| Ring | default | low_mem (patch) |
|---|---|---|
| `tx_comp_ring_size` | 32768 | **2048** |
| `rxdma_buf_ring_size` | 4096 | 1024 |
| `rxdma_mon_status_ring_size` | 1024 | 512 |
| `rxdma_monitor_buf_ring_size` | 4096 | 128 |
| `rxdma_monitor_dst_ring_size` | 2048 | 128 |

Selector: `si_meminfo(&si); low = si.totalram < (SZ_256M >> PAGE_SHIFT)`. It touches
`dp.c` (+50), `dp.h` (13), `dp_rx.c` (9), `dp_tx.c` (12), and crucially redefines
`ATH11K_TX_COMPL_NEXT(x)` → `ATH11K_TX_COMPL_NEXT(dp, x)` wrapping at
`dp->profile->tx_comp_ring_size`, drops `DP_TX_IDR_SIZE`, and bounds the
`idr_alloc()` msdu range by the runtime ring size.

## 2. What our tree already had vs. what was missing

| Quantity | Default | Our 0002 (pre-this-work) | Upstream low_mem | Our 0012 (new) |
|---|---|---|---|---|
| RXDMA buf (IPQ5018 / QCN6122) | 4096 | **512 / 1024** | 1024 | unchanged (0002) |
| mon status / buf / dst / desc | 1024/4096/2048/4096 | 512/128/128/128 | 512/128/128/4096 | unchanged (0002) |
| RXDMA err dst | 1024 | 128 | 1024 | unchanged (0002) |
| **TX completion ring** | **32768** | **32768 (unchanged)** | **2048** | **2048** |
| **TX status FIFO (kmalloc)** | 32768×32 B | unchanged | 2048×32 B | **2048×32 B** |
| **`ATH11K_TX_COMPL_NEXT` wrap** | 32768 | 32768 | runtime | **runtime** |
| **`DP_TX_IDR_SIZE` msdu range** | 32768 | 32768 | runtime | **runtime (size−2)** |

**The gap:** our 0002 reduced only the **RX** rings (the biggest single saving,
~42 MiB of pre-posted buffers, `stability-risks.md` §1). It explicitly left the
**TX completion ring and all its dependent logic** alone, because that size is baked
into the `ATH11K_TX_COMPL_NEXT()` wrap macro and needs a careful change. **Patch
0012 closes exactly that gap.**

## 3. Our adaptation (patch 0012) and why it differs from a copy

The owner's rule: *"Do not copy raw numerical values without adapting all dependent
driver logic."* We did not copy the upstream profile struct. Instead:

1. **Same selector as our 0002, not `totalram`.** We key on
   `ab->hw_params.fw_mem_mode == 2` (the DT property the board already declares),
   not `si_meminfo() < SZ_256M`. Reason: it changes **only boards that declare the
   256 MiB FW profile**, leaving every other board in a shared build untouched —
   the same design principle as 0002, and it avoids a second, differently-keyed
   mechanism in the same driver (the owner's "avoid duplicating conflicting memory
   optimizations"). The AX23's visible MemTotal (~173 MB) is < 256 MiB, so the
   upstream selector would also fire — the two criteria agree here.
2. **One runtime field, every dependent site converted.** `dp->tx_comp_ring_size`
   drives: the WBM2SW release ring in `ath11k_dp_srng_common_setup()`; the
   `tx_status` FIFO `kmalloc` size and its initial `tx_status_tail`;
   `ATH11K_TX_COMPL_NEXT(dp, x)`; and the `idr_alloc()` msdu-id range in
   `ath11k_dp_tx()`. (`BUILD`: `validate-artifacts.sh` checks `DP_TX_IDR_SIZE` is
   gone and the macro takes `dp`.)
3. **IDR bounded at `size − 2`, not `size − 1`.** This is an improvement on a naive
   port. `ath11k_dp_tx_completion_handler()` moves at most `size − 2` descriptors
   into the FIFO in one pass (the copy loop stops at `head == tail − 1`, tail
   starting at `size − 1`). With `size − 1` frames in flight (the upstream/
   `DP_TX_IDR_SIZE − 1` bound) one completion can be stranded behind a
   "status_fifo is full" warning until a later interrupt. A Python model of the
   handler (`tests/unit/test_ath11k_rings.py::CompletionModel`) demonstrates:
   `size − 1` → `status_fifo full` events on a 16-entry ring under load; `size − 2`
   → zero, in-order, every frame completed exactly once, across 3 seeds ×20 000
   steps. Unreachable at 32768; reachable at 2048 under load.
4. **Kept separate from 0002.** 0012 adds no RX changes; `test_ath11k_rings.py`
   asserts the 961 diff contains no `RXDMA` and 0002 contains no `tx_comp_ring_size`
   — the two do not overlap or conflict.

## 4. Memory effect (BUILD / source-derived; effect HYP for the AX23)

Per radio, from `ath11k_dp_srng_setup()` and the `kmalloc` FIFO
(`test_ath11k_rings.py::MemoryAccounting`). No CMA and no IOMMU on IPQ5018, so dma-direct
allocates `get_order(size)` pages. **Correction:** the doubled ring orders come from the
7-byte `HAL_RING_BASE_ALIGN - 1` slack ath11k added to every ring, not from 2 MiB alignment.
Patch 0027 (ath11k 965) removes it (`high-order-dma-audit.md`):

| | DMA ring order/bytes | kmalloc FIFO order/bytes | per radio |
|---|---|---|---|
| default 32768 (1 MiB ring) | order-9 / 2 MiB (order-8 with 965) | order-8 / 1 MiB | **3 MiB** |
| FW mode 2 (0012) 2048 (64 KiB ring) | order-5 / 128 KiB → **order-4 / 64 KiB with 965** | order-4 / 64 KiB | **128 KiB** |

**Saving: ~2.8 MiB per radio → ~5.6 MiB for both radios.** More important than the
byte count is the **allocation order**: the default needs an **order-9 (2 MiB)
physically contiguous block per radio when the firmware becomes ready** — i.e. after
userspace has started and memory is fragmented. On a 256 MiB board this can fail
even when enough total memory is free. 0012 drops the requirement to order-5
(128 KiB), and 965 to order-4 (64 KiB), which a fragmented small system can still satisfy. This is the failure
mode EX511 v2 and the other 256 MiB boards hit (`cross-device-equivalence.md` §1).

## 5. Compiled into the AX23 kernel (BUILD)

`./tools/build-dev.sh --variant dev --resume` applies 0012 and rebuilds; the object
is confirmed newer than the patched header and the symbol is present:

```
dp.c:4  dp_tx.c:1  dp.h:2   (tx_comp_ring_size occurrences)
validate: PASS ath11k built with FW-mode-2 TX completion ring sizing (961)
```

The dev initramfs rebuilt and re-validated (67 checks PASS, 0 FAIL) with 0012–0015.

## 6. Limits
- **Effect is HYP for the AX23 until hardware.** No AX23 has booted this. The
  byte/order accounting is source-derived; the *stability* benefit (both radios up
  without `-ENOMEM`) is observable only with `free`/`dmesg` on the real board
  (`ax23-selfdiag.sh` S3.8/M.3/M.4 are written to capture exactly this).
- **Upstream merge state unverified offline.** If the ath-next profile patch lands
  and is later backported into our `mac80211`, 0012's header says to drop it; the
  selectors would then need reconciling (ours `fw_mem_mode`, theirs `totalram`).
- **2048 is a measured sibling value**, not ours: it is the upstream low_mem value
  and OpenWrt PR #21495's, tested by others on IPQ5018+QCN6122; it is 4× the
  512-entry TCL data ring, so it does not starve TX. We did not invent a number.
