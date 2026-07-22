# Mini-DAQ — Data Path (start to finish)

**What this document is:** a complete, per-stage account of how one analog voltage
becomes a point on a spectrum plot — every module the data passes through, what it
looks like going in and coming out, the exact bit layouts and number formats, the
clocking/reset and flow-control that hold it together, and the throughput budget.
It is the detailed companion to the "Data-flow / data-path" summary in
`docs/hls_engineering_log.md` §11.3.

**Design under test:** Artix-7 `xc7a35tftg256-1`, MicroBlaze SoC, 16-point HLS FFT,
single 100 MHz clock. Block design `daq_bd` in `C:\daq_soc` (sources in this repo).

---

## 0. The pipeline at a glance

```
              external            xadc_daq                xadc_axis_framer         fft_axis            axis_repack           axi_fifo_mm_s        MicroBlaze         uart_tx        Python host
  analog  →  conditioning  →  (xadc_wiz + daq_sampler)  →   (framer)         →   (16-pt FFT)    →     (40→32 repack)   →   (AXI-Stream FIFO)  →   (software)    →   (UART)    →   (pyserial+matplotlib)
  0–1 V      attenuate/bias      12-bit code → Q5.15         Q5.15 sample →         16 real →            40-bit bin →           9×32-bit           read 9 words        bytes         |X[k]| = sqrt(re²+im²)
             anti-alias          sample[19:0] + valid        40-bit AXIS beat       16 complex           32-bit word           frame buffered      → UART bytes         @115200       → plot
                                                             TLAST every 16th       bins (Q5.15)         bins 0..8 only        @ 0x0001_1000
```

Signal chain (module ports):

```
xadc_daq.sample[19:0]/sample_valid → xadc_axis_framer.m (40b AXIS)
    → fft_axis.in_r → fft_axis.out_r (40b AXIS)
    → axis_repack.s → axis_repack.m (32b AXIS)
    → axi_fifo_mm_s.AXI_STR_RXD  ⇒  (AXI4-Lite S_AXI) ⇒ microblaze_0.M_AXI_DP
```

Everything from `xadc_daq` through the FIFO runs on the single 100 MHz `clk_out1`.

---

## 1. Number formats used along the way

Two fixed-point formats carry the signal. Both are two's-complement signed.

| Format | Bits | Integer (incl. sign) | Fractional | Range | Resolution (LSB) | Where |
|---|---|---|---|---|---|---|
| **Q5.15** | 20 | 5 | 15 | [−16, +16) | 2⁻¹⁵ ≈ 3.05e-5 | XADC sample, framer beat, FFT in/out |
| **Q5.11** | 16 | 5 | 11 | [−16, +16) | 2⁻¹¹ ≈ 4.88e-4 | repack output word (each half) |

The value of a fixed-point word is `raw_integer / 2^frac`. So Q5.15 `0x08000`
(= 32768) is `32768 / 2¹⁵ = 1.0`; Q5.11 `0x0800` (= 2048) is `2048 / 2¹¹ = 1.0`.

Why five integer bits (`ap_fixed<20,5>`) and not one: the FFT accumulates bit
growth across log₂16 = 4 butterfly stages, and the DC bin of a mid-scale input can
reach ~8.0 — Q1.15 (range ±1) would overflow, so the datapath carries range ±16.
See `hls_engineering_log.md` §3.7 and `verification_methodology.md` §3.

---

## 2. Stage 0 — analog front-end (external, not on the FPGA)

**In:** a bench signal (function generator, sensor, etc.).
**Out:** a conditioned voltage in **0–1 V** on the VAUX5 pin pair (`Vaux5_v_p/n`).

The Artix-7 XADC auxiliary input accepts **0–1 V only**. A raw bench source must go
through external conditioning first — **attenuate** into range, **DC-bias** to
mid-rail (0.5 V) so a bipolar signal fits the unipolar window, **anti-alias**
low-pass below Nyquist, and **protect** the pin (clamp/series-R). Wiring a generator
directly risks damaging the pin. For clean demos, pick tones at bin centers
(`k·Fs/16`) below Nyquist to avoid leakage/aliasing.

This block is hardware outside the RTL; the DAQ assumes a valid 0–1 V input arrives.

---

## 3. Stage 1 — `xadc_daq` : analog → Q5.15 sample

`xadc_daq.vhd` wraps the **`xadc_wiz_0`** IP and the **`daq_sampler.vhd`** FSM.

**In:** `Vaux5_v_p/n` (analog), `dclk_in` (100 MHz), `reset` (active-high).
**Out:** `sample[19:0]` (Q5.15 signed), `sample_valid` (1-cycle pulse per sample).

### 3a. The XADC IP (`xadc_wiz_0`)

Configured single-channel **VAUX5**, **continuous**, **~1 MSPS**, DRP interface,
unipolar, no averaging, 100 MHz DCLK. It continuously samples VAUX5 and converts to
a **12-bit unsigned code** (0…4095 ↔ 0…1 V), signalling `eoc_out` (end of
conversion) each time; the result is read out of DRP register **0x15** as
`do_out[15:4]` (the 12 result bits sit in the top 12 of the 16-bit DRP word).

### 3b. `daq_sampler` — DRP read + conversion

A two-state FSM (`WAIT_EOC → WAIT_DRDY`): on `eoc_in` it pulses `den_out` for one
cycle to start a DRP read of 0x15; on `drdy_in` it captures `do_in`, converts, and
emits `sample` with a one-cycle `sample_valid`.

The conversion (unipolar, `SHIFT = 4`):

```
raw12    = do_in(15 downto 4)          -- full 12-bit result, 0..4095
centered = raw12 - 2048                -- mid-rail → 0, signed −2048..+2047
sample   = centered << 4               -- ×16, sign-extended to 20-bit Q5.15
```

Worked values (unit-verified 6/6 in `tb_daq_sampler`):

| VAUX5 code | meaning | `centered` | `sample` (dec) | Q5.15 value |
|---|---|---|---|---|
| 2048 | mid-scale (0.5 V) | 0 | 0 | 0.000 |
| 4095 | +full-scale (1 V) | +2047 | +32752 | +0.9995 |
| 0 | −full-scale (0 V) | −2048 | −32768 | −1.000 |
| 3072 | +0.5 FS | +1024 | +16384 | +0.500 |
| 1024 | −0.5 FS | −1024 | −16384 | −0.500 |

So the ADC full-scale maps to a **normalized ±1.0** in Q5.15 — headroom for the
FFT's bit growth. Absolute-voltage calibration, if ever needed, is a Python-side
scale factor. Any residual DC (signal not perfectly mid-rail) lands in bin 0.
`BIPOLAR` generic (default false) selects the two's-complement path for a future
differential source. Full rationale: `hls_engineering_log.md` §10.

---

## 4. Stage 2 — `xadc_axis_framer` : samples → 40-bit AXIS frames

`xadc_axis_framer.vhd` (`FRAME` generic = 16).

**In:** `sample[19:0]` + `sample_valid` (from `xadc_daq`), `clk`, `reset`.
**Out:** AXI4-Stream master `m` (40-bit), plus an `overflow` flag.

Each `sample` becomes one **40-bit AXIS beat**:

```
m_tdata(19 downto 0)  = sample   (real, Q5.15)
m_tdata(39 downto 20) = 0        (imag = 0 — the input is real-valued)
m_tkeep / m_tstrb     = all ones
m_tlast               = 1 on every FRAME-th (16th) beat  → end of an FFT frame
```

This is where a continuous sample stream is chopped into the **16-sample frames**
the FFT consumes. `TVALID` is held until `TREADY` accepts, so the block is
back-pressure-safe; `overflow` pulses in the (practically impossible) case that a
new sample arrives while the previous beat is still unaccepted. `FRAME` must always
equal the FFT `SIZE` (16 now, 256 later).

---

## 5. Stage 3 — `fft_axis` : 16 real samples → 16 complex bins

The packaged HLS IP (VLNV `wadhwani:daq:fft_axis:1.0`) — a 16-point radix-2
decimation-in-time FFT, Q5.15, dataflow architecture, **free-running**
(`ap_ctrl_none`).

**In:** AXIS slave `in_r` (40-bit), `ap_clk`, `ap_rst_n` (active-low).
**Out:** AXIS master `out_r` (40-bit).

It consumes a 16-beat frame (`TLAST` marks the last input sample) and produces a
16-beat frame of complex spectrum bins, **same 40-bit layout**:

```
out_r TDATA(19 downto 0)  = Re{X[k]}   (Q5.15)
out_r TDATA(39 downto 20) = Im{X[k]}   (Q5.15)
```

Bins stream out in **natural order** `k = 0…15` (bit-reversal is handled inside),
`TLAST` on bin 15. Because the input is real, the spectrum is conjugate-symmetric:
`X[16−k] = X[k]*`, so bins 9…15 are mirror images of 7…1 — redundant, and dropped
downstream. Measured: 12 DSP, 151.77 MHz, latency ~113 / **interval 20 cycles**, so
the FFT sustains far above the sample rate (§8). Verified to within ~5 LSB of the
exact DFT across 10k random frames — see `verification_methodology.md`.

---

## 6. Stage 4 — `axis_repack` : 40-bit bins → 32-bit CPU words, unique bins only

`axis_repack.vhd` (`SIZE` generic = 16). Combinational except a bin counter, so it
adds no latency. Built + verified (`tb_axis_repack`: 18 words / 2 frames including a
back-pressure pass).

**In:** AXIS slave `s` (40-bit, from `fft_axis.out_r`), `clk`, `reset`.
**Out:** AXIS master `m` (32-bit, to the FIFO).

It does two jobs as bins stream past, in bin order:

**(a) Truncate 40→32, pack real+imag into one word.** The CPU reads 32-bit words and
40 bits don't fit. Each 20-bit Q5.15 value is truncated to 16-bit **Q5.11 by
dropping the low 4 bits** and the two halves share one word:

```
m_tdata(31 downto 16) = s_tdata(19 downto 4)    -- Re, Q5.11  (real[19:4])
m_tdata(15 downto  0) = s_tdata(39 downto 24)   -- Im, Q5.11  (imag[19:4])
```

Dropping the **low** 4 bits (not the top) is the crux: it preserves the full ±16
range so spectral **peaks survive** (the output swings to ~±8), and only coarsens
resolution 2⁻¹⁵→2⁻¹¹ — a noise floor invisible on a plot. Dropping the top 4 would
collapse the range to ±1 and clip every peak. *Preserve dynamic range, sacrifice
precision.* (Truncation is floor, a sub-1-LSB bias, irrelevant for a display.)

**(b) Forward only the 9 unique bins.** Bins `0…SIZE/2` (0…8 for N=16) are forwarded;
bins 9…15 are **consumed-and-discarded** — the block still accepts them off the bus
(so the free-running FFT never stalls) but emits no word. `TLAST` is asserted on bin
`SIZE/2` (bin 8). Output: a **9-word frame** of 32-bit values.

Flow-control detail: `s_tready = m_tready when keep else '1'` — drop-bins are always
accepted; kept bins propagate the FIFO's back-pressure upstream. The counter
resyncs on the incoming `TLAST`, so bin alignment self-heals each frame.

---

## 7. Stage 5 — `axi_fifo_mm_s` : buffer + AXI4-Lite hand-off to the CPU

The Xilinx **AXI4-Stream FIFO** (`axi_fifo_mm_s`, *not* `axis_data_fifo`) — chosen
because it has both an AXI4-Stream **slave** (data in) and an **AXI4-Lite** register
interface the CPU reads through. No DMA.

**In:** AXIS slave `AXI_STR_RXD` (32-bit, from `axis_repack.m`), `s_axi_aclk`,
`s_axi_aresetn`.
**Out / control:** `S_AXI` (AXI4-Lite) → `microblaze_0/M_AXI_DP` via the AXI
interconnect. Mapped at base **`0x0001_1000`** (4 KB), symbol
`XPAR_AXI_FIFO_MM_S_0_BASEADDR`. The transmit side (`AXI_STR_TXD/TXC`) and
`interrupt` are unused — data only flows FFT→CPU, and the CPU **polls**.

The FIFO absorbs one 9-word frame on the stream side; software reads it out through
the receive registers (offsets from the base):

| Reg | Offset | Meaning |
|---|---|---|
| `RDFO` | 0x1C | receive FIFO occupancy (words available) |
| `RDFD` | 0x20 | receive data — each read pops one 32-bit word |
| `RLR`  | 0x24 | receive length — bytes in the packet at the head |

With the bundled `XLlFifo` driver: `XLlFifo_iRxOccupancy()` / `XLlFifo_RxGetLen()`
(returns 36 bytes = 9 words) / `XLlFifo_RxGetWord()`.

FIFO depth is a parameter, sized ≥ one frame (9 words for N=16; 129 for N=256).

---

## 8. Stage 6 — MicroBlaze software (Day 11 H4, in progress)

**In:** the FIFO's AXI4-Lite registers at `0x0001_1000`.
**Out:** bytes to `uart_tx`.

Polling loop: wait until a full packet is present (`RLR`/occupancy), read the 9
words from `RDFD`, and stream them out the UART. Software owns framing and pacing —
it decimates to the display rate (§9) rather than sending all 62,500 frames/s. This
is also where any host-protocol framing (sync word, sequence count) would live.

---

## 9. Stage 7 — `uart_tx` (Day 11 H4) and Stage 8 — Python host (Day 11 H5)

**`uart_tx`** (verified prior work): 8-N-1 at **115200 baud**, driven by
`tx_start`/`data_in[7:0]`/`tx_busy` — directly software-drivable. Per the locked
decision the custom `uart_tx` is wrapped behind AXI rather than replaced with AXI
UARTlite. Each 32-bit word is 4 UART bytes.

**Python host** (`pyserial` + `matplotlib`): reads the byte stream, reassembles
32-bit words, splits each into two **signed 16-bit** halves (real, imag), scales
each by 2⁻¹¹ to recover the Q5.11 value, computes the magnitude
`|X[k]| = sqrt(re² + im²)`, and plots the 9-bin spectrum. Absolute scale is
arbitrary for a plot, so calibration is optional.

---

## 10. Clocking, reset, and flow control

- **Single clock domain:** `xadc_daq.dclk_in`, `xadc_axis_framer.clk`,
  `fft_axis.ap_clk`, `axis_repack.clk`, and `axi_fifo_mm_s.s_axi_aclk` are all on the
  Clocking Wizard's **100 MHz `clk_out1`** (with the MicroBlaze and interconnect).
  No CDC.
- **Reset polarity:** the three RTL modules (`xadc_daq`, `xadc_axis_framer`,
  `axis_repack`) take the Processor System Reset's **`peripheral_reset`**
  (active-high); the AXI/HLS blocks (`fft_axis.ap_rst_n`, the FIFO and interconnect
  `aresetn`) take **`peripheral_aresetn`** (active-low). Both are synchronized
  releases of the same reset.
- **Back-pressure end-to-end:** every hop is AXI-Stream `TVALID`/`TREADY`. If the
  FIFO fills (CPU slow to drain), `TREADY` deasserts and the stall propagates back
  through `axis_repack` (for kept bins) and the framer, holding data rather than
  dropping it. In normal operation the XADC rate is far below the FFT/FIFO rate, so
  the pipeline is essentially always ready.

---

## 11. Throughput budget

| Point | Rate |
|---|---|
| XADC sampling | ~1 MSPS |
| FFT frames (16 samples/frame) | ~62,500 frames/s |
| FFT capacity (interval 20 cyc @ 100 MHz) | ~5,000,000 frames/s (≫ input) |
| Repack output (9 words/frame, all frames) | ~562,500 words/s ≈ 2.25 MB/s |
| UART link (115200 8-N-1) | ~11,520 B/s ≈ 320 words/s |

The UART is the bottleneck **by design** — but a spectrum plot only needs ~10–30
updates/s. Software decimates (e.g. 30 frames/s × 36 bytes ≈ 1.1 kB/s, comfortably
under the link), so the UART caps *display refresh*, never the sampling or FFT.
Frequency resolution: `Fs/16 = 1 MSPS / 16 ≈ 62.5 kHz/bin`, Nyquist 500 kHz.

---

## 12. Address map

| Segment | Base | Size | Notes |
|---|---|---|---|
| Local memory (I/D) | `0x0000_0000` | 32 KB | MicroBlaze code + data (LMB) |
| `axi_fifo_mm_s_0` `S_AXI` | `0x0001_1000` | 4 KB | FIFO registers (RDFO/RDFD/RLR) |

---

## 13. Scaling to N = 256 (the endgame)

The periphery scales by configuration: `xadc_axis_framer.FRAME = 256`,
`axis_repack.SIZE = 256` (→ 129 unique bins, `TLAST` on bin 128), FIFO depth ≥ 129
words. `FRAME` must always equal the FFT `SIZE`. The real work is inside the **FFT
core** (refactor to 8 stages, 128-entry twiddle ROM, fix Q5.15 overflow at N=256 via
a wider type or per-stage scaling, re-verify). At N=256 the "carry only unique bins"
choice matters most — it halves FIFO/BRAM and UART traffic exactly where they get
tight. Bin spacing becomes `Fs/256 ≈ 3.9 kHz`.

---

## 14. Status

| Stage | Status |
|---|---|
| Analog conditioning (external) | Documented; hardware is the user's |
| `xadc_daq` / `daq_sampler` | Built, conversion unit-verified (6/6), synth-clean |
| `xadc_axis_framer` | Built + verified (framing + back-pressure) |
| `fft_axis` | Built + fully verified (10k-frame differential, cosim) |
| `axis_repack` | Built + verified (18 words/2 frames incl. back-pressure) |
| `axi_fifo_mm_s` + BD wiring | Wired into `daq_bd`, **Validate clean** (Day 11 H3) |
| MicroBlaze C + `uart_tx` | **Day 11 H4 — next** |
| Python host | Day 11 H5 |

_Companion to `docs/hls_engineering_log.md` (§11), `docs/verification_methodology.md`,
`docs/controller_verification.md`._
