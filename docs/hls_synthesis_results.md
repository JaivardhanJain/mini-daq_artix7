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

## 5.c  Cosim — RTL matches C (Day 8, Hour 1)

Ran `cosim_design`: HLS generated the Verilog RTL, then ran it in the xsim
simulator driven by the *same* `fft_tb` C testbench (C-check before sim, RTL
sim, C-check after).

**Result: `C/RTL co-simulation finished: PASS`** — 4/4 vectors, both the pre-
and post-simulation C checks. So the generated hardware behaves identically to
the C.

It also **confirmed the performance estimates with a real simulation**: RTL
transactions completed 190 ns apart = **19 cycles interval** (matches the
csynth estimate exactly), first result at ~76 cycles ≈ the 74-cycle latency
estimate. The dataflow deadlock detector ran clean (no stalls). So the 74/19
numbers are now measured, not just estimated.

## 5.d  AXI-Stream version — synth + cosim (Day 8, Hours 2-3)

Wrapped the verified `fft_dataflow` in an AXI4-Stream top (`fft_axis`) and
re-synthesized. csim + cosim both **PASS 4/4**.

**Interface transformed** (the point of the change): the old `ap_memory` array
ports became real AXI4-Stream ports —
`in_r: TDATA[40]/TVALID/TREADY/TLAST/TKEEP[5]/TSTRB[5]` (slave) and `out_r: ...`
(master). Block control is still `ap_ctrl_hs` (start/done) — `ap_ctrl_chain`/
`none` is the Hour-4 change.

| Metric        | Array top (`fft_dataflow`) | Stream top (`fft_axis`) |
|---------------|----------------------------|-------------------------|
| DSP48         | 12                         | 12  (core unchanged)    |
| LUT           | 1,350                      | 1,684  (+334 wrapper)   |
| FF            | 1,668                      | 1,854  (+186 wrapper)   |
| Fmax          | 152 MHz                    | 152 MHz                 |
| Top latency   | 74 cycles                  | 112 cycles              |
| Top interval  | 19 cycles                  | **113 cycles**          |
| Ports         | ap_memory                  | AXI4-Stream             |
| csim / cosim  | 4/4 / PASS                 | 4/4 / PASS              |

**Why LUT/FF grew:** the stream wrapper adds read/write loops, the pack/unpack
(`.range()`), address generation, and the TVALID/TREADY handshake FSM. The FFT
core itself is byte-for-byte the same (still 12 DSP). Fits easily: 13% DSP /
8% LUT / 4% FF.

**Throughput regression to fix in Hour 4:** the interval jumped 19 -> 113 cycles
(cosim confirms: frames complete 1130 ns = 113 cycles apart). Cause: `fft_axis`
runs read-16 -> compute -> write-16 strictly in sequence, and `ap_ctrl_hs` blocks
the next frame until the current one fully finishes — no frame overlap. Fix
(Hour 4): `ap_ctrl_chain`/`ap_ctrl_none` for successive-frame overlap, and make
`fft_axis` a dataflow region so read/compute/write run concurrently. Then the
interval should drop back toward the core's ~19.

## 5.e  Dataflow wrapper — throughput restored (Day 8, Hour 4)

Added `#pragma HLS dataflow` to `fft_axis` and refactored the read/write phases
into functions (`read_in`, `write_out`) so it's a clean 3-process region.

**Result: interval 113 -> 20 cycles (~5.6x throughput), latency unchanged.**

| Metric        | 5.d Stream (sequential) | 5.e Stream (dataflow) |
|---------------|-------------------------|-----------------------|
| Top interval  | 113 cycles              | **20 cycles**         |
| Top latency   | 112 cycles              | 113 cycles            |
| DSP48         | 12                      | 12                    |
| LUT           | 1,684                   | 1,631                 |
| FF            | 1,854                   | 1,937                 |
| Fmax          | 152 MHz                 | 152 MHz               |
| csim / cosim  | 4/4 / PASS              | 4/4 / PASS            |

Per-process intervals: read_in 18, fft_dataflow 19, write_out 19 -> region
interval = max ≈ 20. cosim confirms it in real sim: frames complete 200 ns =
20 cycles apart. The `X`/`OUT` buffers became ping-pong (PIPO) memories (the
doubled storage that lets the phases overlap); area barely moved.

**Note:** the dataflow pragma alone achieved the overlap under `ap_ctrl_hs` (the
region pipelines the frames itself). `ap_ctrl_none`/`ap_ctrl_chain` is still
recommended for continuous free-running operation in the SoC and to clear the
`HLS 200-786` dataflow-on-top warning — it's an integration refinement now, not
a throughput fix.

## 5.f  Free-running control + IP export (Day 8, Hour 4 — final)

Added `#pragma HLS INTERFACE ap_ctrl_none port=return` to `fft_axis` and
appended `export_design -format ip_catalog` to the tcl.

**Result: throughput/area unchanged; the block is now free-running and packaged.**
Exact figures from `fft_axis_csynth.rpt`:

| Metric         | 5.e Stream (ap_ctrl_hs) | 5.f Stream (ap_ctrl_none) |
|----------------|-------------------------|---------------------------|
| Top interval   | 20 cycles               | **20 cycles**             |
| Top latency    | 113 cycles (1.130 us)   | 113 cycles (1.130 us)     |
| DSP48          | 12                      | 12   (13%)                |
| LUT            | 1,631                   | 1,629  (7%)               |
| FF             | 1,937                   | 1,937  (4%)               |
| BRAM_18K       | 0                       | 0                         |
| Estimated Fmax | 152 MHz                 | **151.77 MHz** (6.589 ns) |
| Control ports  | ap_start/done/idle/ready| **none** (data-driven)    |
| HLS 200-786    | present                 | **cleared**               |
| csim / cosim   | 4/4 / PASS              | 4/4 / PASS                |

The numbers barely move (LUT 1631 -> 1629, the two gates of the dropped handshake)
because `ap_ctrl_none` only changes *how the block is triggered*, not the
datapath. Per-process breakdown from the report: `read_in` interval 18, `write_out`
19, `fft_dataflow` 19 (latency 74) -> region interval = max ≈ **20**; the FFT core
holds all 12 DSP, the wrapper adds only `read_in` 71 LUT / `write_out` 108 LUT.

**Interface table confirms the free-running control** — the only non-AXIS ports
are `ap_clk` and `ap_rst_n` (both listed under protocol `ap_ctrl_none`); every
data port is `axis` (`in_r_/out_r_ TDATA[40]/TVALID/TREADY/TLAST/TKEEP[5]/TSTRB[5]`).
The `ap_start/done/idle/ready` ports are gone. cosim still PASS 4/4 (the dataflow
monitor + TLAST bound each frame in place of `ap_done`).

**Timing headroom:** estimated critical path 6.589 ns against the 10 ns target
(2.70 ns uncertainty guardband) — ~3.4 ns slack, i.e. the design would close
timing well above 100 MHz with room for the rest of the SoC's routing.

**IP export:** `export_design` packaged the RTL as a Vivado IP-catalog bundle at
`mini_daq_fft_hls/sol1/impl/export.zip` (VLNV `wadhwani:daq:fft_axis:1.0`). This
required working around a Vitis 2020.2 date bug — the auto-generated
`core_revision` (`YYMMDDHHMM` = 2607161630) overflows a 32-bit signed int in
2026; temporarily setting the PC clock to 2021 let it pack. See engineering log
3.13. **This completes the HLS optimization track.**

## Notes
- `fft_stage_one` uses **0 DSPs** (twiddle W^0 = 1 -> pure add/sub); stages 2-4
  use 4 DSPs each = 12 total.
- Butterfly loop hit `II=1` in every stage with **no ARRAY_PARTITION** — each
  array sees only 2 accesses/cycle, matching a 2-port BRAM.
- Buffers between stages: ping-pong (PIPO), 0 BRAM (distributed RAM).
- Twiddles synthesized as ROMs. Interface: `ap_memory` + `ap_ctrl_hs`.

## Known follow-ups
- **DONE:** AXI-Stream interface (5.d), frame-throughput dataflow (5.e),
  free-running `ap_ctrl_none` + IP export (5.f), cosim RTL-vs-C at every step.
- Next phase: Vivado block design — instantiate the exported IP and wire
  XADC -> FFT -> DMA -> MicroBlaze.
- Later: per-stage bit-growth types (vs uniform Q5.15), scale N to 64-256.

_Generated during Phase 1 HLS bring-up (Day 7 — 2026-07-14; design decisions were Day 2, 2026-07-07)._
