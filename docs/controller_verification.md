# Mini-DAQ — Controller Verification (XADC & UART)

Verification status of the two existing hand-written VHDL controllers, reviewed
Day 9 (2026-07-16/17). Both were prior lab-exercise projects reused for the
Mini-DAQ; this records what is actually verified vs. what still needs work to
serve the DAQ pipeline.

---

## UART controller — VERIFIED (loopback simulation passes)

**Files:** `rtl/UART controller/Ex5/…` — `uart_tx.vhdl` (TX), `uart_rx.vhd` (RX),
`uart_master_top.vhdl` / `uart_slave_top.vhdl` (demo tops), testbenches
`uart_link_tb.vhd` (loopback) and `tb_uart_tx.vhd`.

**Design:** 8-N-1 UART at 115200 baud, 100 MHz clock (`BAUD_DIV = 868`,
`HALF_BAUD = 434`).
- **TX** (`uart_tx.vhdl`): FSM IDLE → START → DATA(×8, LSB-first) → STOP, with a
  baud-tick generator and `tx_busy`. Framing correct (start=0, 8 data LSB-first,
  stop=1).
- **RX** (`uart_rx.vhd`): 2-FF synchronizer on the async line, samples at the
  start-bit center with glitch rejection, then at each bit center; LSB-first
  shift-in; one-cycle `rx_done` pulse. Correct.

**Verification (the important part):** `uart_link_tb` is a **self-checking
loopback** — it wires TX → wire → RX and asserts the received byte equals the sent
byte. The xsim run passed both patterns:

Re-run at the real baud (868) with an expanded pattern set — all six pass:

```
Note: OK   sent 0x53  received 0x53   @  82665 ns
Note: OK   sent 0xA6  received 0xA6   @ 169495 ns
Note: OK   sent 0x00  received 0x00   @ 256325 ns
Note: OK   sent 0xFF  received 0xFF   @ 343155 ns
Note: OK   sent 0x55  received 0x55   @ 429985 ns
Note: OK   sent 0xAA  received 0xAA   @ 516815 ns
Note: === Simulation finished ===
```

No FAIL, clean compile/elaborate. **Timing confirmed:** consecutive bytes complete
exactly 86,830 ns apart = 10 bits × 8.68 µs, i.e. one 8-N-1 frame at 115200 baud —
proving the run is at the real 868 divisor. The 0x00/0xFF (all-low/all-high data)
and 0x55/0xAA (alternating) patterns exercise the sampling edges and bit ordering.
This is genuine, closed-out functional verification.

**Caveats / follow-ups:**
1. **Re-sim at the real baud — DONE.** Re-simulated at 868 with six patterns
   (0x53, 0xA6, 0x00, 0xFF, 0x55, 0xAA); all round-trip, frames exactly 86.83 µs
   apart (= 10 bits @ 115200). The earlier fast-divisor caveat is now closed.
2. **Duplicate TX removed.** `uart_tx.vhd` was an orphan copy (not in the `.xpr`,
   not compiled by the sim); deleted. Project uses `uart_tx.vhdl`.
3. **Stale comments removed** from `uart_tx.vhdl` and `uart_rx.vhd` (the
   "TEMPORARILY 16 … RESTORE TO 868" notes — values were already correct).
4. **Coverage is light** (two byte patterns). Harden later with 0x00, 0xFF,
   0x55/0xAA and a few back-to-back frames.

**Integration fit:** the `uart_tx` interface (`tx_start` / `data_in[7:0]` /
`tx_busy`) is directly drivable by MicroBlaze software or an RTL framer — no rework
needed to use it in the DAQ. RX is for host→FPGA (optional; Phase-4 mode select).

---

## XADC controller — BUILDS & timing-clean, but NOT sim-verified and NOT DAQ-shaped

**Files:** `rtl/XADC controller/Ex4/…` — `xadc_top.vhd` + the `xadc_wiz_0` IP.
Configured single-channel **VAUX5**, continuous, **~1 MSPS**, no averaging, 100 MHz
DCLK.

**Design:** FSM WAIT_EOC → WAIT_DRDY. On each `eoc_out` it pulses `den` for one
cycle to DRP-read register 0x15 (VAUX5), waits for `drdy`, and latches the **top 8
of the 12-bit** result onto 8 LEDs. It's the classic "read the pot, show it on the
LEDs" bring-up exercise.

**What is verified:** synthesis clean (0 warnings/criticals), **timing met** (WNS
+6.882 ns, WHS +0.316 ns), 1 (minor) routed-DRC item, bitstream generated. If the
LEDs tracked the pot on the board, that's an informal hardware smoke test.

**What is NOT verified / NOT DAQ-ready:**
- **No simulation testbench** exists (`sim/` empty) — no self-checking sim, no
  captured waveforms.
- **Outputs to LEDs**, not a sample bus — no data-out port + `valid` strobe for a
  downstream consumer (the FFT needs one).
- **Discards resolution** — keeps only `drp_do(15 downto 8)`; the real 12-bit
  result is `drp_do(15 downto 4)`.
- **No format conversion** — XADC gives a 12-bit *unsigned unipolar* code
  (0…4095 = 0…1 V); the FFT needs *signed* samples in Q5.15. The
  "subtract mid-scale, scale to Q5.15" adapter isn't present.

**DAQ front-end built + conversion verified (2026-07-21).** New modules in
`rtl/XADC controller/Ex4.srcs`:
- `daq_sampler.vhd` — DRP-read FSM + 12-bit→Q5.15 conversion, **IP-free** so it's
  unit-testable (generics `BIPOLAR`, `SHIFT`).
- `xadc_daq.vhd` — top wrapping `xadc_wiz_0` + `daq_sampler` (generics `DADDR=0x15`,
  `BIPOLAR=false`, `SHIFT=4`); emits `sample(19:0)` Q5.15 + `sample_valid`.
- `tb_daq_sampler.vhd` — self-checking unit test that **mocks the DRP side** (drives
  `eoc`/`drdy`/`do_in` with known codes), no XADC IP or analog stimulus needed.

**Result — 6/6 codes pass** (xsim): mid-scale 2048→0, +full-scale 4095→+32752,
−full-scale 0→−32768, +0.5 3072→+16384, −0.5 1024→−16384, +0.25 2560→+8192.
Confirms the centering (−2048), the `<<4` scale, the sign, and the `sample_valid`
strobe. Design decisions + justifications: `hls_engineering_log.md` §10.

**Synth check — PASS (2026-07-21).** Synthesized `xadc_daq` as top: elaborates
cleanly, `xadc_wiz_0` hooks up (shows as a black box, synthesized OOC), footprint
**4 LUT / 15 FF / 0 DSP / 0 BRAM** — the `<<4` scale is free wiring, no multiplier.
(The 25 IOBs are a synth-as-top artifact; they disappear once `sample`/`sample_valid`
are internal nets in the SoC.)

**Still to do:** the integration-contract check against the FFT read side (sample
rate / format / handshake) and real place-and-route timing — both happen when
`xadc_daq` is instantiated in the Day-11 MicroBlaze block design with a proper
board-level top.

---

## UART throughput vs. Python visualization (analysis)

At 115200 baud, one byte ≈ 87 µs → ~11.5 kB/s. The FFT at ~1 MSPS with N=16
produces ~62,500 spectra/s, which cannot be streamed whole (would need ~4 MB/s).
**This is fine for visualization** because a plot only needs ~10–30 updates/s — you
decimate/average frames on-FPGA and send a small fraction. Even sending every frame
naively (~64 bytes) still gives ~180 spectra/s, more than a display needs. The UART
rate caps *display refresh*, not the FFT or sampling.

**If more throughput is wanted:** (a) raise the baud rate — most FTDI/CP210x USB
bridges do 921600 up to a few Mbaud, a one-line `BAUD_DIV` + pyserial change for an
8–25× gain; (b) send fewer bytes/frame — only the 9 unique bins (real-input
conjugate symmetry) instead of 16, or magnitude-only, or narrower words;
(c) average/decimate on-FPGA. Only full-rate lossless *logging* would force a
faster link (USB-FIFO / Ethernet) — out of scope for the spectrum plot.

---

## XADC → FFT framer — built + verified (2026-07-21)

`xadc_axis_framer.vhd` (in `rtl/XADC controller/Ex4.srcs`) bridges the front-end to
the FFT: each `sample`+`sample_valid` becomes one 40-bit AXIS beat
(`real=[19:0]=sample`, `imag=[39:20]=0`), with `TLAST` on every `FRAME`-th beat
(`FRAME` generic, default 16 — set to 256 later; must equal FFT `SIZE`). `TVALID` is
held until `TREADY` accepts, so it is back-pressure-safe (with an `overflow` flag).

`tb_xadc_axis_framer.vhd` self-checks framing (32 samples → 2 frames: TDATA,
imag-zero, TLAST on beats 15 & 31, TKEEP/TSTRB all-ones) and back-pressure (beat
held stable while TREADY low, drains on release). **Result: PASS.** The full
XADC→FFT data path (`xadc_daq` → `xadc_axis_framer` → `fft_axis`) is now built and
sim-verified end-to-end; wiring into the SoC is the Day-11 block-design work.

_Companion to `README.md` and `docs/verification_methodology.md`._
