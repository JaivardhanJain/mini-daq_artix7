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
- **Day 9 (2026-07-17)** — Verification: UART controller verified (loopback, 6
  patterns at real baud); FFT randomized differential harness written (below).
- **Day 10 (2026-07-21)** — DONE: FFT differential verification closed (4.6 LSB);
  XADC DAQ front-end built, conversion unit-verified (6/6), synth-clean (below).
- **Day 10 Hour 5 + Day 11 (planned)** — System integration: XADC→FFT framer, then
  the MicroBlaze SoC bring-up (below).

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

## Day 9 plan — verification day (FFT + controllers)
Goal: fully verify what already exists before any integration wiring — finish the
FFT's randomized differential verification, then bring up the existing XADC & UART
VHDL controllers in simulation. No MicroBlaze / integration work yet; that moves to
Day 10. (Full FFT test design: `docs/verification_methodology.md`.)
- Hour 1: **FFT differential harness** — factor the existing streaming testbench
  into a `run_dut()` helper; add the double-precision direct-DFT reference and
  ~10k seeded-random frames comparing **real + imag** (not just magnitude). Run in
  csim, read the worst-case error, calibrate `TOL` (express it in LSBs).
- Hour 2: **FFT stress + invariants + sign-off** — add near-full-scale boundary
  frames and corner bins (1, Nyquist), the Parseval energy check (`Σ|X|² = N·Σ|x|²`);
  push ~a dozen random frames through cosim; record the worst-case error and flip
  the verification docs from "designed" to "done".
- Hour 3: **XADC controller verification** — add the VHDL to `rtl/`; testbench it
  against `docs/board_xadc_pinmap.md`; confirm sample rate, width, format, and the
  handshake the FFT input will consume.
- Hour 4: **UART controller verification** — testbench the TX (and RX if present):
  check serial timing at the target baud (start/stop/bit period) and byte ordering
  for the multi-byte FFT output. Loopback if RX exists.

> Day-9 progress: UART **verified & closed** (loopback, 6 patterns @ real baud);
> XADC found to be a pot→LED demo, not DAQ-shaped (needs a front-end rebuild);
> FFT differential harness written but not yet run/calibrated. See
> docs/controller_verification.md and docs/verification_methodology.md.

## Day 10 plan — close FFT verification + XADC DAQ front-end
- Hour 1: **close the FFT differential test** — run the harness, read worst|err|
  (LSB) + Parseval + boundary frames, calibrate `TOLD` to ~1.5–2× the measured
  worst, add a small random subset to cosim, record the number, flip the docs to
  done.
- Hour 2: **XADC front-end — design** — new `xadc_daq.vhd` wrapping the XADC IP:
  full 12-bit result, unsigned→signed (subtract mid-scale 0x800), scale to Q5.15,
  expose `sample` + `sample_valid` (the handshake the FFT consumes).
- Hour 3: **build + unit-test** — mock the DRP side (`drdy` + `drp_do` codes),
  check mid-scale→~0, full-scale→±expected, correct Q5.15, `sample_valid` once/read.
- Hour 4: **integration-contract check + document** — confirm output matches
  `fft_axis`'s read side (format/rate/handshake); quick synth for fit/timing;
  update docs/README/memory; scope the MicroBlaze block design (Day 11).

## Day 10 Hour 5 + Day 11 plan — system integration (MicroBlaze SoC)
**Hour 5 (today):** lock the block diagram + two decisions — FFT→CPU path
(**AXI-Stream FIFO** recommended vs DMA) and UART attach (**wrap the custom
`uart_tx`** recommended vs GPIO / AXI UARTlite); then write the **XADC→AXIS framer**
(sample+valid → 40-bit AXIS beat, `TLAST` every 16th) + testbench.

**Day 11 (5 hrs):**
- H1: unit-test the framer; start the Vivado block design.
- H2: MicroBlaze + AXI infra (interconnect, clock wiz, proc reset, local mem, MDM);
  validate; bare CPU building.
- H3: data plane — XADC front-end + framer + `fft_axis` IP + a **`fft_repack`**
  stage + AXI-Stream FIFO (depth a parameter). `fft_repack`: truncate each 20-bit
  Q5.15 → 16-bit **Q5.11 by dropping the low 4 bits** (keeps ±16 range/peaks;
  dropping MSBs would clip them), pack real+imag into one 32-bit CPU word, and keep
  only the **N/2+1 unique bins** (real-input symmetry) — `TLAST` on bin N/2. Wire
  XADC→framer→FFT→repack→FIFO; validate. (Full rationale: eng log §11.)

**Designed for the 256-point endgame:** framer `FRAME`, FIFO depth, and the SW
frame loop are all parameterized, so bumping N is config, not rework. The real
256 work is the **FFT core** (add/refactor to 8 stages, 128-entry twiddle ROM,
fix Q5.15 overflow via wider type or per-stage scaling, re-verify) — a separate
~1–2 day task after N=16 works end-to-end. `FRAME` must always equal FFT `SIZE`.
- H4: attach UART + first MicroBlaze C (read a frame from the FIFO, send over UART).
- H5: Python `pyserial`+`matplotlib` host + first end-to-end bring-up + triage.

**Status: H1/H2 DONE** — MicroBlaze SoC scaffold (MicroBlaze + 32 KB LMB + MDM +
Clocking Wizard on N14 + Processor System Reset) built and validated in a new local
project `C:\daq_soc`; no-button reset tied off with constants (see eng log §11.1).
Next up: H3 (`fft_repack` + data-plane wiring).

Realistic: first SoC bring-up is fiddly (clocking/reset/BSP), so the Python plot +
on-board end-to-end may spill to a Day 12.

## Day 10 design decisions — XADC DAQ front-end
New module `xadc_daq.vhd` (pot→LED demo left intact). Full justifications in
`docs/hls_engineering_log.md` §10.
- **Convert inside** the module → emits **Q5.15 `sample` + `sample_valid`** (one
  pulse/conversion), so the AXI-Stream framer is trivial.
- **Conversion:** full 12-bit result, center (−2048 for unipolar), shift left 4 →
  Q5.15 in [−1.0, +1.0) (headroom for FFT bit-growth; normalized full-scale = ±1.0).
- **Unipolar + external mid-rail bias**; `BIPOLAR` generic (default false) for a
  future differential source.
- **Generics:** `DADDR=0x15` (VAUX5), `BIPOLAR=false`, `SHIFT=4` — channel /
  polarity / scale, compile-time. Runtime config deferred (Phase-4).
- **Fs + averaging = XADC Wizard IP** (not RTL): Fs ~1 MSPS → Nyquist 500 kHz, bin
  spacing 62.5 kHz. Change Fs = regenerate IP.
- **Input = conditioned analog on VAUX5** (0–1 V only): needs external attenuate /
  bias / anti-alias / protect. A function generator works **only** through
  conditioning — never wired direct.
- **Verify (Hour 3)** by mocking the DRP side (drive `drp_do`/`drdy`), checking the
  Q5.15 output and the `sample_valid` strobe — no analog stimulus needed.

## Status
- [x] Golden model (direct DFT, radix-2, Q1.15 fixed-point) — verified vs NumPy
- [x] Test vectors exported
- [x] Project docs (design notes, board XADC pin map, project plan)
- [x] Learning HLS (pp4fpgas intro + FFT chapter: pragmas, bit-reversal, task pipelining)
- [x] HLS FFT: C++ kernel (dataflow, Q5.15, twiddle ROM, flattened PIPELINE II=1) + csim/cosim vs golden vectors (4/4 pass)
- [x] HLS FFT: csynth (Q5.15: 12 DSP, 152 MHz, latency 74/interval 19, fits XC7A35T — see docs/hls_synthesis_results.md)
- [x] HLS FFT: AXI-Stream interface + dataflow throughput (interval 20) + ap_ctrl_none free-running + IP export (hls/ip/fft_axis_1.0.zip)
- [x] HLS FFT: randomized differential verification **DONE** — 10k random frames worst 4.6 LSB (csim) + 16-frame cosim PASS + boundary/Nyquist + Parseval; see docs/verification_methodology.md
- [x] UART controller (VHDL): **verified & closed** — self-checking loopback passes 6 patterns at real baud 868 (frames 86.83 µs = 115200); cleanups done — see docs/controller_verification.md
- [x] XADC→FFT framer (VHDL): `xadc_axis_framer` built + **verified** (32 beats/2 frames + back-pressure); `FRAME` generic (256-ready). Full XADC→FFT data path now sim-verified end-to-end.
- [x] XADC DAQ front-end (VHDL): `xadc_daq`/`daq_sampler` built; conversion **unit-verified** (6/6 codes: mid-scale→0, ±full-scale, ±0.5, +0.25) + `sample_valid` — see docs/controller_verification.md. Remaining: synth-with-IP + integration-contract check (Day 11)
- [ ] System integration: MicroBlaze block design (XADC -> FFT IP -> DMA/FIFO -> MicroBlaze -> UART); AXI wrappers for the VHDL controllers, XADC->AXIS adapter
- [ ] End-to-end demo: XADC -> FFT -> UART -> Python
- [ ] Phase 4: switch mode-select + SPI-flash standalone boot
- [ ] (optional/stretch) Hand-RTL FFT + RTL-vs-HLS comparison
