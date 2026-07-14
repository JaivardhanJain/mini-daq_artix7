# HLS FFT — Synthesis Results (Phase 1)

**What this document shows:** the measured Vitis HLS synthesis numbers (DSP,
LUT, FF, Fmax, latency) for the 16-point FFT, and how those numbers changed as
each optimization was applied — the float→fixed-point switch (5.a) and the
loop-flatten (5.b). It is the "numbers" companion to `hls_engineering_log.md`
(which tells the story of *how* we got here and every problem along the way).

**Design:** 16-point radix-2 DIT FFT, dataflow architecture (bit-reverse + 4 stages),
twiddle ROM, butterfly loop pipelined `II=1`.
**Tool:** Vitis HLS 2020.2, target **XC7A35T-FTG256-1**, 10 ns clock (100 MHz).
**Verification:** csim vs `model/fft_test_vectors.txt` — 4/4 vectors PASS,
max magnitude error 0.0001, peak value 8.0 (within the Q5.15 ±16 range).

## Order of changes (three synthesis runs)

1. **Run 1 — float baseline.** Dataflow + per-stage `PIPELINE II=1` + twiddle
   ROM, datapath type = 32-bit `float`.
2. **Run 2 — fixed-point.** Same design, datapath switched to Q5.15
   (`ap_fixed<20,5>`). (Section 5.a compares Run 1 -> Run 2.)
3. **Run 3 — loop-flatten.** Each stage's nested loops rewritten as one flat
   8-iteration loop, plus `LOOP_TRIPCOUNT`. (Section 5.b compares Run 2 -> Run 3.)

---

## 5.a  Results — float baseline vs Q5.15 fixed-point (the AREA win)

| Metric            | Run 1: Float 32-bit | Run 2: Q5.15 | Change            |
|-------------------|---------------------|--------------|-------------------|
| DSP48             | 90                  | 12           | -87%  (7.5x fewer)|
| LUT               | 8,986               | 1,587        | -82%              |
| FF                | 13,982              | 2,078        | -85%              |
| BRAM_18K          | 0                   | 0            | —                 |
| Estimated Fmax    | 168 MHz             | 152 MHz      | both > 100 MHz    |
| Butterfly depth   | 21 cycles           | 6 (stage 1: 2) | ~3.5x shorter   |
| csim              | 4/4 pass            | 4/4 pass     | both correct      |

**Why the numbers changed (float -> fixed):**
- **DSP 90 -> 12:** a 32-bit float multiply/add each consumes several DSP48s;
  a Q5.15 (20-bit) multiply fits in a single DSP48 (25x18 multiplier) and the
  add/subtract move into LUT logic. Far fewer DSPs per butterfly.
- **LUT/FF collapse (-82% / -85%):** floating-point cores carry heavy mantissa
  alignment and normalization logic (barrel shifters, leading-zero detect,
  rounding), which is a lot of LUTs and pipeline FFs. Fixed-point is plain
  integer arithmetic — almost none of that.
- **Fmax 168 -> 152 (slight drop):** *educated guess* — the float cores are
  very deeply pipelined (butterfly depth 21), so each pipeline stage has a short
  critical path and a high clock ceiling. The fixed MAC has far fewer pipeline
  registers (depth 6), so a bit more combinational logic per clock stage and a
  marginally longer path. Still comfortably above the 100 MHz target.
- **Butterfly depth 21 -> 6:** float ops need multi-cycle align/normalize; a
  fixed-point MAC is short. Lower latency per butterfly, as a side effect.

**On the XC7A35T (90 DSP / 20800 LUT / 41600 FF):** Q5.15 uses **13% DSP / 7% LUT
/ 4% FF** vs float maxing DSPs at 100%. This is the measured justification for
the Q1.15/fixed-point design decision — ~7/8 of the fabric stays free for
MicroBlaze, XADC, UART, and the rest of the SoC.

---

## 5.b  Results — Q5.15 nested vs flattened loops (the LATENCY / BALANCE win)

Change: each stage's two nested loops (outer twiddle loop + inner butterfly
loop) were rewritten as a **single flat loop over all N/2 = 8 butterflies**,
deriving the twiddle position and indices from one counter, with
`#pragma HLS PIPELINE II=1` and `#pragma HLS LOOP_TRIPCOUNT min=8 max=8`.

| Metric              | Run 2: Nested    | Run 3: Flattened          |
|---------------------|------------------|---------------------------|
| DSP48               | 12               | 12  (unchanged)           |
| LUT                 | 1,587            | 1,350  (-15%)             |
| FF                  | 2,078            | 1,668  (-20%)             |
| Estimated Fmax      | 152 MHz          | 152 MHz  (unchanged)      |
| Stage 4 latency     | ~48 (bottleneck) | 14                        |
| Per-stage latency   | ? / imbalanced   | 10 / 14 / 14 / 14 (bit_rev 18) |
| Top-level latency   | ? (unresolved)   | 74 cycles (0.74 us)       |
| Top-level interval  | ?                | 19 cycles                 |
| csim                | 4/4 pass         | 4/4 pass                  |

**Why the numbers changed (nested -> flattened):**
- **DSP unchanged (12):** the flatten changes only loop *control*, not the
  datapath — same number of multiplies/adds, same 8 butterflies per stage.
- **LUT -15%, FF -20%:** *educated guess* — the nested version needed two loop
  counters (outer `j`, strided inner `i`), strided address generation, and
  pipeline fill/drain control repeated once per outer iteration. The flat loop
  has one counter and one pipeline fill, so less control/FSM logic and fewer
  pipeline-flush registers.
- **Stage 4 ~48 -> 14, stages balanced:** the nested loops weren't a "perfect
  nest" (the twiddle ROM reads sit between outer and inner loop), so HLS
  pipelined only the inner loop. Stage 4's inner loop runs once, so its 8
  butterflies lived in the outer loop and each paid a fresh pipeline fill
  (~8 x 6). The single flat loop pays one fill, so all stages land at ~14.
- **Latency `?` -> 74 / interval 19:** the flat loop bound is a compile-time
  constant (8), so HLS can statically compute latency (it couldn't before,
  because the nested bounds varied with `stage`). Interval is now set by the
  slowest stage (bit-reverse at 18).
- **Fmax unchanged:** same arithmetic / same critical path.

---

## Notes
- `fft_stage_one` uses **0 DSPs** (twiddle W^0 = 1 -> pure add/sub); stages 2-4
  use 4 DSPs each = 12 total.
- Butterfly loop hit `II=1` in every stage with **no ARRAY_PARTITION** — each
  array sees only 2 accesses/cycle, matching a 2-port BRAM.
- Buffers between stages: ping-pong (PIPO), 0 BRAM (distributed RAM).
- Twiddles synthesized as ROMs. Interface: `ap_memory` + `ap_ctrl_hs`.

## Known follow-ups (not yet done)
- `ap_ctrl_chain` for frame-to-frame overlap (streaming DAQ throughput).
- AXI-Stream interfaces for XADC -> FFT -> MicroBlaze integration.
- cosim to confirm RTL matches C.
- Later: per-stage bit-growth types (vs uniform Q5.15), scale N to 64-256.

_Generated during Phase 1 HLS bring-up (Day 7 — 2026-07-14; design decisions were Day 2, 2026-07-07)._
