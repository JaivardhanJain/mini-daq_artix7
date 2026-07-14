# Mini-DAQ (Artix-7) — Phase 1

Real-time benchtop DAQ: XADC sampling -> 16-point FFT -> MicroBlaze -> UART ->
Python spectrum plot.

The FFT is built in **HLS first** (fast path to a working end-to-end demo); a
hand-written **RTL FFT follows** as the centerpiece and RTL-vs-HLS comparison.

## Folder layout
- `model/` — Python golden model + test vectors (the source of truth for verification)
- `hls/`   — Vitis/Vivado HLS FFT: C kernel, AXI-Stream interface, HLS testbench — **current FFT track**
- `rtl/`   — SystemVerilog FFT (butterfly, twiddle ROM, stage control) — later track
- `sim/`   — ModelSim testbenches and simulation scripts
- `python/`— host-side pyserial + matplotlib visualization
- `docs/`  — design notes, board XADC pin map, project plan, reports

## Design decisions locked (Day 1)
- FFT size: N = 16 (parameterized; scale to 64–256 after the deadline)
- Number format: Q1.15 fixed-point, full bit-growth (16 -> 20 bits over 4 stages)
- Algorithm: radix-2 decimation-in-time
- Single clock domain (no CDC for now)
- Magnitude (sqrt) computed in Python, not hardware
- FFT implementation: **HLS first** for an early working pipeline; hand-RTL FFT
  as the centerpiece + RTL-vs-HLS comparison

## Day 2 plan (HLS learning + pp4fpgas FFT chapter)
Goal: understand the HLS FFT flow — not writing the kernel yet.
- Hour 1: backfill HLS pragmas (PIPELINE/II, UNROLL, ARRAY_PARTITION, DATAFLOW)
  + `ap_fixed`; read FFT "Background" (S-matrix, divide-and-conquer, twiddles)
- Hour 2: "Baseline Implementation" + "Initial Software FFT" — stage/butterfly
  loops; why the naive version bottlenecks on memory ports
- Hour 3: "Bit Reversal" — bit-reversed indexing math + in-place reorder
- Hour 4: "Task Pipelining" — DATAFLOW between stages, PIPELINE the butterfly
  loop, UNROLL + ARRAY_PARTITION for parallel butterflies

## Status
- [x] Golden model (direct DFT, radix-2, Q1.15 fixed-point) — verified vs NumPy
- [x] Test vectors exported
- [x] Project docs (design notes, board XADC pin map, project plan)
- [x] Learning HLS (pp4fpgas intro + FFT chapter: pragmas, bit-reversal, task pipelining)
- [~] HLS FFT: C++ kernel (dataflow, Q5.15, twiddle ROM) + csim vs golden vectors (4/4 pass); AXI-Stream still to add
- [~] HLS FFT: csynth done (Q5.15: 12 DSP, 152 MHz, fits XC7A35T — see docs/hls_synthesis_results.md); cosim + tripcount/loop-flatten pending
- [ ] End-to-end demo: XADC -> HLS FFT -> UART -> Python
- [ ] Phase 2: switch mode-select + SPI-flash boot
- [ ] Hand-RTL FFT (butterfly -> full FFT -> ModelSim) + RTL-vs-HLS comparison
