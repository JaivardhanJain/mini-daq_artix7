# Mini-DAQ (Artix-7) — Phase 1

Real-time benchtop DAQ: XADC sampling -> 16-point FFT -> MicroBlaze -> UART ->
Python spectrum plot.

The FFT is built in **HLS** and packaged as an AXI-Stream IP (complete). The
XADC and UART controllers are **existing hand-written VHDL** modules. The current
focus is **system integration** — verifying those controllers and wiring
XADC -> FFT IP -> UART -> Python. A hand-RTL FFT is an optional late stretch, not
required (other RTL projects already cover that ground).

## Folder layout
- `model/` — Python golden model + test vectors (the source of truth for verification)
- `hls/`   — Vitis HLS FFT (C++): dataflow kernel, twiddle ROM, AXI-Stream wrapper, run_hls.tcl, packaged IP in `hls/ip/` — **HLS track COMPLETE**
- `rtl/`   — hand-written **VHDL** controllers (XADC, UART) + integration glue/top — **current track (Day 9)**; optional hand-RTL FFT later
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
- **Day 8 (2026-07-16)** — Finished the HLS track: cosim, AXI-Stream interface,
  dataflow throughput fix, free-running control, IP export (below).
- **Day 9 (planned)** — System integration bring-up: verify the existing XADC &
  UART VHDL controllers, then start wiring XADC -> FFT IP -> UART (below).

## Design decisions locked (Day 2 — 2026-07-07)
- FFT size: N = 16 (parameterized; scale to 64–256 after the deadline)
- Number format: Q1.15 fixed-point, full bit-growth (16 -> 20 bits over 4 stages)
- Algorithm: radix-2 decimation-in-time
- Single clock domain (no CDC for now)
- Magnitude (sqrt) computed in Python, not hardware
- FFT implementation: the **HLS FFT (packaged AXI-Stream IP) is the FFT used in
  the system**; a hand-RTL FFT is an optional late stretch, not required
- XADC + UART controllers: **existing hand-written VHDL** (reused, then verified)
- Integration: **MicroBlaze SoC** (chosen 2026-07-16) — enables Phase-4 SPI-flash
  standalone boot and moves result framing / UART handling / control into
  software; the free-running FFT streams via AXI (DMA or AXIS-FIFO) to MicroBlaze

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

## Day 8 — HLS track finished (2026-07-16)
**Done — all four hours completed, every step cosim-PASS 4/4.** Validated,
re-interfaced for streaming, and packaged the FFT as a Vivado IP.
- Hour 1: **cosim** — ran the C testbench against the generated RTL (xsim);
  RTL == C confirmed, measured interval 19 / latency ~74 (matched estimates).
- Hour 2-3: **AXI-Stream** — wrapped the core in an `fft_axis` top with
  `hls::stream` + `axis` ports (40-bit TDATA = real+imag Q5.15, TLAST per frame);
  csim + csynth + cosim all pass; ports confirmed TDATA/TVALID/TREADY/TLAST.
- Hour 4: **throughput + control + export** — made `fft_axis` a dataflow region
  (interval regression 113 -> **20**), set `ap_ctrl_none` (free-running, cleared
  the overlap warning), and `export_design` packaged the IP -> `hls/ip/fft_axis_1.0.zip`.
- Final: **12 DSP / 1629 LUT / 1937 FF, 151.77 MHz, latency 113 / interval 20.**
  Full write-up: `docs/hls_engineering_log.md`, `docs/hls_synthesis_results.md`.

## Day 9 plan — system integration bring-up
Goal: verify the two existing hand-written VHDL controllers (XADC, UART) in
simulation, then start stitching the datapath XADC -> FFT IP -> UART. Correctness
of the building blocks first, wiring second.
- Hour 1: **integration architecture + module review** — add the existing XADC +
  UART VHDL controllers to `rtl/`; read their interfaces (clock/reset, data width,
  sample rate + handshake, UART baud/framing). Sketch the top-level datapath and
  the glue it needs: XADC sample -> Q5.15/AXIS adapter -> `fft_axis` IP -> UART TX.
  **Integration is via MicroBlaze** (decided) — so the open question here is *how
  the two custom VHDL controllers attach to the AXI fabric* (wrap each as a custom
  AXI4-Lite/AXIS peripheral vs. drive them from MicroBlaze GPIO), and how FFT
  output reaches the CPU (AXI DMA S2MM vs. AXI-Stream FIFO). Result framing / UART
  bytes move into MicroBlaze software.
- Hour 2: **XADC controller testbench** — simulate it standalone against
  `docs/board_xadc_pinmap.md`; confirm it produces samples at the expected rate,
  width, and format, with the handshake the FFT input will consume.
- Hour 3: **UART controller testbench** — simulate the TX (and RX if present):
  feed known bytes, check serial timing at the target baud (start/stop/bit
  period), and confirm byte ordering for the multi-byte FFT output. Loopback if
  RX exists.
- Hour 4: **start the MicroBlaze block design** — new Vivado project, add the
  MicroBlaze + AXI infra (interconnect, clock/reset, local memory) and the FFT IP
  from `hls/ip/`; drop in the two controllers (or stub AXI wrappers for them);
  connect what's clean and list the peripherals/adapters to build next (controller
  AXI wrappers, XADC->AXIS adapter, DMA/FIFO path). Log status; scope Day 10.

> Note: the `rtl/` folder in this repo is currently empty — the XADC/UART VHDL
> sources need to be added here (or their location pointed to) before Hour 2.

## Status
- [x] Golden model (direct DFT, radix-2, Q1.15 fixed-point) — verified vs NumPy
- [x] Test vectors exported
- [x] Project docs (design notes, board XADC pin map, project plan)
- [x] Learning HLS (pp4fpgas intro + FFT chapter: pragmas, bit-reversal, task pipelining)
- [x] HLS FFT: C++ kernel (dataflow, Q5.15, twiddle ROM, flattened PIPELINE II=1) + csim/cosim vs golden vectors (4/4 pass)
- [x] HLS FFT: csynth (Q5.15: 12 DSP, 152 MHz, latency 74/interval 19, fits XC7A35T — see docs/hls_synthesis_results.md)
- [x] HLS FFT: AXI-Stream interface + dataflow throughput (interval 20) + ap_ctrl_none free-running + IP export (hls/ip/fft_axis_1.0.zip)
- [~] XADC + UART controllers: hand-written VHDL (built by JJ) — **verifying in sim (Day 9)**
- [ ] System integration: MicroBlaze block design (XADC -> FFT IP -> DMA/FIFO -> MicroBlaze -> UART); AXI wrappers for the VHDL controllers, XADC->AXIS adapter
- [ ] End-to-end demo: XADC -> FFT -> UART -> Python
- [ ] Phase 4: switch mode-select + SPI-flash standalone boot
- [ ] (optional/stretch) Hand-RTL FFT + RTL-vs-HLS comparison
