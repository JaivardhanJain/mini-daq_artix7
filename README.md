# Mini-DAQ (Artix-7) — Phase 1

Real-time benchtop DAQ: XADC sampling -> 16-point FFT -> MicroBlaze -> UART ->
Python spectrum plot.

The FFT is built in **HLS first** (fast path to a working end-to-end demo); a
hand-written **RTL FFT follows** as the centerpiece and RTL-vs-HLS comparison.

## Folder layout
- `model/` — Python golden model + test vectors (the source of truth for verification)
- `hls/`   — Vitis HLS FFT (C++): dataflow kernel, twiddle ROM, testbench, run_hls.tcl — **current FFT track** (AXI-Stream later)
- `rtl/`   — SystemVerilog FFT (butterfly, twiddle ROM, stage control) — later track
- `sim/`   — ModelSim testbenches and simulation scripts
- `python/`— host-side pyserial + matplotlib visualization
- `docs/`  — design notes, board XADC pin map, project plan, reports

## Timeline (by work day)
- **Day 1** — Initial project design: overall architecture + Phases 1-4 scoped.
- **Day 2 (2026-07-07)** — Design decisions locked (below); deadline set
  (Aug 1, 2026); Phases 2 & 3 dropped (Python handles visualization).
- **Day 3** — Learning the FFT (DFT math, butterfly, twiddles, bit-reversal).
- **Day 4** — Python golden model + test vectors + project docs.
- **Day 5-6** — Learning HLS (pragmas, `ap_fixed`, pp4fpgas FFT chapter).
- **Day 7 (2026-07-14)** — Built, verified, and synthesized the HLS FFT (below).

## Design decisions locked (Day 2 — 2026-07-07)
- FFT size: N = 16 (parameterized; scale to 64–256 after the deadline)
- Number format: Q1.15 fixed-point, full bit-growth (16 -> 20 bits over 4 stages)
- Algorithm: radix-2 decimation-in-time
- Single clock domain (no CDC for now)
- Magnitude (sqrt) computed in Python, not hardware
- FFT implementation: **HLS first** for an early working pipeline; hand-RTL FFT
  as the centerpiece + RTL-vs-HLS comparison

## Day 7 — HLS FFT built, verified, synthesized (2026-07-14)
Went past the "just learn it" goal and shipped a working, optimized HLS FFT.
- Backfilled the HLS pragmas (DATAFLOW, PIPELINE/II, UNROLL, ARRAY_PARTITION,
  LOOP_TRIPCOUNT) + `ap_fixed`, and worked through the pp4fpgas FFT chapter
  (background/S-matrix, baseline, bit-reversal, task pipelining).
- Built the dataflow FFT in `hls/` (C++): bit-reverse + 4 stage functions,
  `#pragma HLS dataflow`, twiddle ROM, flattened butterfly loop `PIPELINE II=1`.
- Datapath = **Q5.15 (`ap_fixed<20,5>`)** — Q1.15 would overflow (DC bin hits 8);
  the 5 integer bits hold the 16->20-bit growth.
- Verified: Vitis **csim 4/4** vs golden vectors; **csynth** on XC7A35T =
  **12 DSP / 1350 LUT / 1668 FF (13% DSP), 152 MHz, latency 74 / interval 19**.
- Float baseline was 90 DSP (100% of the chip) — measured proof of the
  fixed-point decision. Full write-up in `docs/hls_engineering_log.md` and
  `docs/hls_synthesis_results.md`.
- Remaining HLS polish: `ap_ctrl_chain` (frame overlap), AXI-Stream interfaces,
  cosim.

## Day 8 plan — finish the HLS track
Goal: validate, re-interface for streaming, and package the FFT as an IP.
- Hour 1: **cosim** — run the C testbench against the generated RTL (xsim);
  confirm RTL == C and get measured latency.
- Hour 2: **AXI-Stream (part 1)** — swap the `ap_memory` array ports for
  `hls::stream` + `axis` (TVALID/TREADY/TLAST); update the testbench; csim.
- Hour 3: **AXI-Stream (part 2)** — csynth + cosim the streaming version;
  confirm TDATA/TVALID/TREADY/TLAST ports and that it still fits.
- Hour 4: **block protocol + export** — set `ap_ctrl_chain`/`ap_ctrl_none` for
  continuous frames (clears the Day-7 overlap warning), then `export_design`
  to package the Vivado IP for the SoC block design.

## Status
- [x] Golden model (direct DFT, radix-2, Q1.15 fixed-point) — verified vs NumPy
- [x] Test vectors exported
- [x] Project docs (design notes, board XADC pin map, project plan)
- [x] Learning HLS (pp4fpgas intro + FFT chapter: pragmas, bit-reversal, task pipelining)
- [~] HLS FFT: C++ kernel (dataflow, Q5.15, twiddle ROM, flattened PIPELINE II=1) + csim vs golden vectors (4/4 pass); AXI-Stream still to add
- [~] HLS FFT: csynth + loop-flatten/tripcount done (Q5.15: 12 DSP, 152 MHz, latency 74/interval 19, fits XC7A35T — see docs/hls_synthesis_results.md); cosim pending
- [ ] End-to-end demo: XADC -> HLS FFT -> UART -> Python
- [ ] Phase 2: switch mode-select + SPI-flash boot
- [ ] Hand-RTL FFT (butterfly -> full FFT -> ModelSim) + RTL-vs-HLS comparison
