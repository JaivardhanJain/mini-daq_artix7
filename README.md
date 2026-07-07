# Mini-DAQ (Artix-7) — Phase 1

Real-time benchtop DAQ: XADC sampling -> hand-written RTL 16-point FFT ->
MicroBlaze -> UART -> Python spectrum plot.

## Folder layout
- `model/` — Python golden model + test vectors (the source of truth for verification)
- `rtl/`   — SystemVerilog FFT (butterfly, twiddle ROM, stage control) — Phase 1 core
- `sim/`   — ModelSim testbenches and simulation scripts
- `python/`— host-side pyserial + matplotlib visualization
- `docs/`  — design notes, fixed-point format, timing/utilization reports

## Design decisions locked (Day 1)
- FFT size: N = 16 (parameterized; scale to 64–256 after the deadline)
- Number format: Q1.15 fixed-point, full bit-growth (16 -> 20 bits over 4 stages)
- Algorithm: radix-2 decimation-in-time
- Single clock domain (no CDC for now)
- Magnitude (sqrt) computed in Python, not hardware

## Status
- [x] Golden model (direct DFT, radix-2, Q1.15 fixed-point) — verified vs NumPy
- [x] Test vectors exported
- [ ] Butterfly RTL
- [ ] Full 16-point FFT RTL + ModelSim verification
- [ ] AXI-Stream wrap + SoC integration
- [ ] XADC -> FFT -> UART -> Python end-to-end
