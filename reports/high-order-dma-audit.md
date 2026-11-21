# High-order DMA allocation and fragmentation audit

Scope: the order-9 WBM link-descriptor banks and the other physically contiguous
ath11k DP allocations on the Archer AX23 EU V2.0 (256 MiB). No router was touched.
Labels: **SOURCE** (the exact compiled kernel 6.18.55 / backports 7.2 in `build/dev`),
**OEM** (static analysis of TP-Link's signed 1.2.1 image and its GPL tree; nothing
executed), **BUILD**, **SIM** (host model), **REL** (related hardware), **UNV**.
Nothing here is **VERIFIED ON OUR PHYSICAL AX23**.

## 1. Geometry (SOURCE)
| Item | Value |
|---|---|
| Descriptors per radio | 2730 MPDU link + 227 queue + 4681 TX MSDU link + 10922 RX MSDU link = **18,560**, rounded up to a power of two = **32,768** (`ath11k_wbm_idle_ring_setup`, 64 clients × 2 TIDs) |
| Descriptor | 128 B, 128 B aligned (`HAL_LINK_DESC_SIZE/ALIGN`) |
| Banks | 32,768 × 128 + 128 = 4,194,432 B split at 2 MiB − 128: **2,097,152 + 2,097,152 + 384 B** → two order-9 blocks and one page per radio |
| Idle list | WBM idle ring 32,768 × 8 B = 256 KiB (below 2 MiB, so no scatter list) |
| When | `ath11k_dp_alloc()` at firmware-ready: first start of each radio, and again on every firmware recovery |
| Firmware memory mode 2 | does **not** change the descriptor count (it changes RX/TX rings only; 0002/0012/0018) |

## 2. What the hardware requires (SOURCE)
- Each descriptor is listed individually in the WBM idle ring with its own physical
  address and a 21-bit software cookie (`ath11k_hal_set_link_desc_addr`,
  `BUFFER_ADDR_INFO1_SW_COOKIE` = bits 31:11). The hardware needs only each 128-byte
  descriptor to be contiguous and aligned.
- Bank contiguity is a **host** convention: the cookie is the bank index, and the RX
  error and monitor paths map an address back as `bank.vaddr + (paddr − bank.paddr)`.
  `DP_LINK_DESC_BANKS_MAX = 8` is a software array size.
- No IOMMU sits in front of the Wi-Fi blocks and they are not DMA-coherent, so
  `dma_alloc_coherent()` is dma-direct: one `alloc_pages(get_order(size))` block. A 2 MiB
  bank therefore needs a free (or compactable) order-9 block.
- Hardware-legal alternatives therefore exist (smaller banks with more cookies). They
  need `DP_LINK_DESC_BANKS_MAX > 8`, because 4 MiB in 512 KiB banks needs 9 banks.

## 3. How TP-Link's firmware does it (OEM, static disassembly of `wifi_3_0.ko`, `qdf.ko`, `umac.ko`)
- The link-descriptor pool comes from `qdf_mem_multi_pages_alloc()`. Its page size is
  read from `pages->page_size` and defaults to 4096 only when the caller leaves it zero.
  Each page is one `__qdf_mem_alloc_consistent()` buffer.
- The caller sets `page_size = wlan_cfg->max_alloc_size` (getter at `+0x8` of the DP
  config context) before allocating.
- The config table defines `dp_max_alloc_size` with range **0x80000–0x200000** (512 KiB–2 MiB),
  and the generated defaults store **0x200000** (2 MiB) for it and **64** for `dp_max_clients`
  (range 8–64). TP-Link's `/ini` files override neither.
- The stock GPL kernel configs (`target/linux/ipq/config-4.4`, `config-lowmem`) have
  **`# CONFIG_CMA is not set`**, `CONFIG_COMPACTION=y`, and the stock DT reserves no CMA region.
- **Conclusion:** stock firmware on this same 256 MiB board allocates the link-descriptor
  pool in 2 MiB coherent chunks with 64 clients and no CMA, i.e. the same order-9 requirement
  as ath11k. It also runs an 8 MiB NSS reservation that OpenWrt does not. The vendor's
  validated minimum chunk is 512 KiB, but the vendor ships 2 MiB.

## 4. Startup and recovery exposure
| Moment | Exposure | Evidence |
|---|---|---|
| First start, both radios | four order-9 + the ring blocks within seconds of each other, early in boot (least fragmented). `ax23_radios=seq` serialises the two radios. | SOURCE; OEM does the same at boot; REL: EX511 v2 runs ath11k with the same banks on 256 MiB |
| Firmware recovery | `ath11k_core_restart()` → `ath11k_core_reconfigure_on_crash()` frees DP memory and `ath11k_core_qmi_firmware_ready()` re-allocates it **in the same work item**. The old 2 MiB blocks stay allocated from the crash until firmware-ready, and their freed order-9 blocks are re-requested immediately. | SOURCE. Keeping the banks across recovery was considered and **rejected**: no evidenced gain. |
| `wifi down/up`, reconfiguration | no DP reallocation | SOURCE |
| Atomic pool | `coherent_pool=2M` is not used for these `GFP_KERNEL` allocations | SOURCE |

## 5. Fixed in this phase: exact ring sizes (patch 0027 = ath11k 965)
`ath11k_dp_srng_setup()` requested `entries × entry_size + HAL_RING_BASE_ALIGN − 1`.
DMA allocations are aligned to at least a page (`Documentation/core-api/dma-api-howto.rst`),
so the 7 bytes were never needed. With dma-direct, every power-of-two ring got a block
twice its size. Per radio in FW memory mode 2 (compiler-confirmed entry sizes):

| Ring | Bytes | Before (order / KiB) | After |
|---|---|---|---|
| WBM idle link | 262,144 | 7 / 512 | 6 / 256 |
| REO destination ×4 | 131,072 each | 6 / 1024 total | 5 / 512 total |
| TX completion (961) | 65,536 | 5 / 128 | 4 / 64 |
| RX release, RXDMA error dst | 32,768 each | 4 / 64 each | 3 / 32 each |
| TCL data, REO exception, RXDMA buffer | 16,384 / 8,192 / 8,192 | one order higher | exact |
| REO status | 212,992 | 6 / 256 | 6 / 256 (not a power of two) |
| **Total listed** | | **2,112 KiB, highest ring order 7** | **1,184 KiB, highest ring order 6** |

That is about 0.9 MiB less contiguous memory per radio (1.8 MiB both), requested at
the same moment as the link-descriptor banks. Ring entry counts, ring geometry and base
alignment seen by the hardware are unchanged. A base that does not meet
`HAL_RING_BASE_ALIGN` is now refused and freed instead of being hidden in slack.

- **Evidence:** SOURCE plus the DMA API guarantee.
- **SIM:** `tests/unit/check_ath11k_ring_alloc.py` runs the real setup/cleanup functions against a page-aligned dma-direct model. The built driver passes; with 965 reversed, eight rings fail on order. It is wired into `tools/test-dev.sh` (`unit-ath11k-ring-alloc`) and the validator.
- **BUILD:** compiled; validator 80/80.

## 6. Options examined and not taken
| Option | Why not |
|---|---|
| Reduce descriptors (fewer clients, no power-of-two rounding) | changes hardware queue capacity; stock keeps 64 clients and rounds the same way (OEM); not requested without evidence |
| Smaller banks (512 KiB, 9+ banks) | hardware-legal (SOURCE) and within the vendor's validated range (OEM), but neither upstream ath11k nor stock ships it, and it changes the cookie-to-bank mapping on RX error paths. **Prepared fallback only**, if the measurement in §8 shows an order-9 failure. |
| CMA region | stock runs without CMA; it would reserve memory permanently on a 256 MiB board |
| Keep banks across recovery | §4: free and re-allocate are back-to-back; no measurable gain |
| Upstream fix | mainline ath11k/ath12k (`torvalds/linux` master, fetched 2026-11-21) still use 2 MiB banks, 8 bank slots and 64 clients, and still re-allocate on recovery. The only differences from our tree are our own patches (0012/0019/0022). The ring slack is also present upstream. |

## 7. Corrected claims
- Link-descriptor memory is 4 MiB + 4 KiB per radio (8 MiB both), not "~4.3 MiB/radio incl. idle ring" or "8.6 MiB".
- The fixed rings took ~1.4 MiB per radio as built (not "~0.4 MiB"), 0.84 MiB after 965.
- Total ath11k host DMA both radios: **~20 MiB** after 965 (~21.5 MiB before); the idle MemAvailable projection stays 75–90 MiB (HYP).
- The doubled ring orders came from alignment slack, not "2 MiB alignment" (`ath11k-low-memory-analysis.md` §4).

## 8. The remaining hardware measurement (passive, no writes)
Captured by `ax23-selfdiag.sh --bundle`. Compare boots with `ax23_radios=none`, `seq` and `both`:
1. `/proc/buddyinfo` before Wi-Fi starts and after each radio registers (M.3/M.4: free blocks of order ≥ 9).
2. dmesg: no `page allocation failure: order:9` and no `failed to setup link desc` (S3.8, M.10).
3. Both `fw_build_id` lines and both phys present.
4. After a natural firmware recovery (none forced), the same three lines again.

If (2) shows an order-9 failure, the next step is the §6 smaller-bank fallback, tested the same way.
Until then the order-9 risk is **UNV** on our unit, with OEM (same allocation on the same
board, no CMA) and REL (EX511 v2) evidence that it succeeds.
