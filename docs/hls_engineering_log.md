# Mini-DAQ HLS FFT — Engineering Log & Interview Prep

**What this document shows:** an honest, blow-by-blow record of building the
16-point FFT in Vitis HLS — what was built, every problem hit, what was tried,
how each was fixed, and exactly what each directive did and saved. It is the
narrative/"story" doc; the raw before/after synthesis tables live in the
companion `hls_synthesis_results.md`. Written so the decisions can be defended
from memory (e.g. in an interview).

---

## 1. What was built

A 16-point, radix-2 decimation-in-time FFT as an HLS **dataflow** pipeline:

```
input -> bit_reverse -> stage1 -> stage2 -> stage3 -> stage4 -> output
```

- Split into 5 concurrent processes (bit-reverse + 4 butterfly stages),
  connected by intermediate buffers.
- Twiddle factors in a precomputed **ROM** (no runtime sin/cos).
- Number format **Q5.15 fixed-point** (`ap_fixed<20,5>`).
- Inner butterfly loop pipelined at **II=1**.
- Target **XC7A35T-FTG256-1**, 100 MHz.
- Verified by C simulation against the Python golden model's test vectors.

Files: `fft.h`, `fft_dataflow.cpp` (stages + top), `bit_reverse.cpp`
(`reverse_bits` + in-place `bit_reverse`), `fft_tb.cpp` (testbench),
`run_hls.tcl` (build script).

---

## 2. Directives used — what each did and what it saved

### 2.1 `#pragma HLS dataflow` (top-level function)
**What it does:** turns the sequence of stage-function calls into concurrent
processes that run at the same time on different data, connected by
handshaked buffers (ping-pong / PIPO memories that HLS inserts automatically).
**What it saved:** without it, the stages run one-after-another and throughput
= sum of all stage latencies. With it, the stages overlap so throughput is set
by the **slowest single stage**, and successive FFT frames pipeline through the
4 stages. This is *task-level* (coarse-grain) pipelining.
**Evidence:** synthesis log — "Applying dataflow ... detected/extracted 5
process functions"; buffers implemented as PIPO.

### 2.2 `#pragma HLS PIPELINE II=1` (inner butterfly loop)
**What it does:** overlaps successive iterations of the butterfly loop so a new
butterfly starts every clock cycle (Initiation Interval = 1). This is
*operation-level* (fine-grain) pipelining, nested inside the coarse dataflow.
**What it saved:** without it, each butterfly finishes before the next starts,
so the effective II equals the butterfly's latency (its "Depth"). With it, II
drops to 1 — roughly a **Depth-times throughput improvement** on the loop.
**Evidence:** synthesis reported `Final II = 1` on every stage's loop.
**Why no ARRAY_PARTITION was needed:** each array (in_R, in_I, out_R, out_I)
sees only 2 accesses per cycle, which a standard 2-port BRAM already supplies —
so II=1 was reachable without splitting memories. (Partitioning would only be
needed if the butterflies were *unrolled* to run several per cycle.)

### 2.3 Twiddle ROM (design change, enables clean synthesis)
**What it does:** the 8 distinct W16 twiddle values are stored in a `static
const` array. HLS synthesizes it as a small ROM and each stage indexes it by
`j * (SIZE >> stage)`.
**What it saved:** replaced runtime `cos()`/`sin()`, which HLS would implement
as a large, slow floating-point trig core. The ROM is a handful of constants
and a lookup.
**Evidence:** synthesis log — "Implementing memory ..._TW_R_rom using auto ROMs".

### 2.4 `reverse_bits` fully unrolled (automatic, but by design)
**What it does:** the bit-reversal loop is written to be fully unrolled; when it
is, each output bit is just a specific input bit.
**What it saved:** it collapses to pure **wiring with zero logic / near-zero
latency**, instead of a sequential shift/OR loop whose latency scales with the
bit count. HLS unrolled it automatically (factor 4 = FFT_BITS) when pipelining
the parent loop.

### 2.5 Loop-flatten + `LOOP_TRIPCOUNT` (applied)
Each stage's two nested loops were rewritten as a single flat loop over all
N/2 = 8 butterflies, with `#pragma HLS PIPELINE II=1` and
`#pragma HLS LOOP_TRIPCOUNT min=8 max=8`.
**What it did:** the nested loops weren't a perfect nest (twiddle reads sat
between them), so HLS pipelined only the inner loop and stage 4 paid a pipeline
fill per butterfly (~48 cycles). The flat loop gets one fill.
**What it saved:** stage 4 dropped ~48 -> 14 cycles; stages balanced to
10/14/14/14 (bit_rev 18); top-level latency resolved to 74 cycles, interval 19.
And less control logic: LUT 1587 -> 1350 (-15%), FF 2078 -> 1668 (-20%).
The constant loop bound (8) also resolved the previously-`?` latency report,
making the `LOOP_TRIPCOUNT` redundant but kept as documentation.

### 2.6 Pending directive (understood, not yet applied)
- `ap_ctrl_chain` interface — enables frame-to-frame overlap so consecutive
  FFTs pipeline (needed for a continuous streaming DAQ; see 3.8).

---

## 3. Problems hit and how they were solved (chronological)

### 3.1 Baseline code synthesizes to poor hardware
**Symptom / understanding:** the pp4fpgas "typical software" FFT compiles but
would give slow, huge hardware — runtime `cos`/`sin`, no interface or
optimization pragmas, in-place single arrays with port pressure.
**Action:** treated it as a *starting point*, not the deliverable. Rebuilt it as
the dataflow architecture (Fig 5.7 idea) with separate stage functions.

### 3.2 Needed a functional reference before optimizing
**Action:** used the Python golden model (direct DFT + radix-2 + Q1.15) and its
exported test vectors as the source of truth. Wrote a C testbench that runs the
FFT, computes bin magnitudes, and diffs them against the golden `mag:` values.
Verified 4/4 vectors pass *before* touching pragmas. (Correct-first, fast-second.)

### 3.3 Vitis rejects project paths containing spaces
**Symptom:** `ERROR: [HLS 200-70] Project/solution path '...Wadhwani Lab
Research/Mini DAQ/...' contains illegal character ' '.`
**Cause:** Vitis shells out to compilers/tools whose command lines break on
unquoted spaces, so it forbids spaces in the project path outright.
**What was tried:** running directly in the OneDrive project folder — failed.
**Fix:** created a space-free scratch build folder `C:\hls_minidaq`, copied the
sources there, and ran `vitis_hls -f run_hls.tcl` from there. Source of truth
stays in the project folder; the scratch folder is just for building.

### 3.4 apcc miscompiles `strtod` in the testbench
**Symptom:** `error: conflicting types for '__strtod'` during csim compile.
**Cause:** a known Vitis HLS quirk — its bundled compiler (`apcc`) generates a
conflicting declaration for a few libc functions, `strtod` among them.
**Fix:** rewrote the testbench parser to read numbers with `fscanf` instead of
`strtod`. csim then compiled and passed 4/4.

### 3.5 Float design is DSP-bound (does not fit)
**Symptom:** first csynth (32-bit float) used **90 DSP48s** — 200% of the
XC7A15T (45 DSP) and 100% of the XC7A35T (90 DSP), plus 86% LUT.
**Cause:** floating-point multipliers/adders are DSP-hungry (a float multiply
~3 DSP, float add ~2), and the FFT has many.
**Fix:** switched the datapath type to **fixed-point** — the project's planned
Q1.15/Q5.15 decision. This is an *area* fix (type change), distinct from the
*throughput* fixes (the pipeline/dataflow directives).

### 3.6 `ap_fixed` is C++-only; project was C
**Symptom:** VS Code `cannot open source file "ap_fixed.h"` (cosmetic include
path) — but the real blocker is that `ap_fixed` is a C++ template and the files
were `.c` (compiled as C, no templates).
**Fix:** converted the HLS sources from `.c` to `.cpp` (standard for any HLS
design using `ap_fixed`/`ap_int`/`hls::stream`) and pointed the tcl at the
`.cpp` files. Algorithm unchanged.

### 3.7 A naive `ap_fixed<16,1>` would overflow
**Symptom / analysis:** Q1.15 (`ap_fixed<16,1>`) has range [-1, 1), but the FFT
sums grow with bit-growth — the DC bin reaches 8.0. That would overflow/wrap.
**Fix:** used **Q5.15 (`ap_fixed<20,5>`)**, range [-16, 16) — the 5 integer bits
hold the growth, matching the design-notes "16->20 bits over 4 stages" plan.
**Verification:** pre-checked in an ap_fixed emulation and confirmed in Vitis
csim: 4/4 pass, max error 0.0001, **peak value 8.0 < 16** (2x headroom).

### 3.8 "dataflow-on-top ... ap_ctrl_hs" warning
**Symptom:** `WARNING [HLS 200-786] ... Overlapped execution of successive
kernel calls will not happen unless interface mode 'ap_ctrl_chain' is used.`
**Meaning:** the 4 stages overlap *within* one FFT call, but consecutive FFT
frames don't yet overlap. For a continuous streaming DAQ we'd switch the
top-level control to `ap_ctrl_chain`. Noted as a follow-up; fine for now.

### 3.9 Stage 4 is the throughput bottleneck ("cannot flatten") — RESOLVED
**Symptom:** `WARNING [HLS 200-960] Cannot flatten loop ... the outer loop is
not a perfect loop` on stages 2-4.
**Cause:** the two stage loops aren't a perfect nest (the twiddle ROM reads sit
between the outer and inner loop), so HLS pipelines only the inner loop. Stage
4's inner loop runs once, so its 8 butterflies live in the outer loop and each
pays a fresh pipeline fill — making stage 4 the slowest stage.
**Fix (done):** rewrote each stage as a single flat 8-iteration loop (deriving
the twiddle position and indices from one counter). The warnings disappeared,
stage 4 dropped ~48 -> 14 cycles, stages balanced (10/14/14/14), and LUT/FF
dropped ~15-20%. csim still 4/4. (See 2.5.)

### 3.10 Latency reported as `?` — RESOLVED
**Symptom:** top-level and stages 2-4 show `?` for latency/interval.
**Cause:** the loop bounds vary with `stage`, so HLS can't statically bound
them (the same TRIPCOUNT situation the pp4fpgas text describes).
**Fix (done):** the loop-flatten made the loop bound a compile-time constant
(8), which by itself resolved the `?` (top latency 74, interval 19).
`#pragma HLS LOOP_TRIPCOUNT min=8 max=8` was added as documentation.

### 3.11 "out of bound array access" warnings
**Symptom:** HLS 214-167 on the butterfly array writes.
**Analysis:** false alarms — `i_lower = i + numBF` is always < 16; csim passing
confirms no real overflow. Can be silenced later with an `assert` on the index.

### 3.12 `SIZE` macro collides with `hls_stream.h` template (Day 8)
**Symptom:** csim of the AXI-Stream version failed to compile:
`error: expected '>' before numeric constant` pointing at `#define SIZE 16`,
expanded inside `hls_stream_thread_unsafe.h`'s `template<size_t SIZE>`.
**Cause:** `fft.h` did `#define SIZE 16` and then `#include "hls_stream.h"`
*after* it. The preprocessor textually replaced the header's `SIZE` template
parameter with `16`, producing `template<size_t 16>` -- nonsense. `SIZE` is too
generic a macro name.
**Fix (done):** moved `#include "hls_stream.h"` and `#include "ap_axi_sdata.h"`
to the top of `fft.h`, *above* `#define SIZE`, so the headers are parsed while
`SIZE` is still an ordinary identifier. Streaming logic was unaffected.
**Cleaner long-term fix (deferred):** rename the macro `SIZE` -> `FFT_SIZE`
everywhere to avoid the collision entirely.
**Lesson:** include third-party/library headers before defining short, common
macro names; or namespace your macros (`FFT_SIZE`).

### 3.13 `export_design` fails: "bad lexical cast" on `core_revision` (Day 8)
**Symptom:** csim/csynth/cosim all PASS, but `export_design` errored at the very
end:
`rdi::set_property core_revision 2607161630 ...` -> `bad lexical cast: source
type value could not be interpreted as target` -> `ERROR [IMPL 213-28] Failed to
generate IP.`
**Cause:** a Vitis HLS 2020.2 date bug, *not* a design bug. When packaging the
IP, Vivado stamps a `core_revision` built from the current date/time as
`YYMMDDHHMM` — here `2607161630` (year **26**, 07/16, 16:30). That value is
stored in a **32-bit signed integer**, whose max is 2,147,483,647. In 2026 the
revision (2,607,161,630) exceeds it and overflows, so the Tcl `set_property`
cast fails. In 2020-2021 the stamp was ~`20xxxxxxxx` and fit; the tool simply
predates today's date. No `export_design` flag overrides `core_revision`.
**Fix (done):** temporarily set the Windows clock back to **2021-01-01** (turn
off "set time automatically"), re-ran `vitis_hls -f run_hls.tcl`, then restored
the clock. The revision became `2101010000`, fit in 32 bits, and packaging
completed: `Generated output file .../sol1/impl/export.zip`. The sim log
timestamps reading "2021" confirm the workaround was active.
**Lesson:** old vendor tools can carry Y2K-style integer-overflow bugs tied to
wall-clock date; a temporary clock roll-back is the standard workaround (restore
it immediately after — a backdated clock disturbs OneDrive sync and git commit
times). Alternatively, a newer Vitis (2022.1+) fixes it.

---

## 4. Verification methodology (how correctness was ensured)

1. **Golden model first** — Python direct DFT (O(N^2), obviously correct) +
   radix-2 + Q1.15 fixed-point, cross-checked against NumPy.
2. **Test vectors** — DC, single sine (bin 3), two-tone (bins 3 & 5), impulse;
   input as Q1.15 integers, expected output magnitudes as float reference.
3. **C simulation (csim)** — runs the HLS FFT on each vector, computes bin
   magnitudes, diffs vs golden with a tolerance; returns non-zero on any fail
   so the tool flags it.
4. **Pre-checks** before Vitis — compiled and ran with gcc/g++ against a direct
   DFT and against an `ap_fixed` emulation to catch bugs and confirm the Q5.15
   range was sufficient, before spending a Vitis run.
5. **csynth** — read timing (Fmax), II per loop, and utilization; used the
   utilization table to prove the fixed-point design fits.

### 4.1 Are 4 vectors enough? Coverage gaps + randomized differential test

**Honest verdict: the 4 curated vectors are a strong *smoke test*, not a
correctness sign-off.** What they do cover is better than it looks — the
**impulse** exercises every twiddle multiply and every butterfly path (an impulse
excites all frequencies), **DC** stresses the worst-case bit-growth (this is how
the 8.0 peak was found), **two-tone** checks linearity/superposition, and the
**single sine** checks that energy lands in the correct bin. But they are not
enough to call the FFT verified. The gaps:

1. **Magnitude-only comparison.** The testbench diffs `|X[k]|`, so a sign flip or
   any phase error that preserves magnitude would pass all four. Fix: compare
   **real and imag** (or magnitude *and* phase).
2. **No input-space coverage.** Four fixed, "clean" patterns. Fixed-point
   correctness is really about rounding/quantization-error accumulation on
   *arbitrary* inputs — untested by these four.
3. **No boundary/overflow testing.** Inputs never pushed near ±full-scale, so
   saturation/overflow behavior at the Q5.15 edges is unexercised.
4. **Missing bins.** Tested bins 3 and 5; never bin 1 or the Nyquist bin (8).
5. **cosim added no input coverage** — it re-ran the *same* four inputs as RTL
   vs C, which proves RTL==C but not correctness over more inputs.

**Planned enhancement — randomized differential test (csim).** Add a self-checking
harness to the C testbench that compares the DUT against a trusted reference over
thousands of random frames:

- **Reference** = a double-precision direct O(N²) DFT (obviously correct; same
  unnormalized definition as the Python golden model, which itself is cross-checked
  vs NumPy). The DUT is the fixed-point HLS FFT.
- **~10,000 seeded-random frames**, inputs bounded `|x| <= 0.5` so the DC bin
  (≤ N·0.5 = 8) stays inside Q5.15's ±16 — no overflow masking real errors.
- **Compare real AND imag** (closes the phase gap), track the worst absolute
  error over all frames and bins, assert `< TOL`.
- **Compare against the DFT of the *quantized* input** (feed the same quantized
  values into the reference), so the metric isolates the FFT's internal
  fixed-point error from input-quantization error.
- **Add explicit stress frames:** near-full-scale all-positive / all-negative
  (bounded so DC < 16), impulse, DC, single tones at **bin 1 and the Nyquist
  bin**, plus a **Parseval invariant** check (`Σ|X[k]|² = N·Σ|x[n]|²`).
- **Tolerance from LSB analysis:** Q5.15 LSB = 2⁻¹⁵ ≈ 3.05e-5; error accumulates
  over the 4 stages, so expect worst ≈ 1e-3…1e-2 — set generous, then tighten to
  the measured worst.
- **Where it runs:** the 10k volume runs in **csim** (seconds on CPU); **cosim**
  keeps the 4 curated vectors plus ~a dozen random frames as a spot check (RTL
  sim is far too slow for 10k).

Sketch:

```cpp
#include <cmath>
#include <cstdlib>

// trusted reference: naive O(N^2) DFT in double
static void ref_dft(const double xr[SIZE], const double xi[SIZE],
                    double Xr[SIZE], double Xi[SIZE]) {
  for (int k = 0; k < SIZE; k++) {
    double sr = 0, si = 0;
    for (int n = 0; n < SIZE; n++) {
      double a = -2.0 * M_PI * k * n / SIZE, c = cos(a), s = sin(a);
      sr += xr[n]*c - xi[n]*s;
      si += xr[n]*s + xi[n]*c;
    }
    Xr[k] = sr; Xi[k] = si;
  }
}

int random_diff_test() {
  const int NTRIAL = 10000; const double AMP = 0.5, TOL = 5e-3;
  srand(12345);                                  // reproducible
  double worst = 0;
  for (int t = 0; t < NTRIAL; t++) {
    double xr[SIZE], xi[SIZE]; DTYPE in_R[SIZE], in_I[SIZE], out_R[SIZE], out_I[SIZE];
    for (int n = 0; n < SIZE; n++) {
      double v = ((double)rand()/RAND_MAX*2 - 1) * AMP;
      in_R[n] = (DTYPE)v; in_I[n] = (DTYPE)0;    // quantize to Q5.15
      xr[n] = (double)in_R[n]; xi[n] = 0.0;      // reference sees the QUANTIZED input
    }
    double Xr[SIZE], Xi[SIZE]; ref_dft(xr, xi, Xr, Xi);
    run_dut(in_R, in_I, out_R, out_I);           // pack->fft_axis->unpack (reuse existing tb helper)
    for (int k = 0; k < SIZE; k++) {
      worst = fmax(worst, fabs((double)out_R[k] - Xr[k]));
      worst = fmax(worst, fabs((double)out_I[k] - Xi[k]));
    }
  }
  printf("random-diff: %d frames, worst|err|=%.6f (tol %.4f) -> %s\n",
         NTRIAL, worst, TOL, worst < TOL ? "PASS" : "FAIL");
  return worst < TOL ? 0 : 1;
}
```

`run_dut()` is the pack-into-stream / call `fft_axis` / pop-output helper the
existing streaming testbench already contains. **Status: DONE (run 2026-07-21).**
Implemented in `fft_tb_axis.cpp` (`run_dut`/`ref_dft`/`check_frame`/
`random_diff_test`/`boundary_test`). Result: csim 10,000 random frames worst
**4.6 LSB**, Parseval residual < 6.1e-5, six boundary/corner frames pass (worst
4.1 LSB), tolerance calibrated to 3e-4; cosim of 16 random + 4 directed + 6
boundary frames **C/RTL PASS** (worst 3.2 LSB). The FFT is fully verified.
Interview framing: *"Four targeted vectors plus cosim were a smoke test; to fully
sign it off I'd add randomized differential testing against the golden model,
compare complex (not just magnitude), and stress the fixed-point range at the
boundaries plus a Parseval check."*

### 4.2 The four vectors — what each one tests

Each vector was chosen to exercise a *different* behavior of the FFT, so together
they form a quick but broad smoke test. Bin numbering is 0…15; for a **real**
input, the spectrum is conjugate-symmetric, so a tone at bin `k` also appears
mirrored at bin `N−k`.

**1. DC — constant input.** `x[n] = 0.5` for all n (a flat, zero-frequency
signal).
- *Expected:* all energy in **bin 0**; `X[0] = Σx[n] = 16 × 0.5 = 8.0`, every
  other bin ≈ 0.
- *What it tests:* (a) the **accumulation path** — bin 0 is literally the sum of
  all inputs; (b) **worst-case bit-growth** — the DC bin is the largest output the
  transform can produce, so it's where overflow first appears. This vector is what
  proved a plain Q1.15 (±1) would overflow and drove the move to **Q5.15** (peak
  8.0 sits safely inside ±16); (c) **cancellation** — every non-DC bin must sum to
  zero, which only happens if the twiddle signs/symmetry are correct.

**2. Single sine — pure tone at bin 3.** `x[n] = sin(2π·3·n/16)`.
- *Expected:* energy concentrated at **bin 3** (and its real-input mirror, bin 13);
  all other bins ≈ 0.
- *What it tests:* **frequency localization and twiddle correctness** — a single
  frequency must land in exactly the right bin. If the twiddle factors (the
  `W = e^{-j2πkn/N}` rotations) were wrong, the energy would smear across bins or
  land in the wrong one. Also confirms the **conjugate symmetry** expected of a
  real input.

**3. Two-tone — bins 3 and 5 together.** `x[n] = sin(2π·3·n/16) + sin(2π·5·n/16)`.
- *Expected:* two clean peaks, at **bins 3 and 5** (mirrors at 13 and 11).
- *What it tests:* **linearity / superposition** — the FFT of a sum must equal the
  sum of the FFTs, and two simultaneous frequencies must resolve into two *separate*
  bins with no cross-talk. A nonlinear bug (e.g. an overflow wrap or a bad
  intermediate rounding) would create spurious "intermodulation" bins that
  shouldn't be there. Also a basic **bin-resolution** check.

**4. Impulse — unit sample.** `x[0] = <value>`, `x[n] = 0` for n ≠ 0.
- *Expected:* a **flat spectrum** — `|X[k]|` is the *same constant* across all 16
  bins, because the DFT of a delta is flat.
- *What it tests:* the best **structural coverage** of the four — an impulse
  contains every frequency equally, so *every* output bin is non-zero and *every*
  twiddle multiply and butterfly path is exercised in one shot. Because the
  expected answer is a known flat line, any single broken butterfly or twiddle
  shows up immediately as one bin that deviates. It also checks the
  **bit-reversal / data routing** (the lone non-zero sample has to reach every
  stage correctly).

**Why these four together:** they deliberately span four distinct failure
surfaces — accumulation + bit-growth (DC), frequency placement + twiddles (sine),
linearity (two-tone), and whole-datapath structural coverage (impulse). That's why
they're a good *smoke test*; §4.1 explains why they still aren't a full sign-off.

### 4.3 Verification taxonomy — is this "formal verification"? (where this project sits)

**No — none of this is formal verification.** It is *simulation-based functional
verification*. The two are different families and the distinction matters in an
interview, so it's captured here.

**Formal verification** = using mathematical methods to **prove or disprove** that a
design meets a formal specification, **exhaustively over all inputs/states**,
*without running test cases*. It reasons symbolically about every behavior at once
and returns a proof or a counterexample. The key word is *exhaustive*: simulation
*samples* the input space, formal *covers* it. (Dijkstra: "testing shows the
presence, not the absence, of bugs.") For context, sampling really is a tiny
fraction here — the input space of a 16-point Q5.15 frame is 2^(16×20) ≈ 10^96
possible frames, so even 10k random frames is a vanishing slice.

Formal comes in three hardware families:
- **Equivalence checking (LEC):** proves two representations compute the *same*
  function for all inputs (e.g. RTL vs synthesized gate netlist — standard ASIC
  sign-off).
- **Model / property checking (FPV):** proves temporal properties written as
  assertions (SVA/PSL) hold across all reachable states, or returns a counterexample
  (JasperGold, VC Formal).
- **Theorem proving:** interactive mathematical proof of an algorithm (ACL2, Coq,
  Isabelle) — how some FPUs/DSP kernels are proven at the math level.

**What this project actually is — simulation-based (dynamic) functional
verification:** the 4 curated vectors are **directed testing**; the planned random
harness (§4.1) is **constrained-random** testing, and because it checks the DUT
against an independent reference it is **differential / golden-model** testing.
**cosim is co-simulation** — it checks RTL-vs-C equivalence, but *by simulating both
on the same stimulus*, so it is still dynamic, **not** formal equivalence checking.
All of it samples inputs and yields *statistical* confidence, never a proof of
absence.

**Could an FFT be formally verified, and why simulation is the norm?** In principle,
parts could: equivalence-check the HLS RTL against the HLS C model, or property-check
"no overflow given bounded inputs"; specialized **datapath / word-level** formal
tools exist for arithmetic blocks (multipliers, MACs, fixed-point pipelines) because
bit-level model checkers choke on wide arithmetic. But full formal proof of a
fixed-point FFT is genuinely hard, which is *why* industry verifies DSP blocks by
simulation-with-a-reference. The obstacle is the fixed-point rounding: the Q5.15 FFT
is deliberately **not bit-exact** to the ideal DFT — it is *approximately* equal,
within an error bound. Equivalence checking proves *exact* equality, so it doesn't
apply against a floating reference; and proving a *bounded-error* property ("output
always within k LSB of the true DFT") over a wide arithmetic datapath is exactly the
quantitative, real-valued property formal tools struggle with. Simulation with a
golden model sidesteps this — it *measures* the actual error empirically across many
inputs, cheaply, and yields a concrete worst-case number.

**Interview answer to "did you formally verify it?"** *"No — I used simulation-based
functional verification with a reference model (directed + constrained-random +
differential, plus co-simulation for C/RTL behavioral equivalence). Formal
verification — equivalence checking or property proving — is the next rung; it's a
poor fit for the fixed-point datapath because the design is approximate-by-design,
but it would help on bounded properties like no-overflow or on C-to-RTL equivalence
of the control logic."*

---

## 5. Results (measured)

Three synthesis runs, in order: **Run 1** float baseline (dataflow + pipeline +
twiddle ROM) -> **Run 2** switch to Q5.15 fixed-point -> **Run 3** loop-flatten.
5.a compares Run 1->2 (area); 5.b compares Run 2->3 (latency/balance).
(Full reasoning also in `hls_synthesis_results.md`.)

### 5.a  Float baseline vs Q5.15 fixed-point (the AREA win)

| Metric          | Run 1: Float | Run 2: Q5.15 | Change             |
|-----------------|--------------|--------------|--------------------|
| DSP48           | 90           | 12           | -87% (7.5x fewer)  |
| LUT             | 8,986        | 1,587        | -82%               |
| FF              | 13,982       | 2,078        | -85%               |
| BRAM_18K        | 0            | 0            | —                  |
| Estimated Fmax  | 168 MHz      | 152 MHz      | both > 100 MHz     |
| Butterfly depth | 21 cycles    | 6 (stg1: 2)  | ~3.5x shorter      |
| csim            | 4/4 pass     | 4/4 pass     | both correct       |

**Why it changed:** float multiply/add cores each eat several DSP48s plus large
mantissa align/normalize/round logic (LUT + FF); a Q5.15 (20-bit) multiply fits
one DSP48 and the adds go to LUTs — so DSP, LUT and FF all collapse. Fmax dips
slightly (168->152) because the float cores are very deeply pipelined (depth 21,
short per-stage paths, high clock ceiling) while the fixed MAC has fewer
pipeline registers (depth 6) and a marginally longer path — *educated guess*,
still > 100 MHz. On the XC7A35T this is **13% DSP / 7% LUT / 4% FF** vs float at
100% DSP, leaving ~7/8 of the fabric for the rest of the SoC. (Stage 1 uses
**0 DSP** — twiddle W^0 = 1, pure add/sub; stages 2-4 use 4 each.)

### 5.b  Q5.15 nested vs flattened loops (the LATENCY / BALANCE win)

| Metric             | Run 2: Nested    | Run 3: Flattened          |
|--------------------|------------------|---------------------------|
| DSP48              | 12               | 12  (unchanged)           |
| LUT                | 1,587            | 1,350  (-15%)             |
| FF                 | 2,078            | 1,668  (-20%)             |
| Estimated Fmax     | 152 MHz          | 152 MHz  (unchanged)      |
| Stage 4 latency    | ~48 (bottleneck) | 14                        |
| Per-stage latency  | ? / imbalanced   | 10 / 14 / 14 / 14 (bit_rev 18) |
| Top-level latency  | ? (unresolved)   | 74 cycles (0.74 us)       |
| Top-level interval | ?                | 19 cycles                 |
| csim               | 4/4 pass         | 4/4 pass                  |

**Why it changed:** DSP is unchanged because the flatten only alters loop
*control*, not the arithmetic. LUT/FF drop because one flat loop needs a single
counter and one pipeline fill instead of two counters, strided addressing, and
a fill/drain repeated per outer iteration — less control logic and fewer flush
registers (*educated guess*). Stage 4 falls ~48->14 because the nested loops
weren't a perfect nest, so HLS pipelined only the inner loop and stage 4 (inner
trip = 1) paid a pipeline fill per butterfly; the flat loop pays one fill, so
all stages balance. And the constant loop bound (8) let HLS finally compute the
latency that was `?` before.

---

## 5.c  Cosim — RTL verification (Day 8, Hour 1)

Ran `cosim_design`: the generated Verilog RTL was simulated in xsim, driven by
the same self-checking C testbench. **Result: `C/RTL co-simulation PASS`** (4/4
vectors, pre- and post-sim C checks). This is the step that proves HLS built
what the C meant — csim only ran the C on the CPU; cosim ran the actual
hardware. It also confirmed the estimates with a real sim: measured interval
= **19 cycles** (transactions 190 ns apart) and latency ~76 ≈ the 74 estimate,
deadlock detector clean. So 74/19 are now measured, not estimated.

## 5.d  AXI-Stream version — synth + cosim (Day 8, Hours 2-3)

Wrapped `fft_dataflow` in an AXI4-Stream top (`fft_axis`); re-synthesized and
cosim'd. **csim + cosim PASS 4/4.** The top-level ports are now real AXIS
(`in_r/out_r: TDATA[40]/TVALID/TREADY/TLAST/TKEEP[5]/TSTRB[5]`), replacing the
old `ap_memory` ports — the goal of the conversion. Area: DSP unchanged (12),
LUT 1350->1684, FF 1668->1854 (the ~+334 LUT / +186 FF is the wrapper: read/write
loops, pack/unpack, handshake FSM), Fmax still 152 MHz, fits at 13%/8%/4%.
**Open item (Hour 4):** top-level interval regressed 19 -> 113 cycles because
`fft_axis` does read -> compute -> write in sequence under `ap_ctrl_hs` (no frame
overlap). Fix with `ap_ctrl_chain`/`none` + making `fft_axis` a dataflow region.
Full numbers: `docs/hls_synthesis_results.md` section 5.d.

## 6. Known remaining work (honest status)

- **AXI-Stream interface: DONE** (Hours 2-3) — synth + cosim PASS, AXIS ports.
- **Restore frame throughput: DONE** (Hour 4) — `fft_axis` dataflow region,
  interval 113 -> 20, cosim PASS. (See 8.1.)
- **`ap_ctrl_none` free-running control: DONE** (Hour 4) — csynth + cosim PASS,
  `ap_start/done/idle/ready` removed, HLS 200-786 warning cleared. (See 8.2.)
- **`export_design` — Vivado IP packaged: DONE** (Hour 4) — `export.zip`
  generated after working around the 2020.2 date-overflow bug (see 3.13).
- Later: per-stage bit-growth types (vs the single uniform Q5.15), scale N to 64-256.

**HLS track status: COMPLETE.** verified -> csynth -> Q5.15 -> loop-flatten ->
AXI-Stream -> dataflow throughput -> free-running -> IP export, every stage
cosim-PASS. Next project phase is Vivado block-design / SoC integration (and, in
parallel, the hand-RTL FFT that is the portfolio centerpiece).

---

## 7. Likely interview questions (and the honest answers)

- **"Why fixed-point and not float?"** Float was correct but used 90 DSP and
  maxed the chip; Q5.15 cut it to 12 DSP (13% of the device) with the same csim
  pass and equivalent accuracy (error ~1e-4). Measured, not assumed.
- **"What does the dataflow pragma actually do vs pipeline?"** Dataflow overlaps
  whole stages (coarse, task level, handshaked buffers); pipeline overlaps loop
  iterations within a stage (fine, cycle level, II). I used both, nested.
- **"How did you get II=1, and did you need array partitioning?"** Pipelined the
  butterfly loop; II=1 was reachable without partitioning because each array
  only needs 2 accesses/cycle, which a 2-port BRAM supplies. Partitioning is
  only needed when unrolling butterflies to run several per cycle.
- **"Why is one stage a bottleneck?"** The two loops aren't a perfect nest, so
  only the inner loop pipelines; stage 4's inner loop runs once, so it pays a
  pipeline fill per butterfly. Fix is to flatten to a single loop.
- **"Why the twiddle ROM?"** To avoid a runtime sin/cos core — the twiddles are
  known constants, so a small ROM lookup is far cheaper.
- **"How did you verify it?"** Python golden model -> test vectors -> csim diff,
  with gcc/ap_fixed pre-checks before each Vitis run.
- **"What would you do next / what's not done?"** See section 6 — I can name the
  exact remaining directives and integration steps and what each buys.

---

## 8. AXI-Stream interface — design decisions (Day 8, Hours 2-3)

The FFT was re-interfaced from memory-mapped array ports (`ap_memory`) to
AXI4-Stream so it can drop into the streaming DAQ pipeline (XADC -> FFT ->
MicroBlaze/DMA). Key decisions and why:

- **AXI4-Stream, not AXI4-Lite or full AXI4 memory-mapped.** The FFT datapath
  is a *stream*: samples are consumed in order, one after another, with no
  addressing. AXI4-Stream matches that exactly and sustains 1 beat/cycle with
  back-pressure — ideal for a continuous XADC feed.
  *Why not AXI4-Lite:* it is a single-word, register-oriented, memory-mapped
  interface meant for **control/status** (start/done/config), not bulk data — far
  too slow and semantically wrong for the sample stream.
  *Why not full AXI4-MM:* addressed bursts + IDs are machinery the FFT never
  needs (no random access to its input), so it would be pure overhead.
  *Ecosystem:* Xilinx DMA (MM2S/S2MM), AXIS FIFOs, and DSP IP all speak
  AXI-Stream, so this is the canonical `XADC -> FFT -> DMA -> MicroBlaze` flow.
  *Not either/or:* the final design will likely pair **AXI4-Stream for the data
  plane** with a small **AXI4-Lite control plane** (start/stop, Phase-4
  mode-select, status). Full AXI4-MM would only apply if the FFT had to master
  DRAM directly for large buffered transforms — not the case for N=16.

- **Wrap, don't rewrite.** Added a thin top wrapper `fft_axis` that does only
  stream I/O and calls the *unchanged, verified* `fft_dataflow` core.
  *Why:* the FFT math was already csim/cosim-verified; re-interfacing should not
  risk it. `fft_axis` = the loading dock; `fft_dataflow` = the assembly line.

- **40-bit TDATA = one complex Q5.15 sample per beat** (`data[19:0]`=real,
  `data[39:20]`=imag).
  *Why 40:* a Q5.15 value is 20 bits; a complex number is two of them = 40, the
  tightest fit. It is also byte-aligned (40 = 5 bytes), which AXI-Stream wants
  (TKEEP/TSTRB are 1 bit/byte). *Alternatives:* 32 bits is too small to hold two
  20-bit values; 64 bits works but wastes 24 idle bits/beat. 40 is the minimal
  clean width.

- **One sample per beat / 16 beats per frame, TLAST on the 16th.**
  *Why:* keeps "1 sample = 1 beat" so framing is simple; TLAST delimits each
  16-point spectrum for a downstream DMA/consumer. Splitting real/imag across
  beats would double the beat count and complicate framing.

- **`keep = strb = -1` (all ones).**
  *Why:* asserts "all 5 bytes are valid data." `-1` in an unsigned N-bit field
  is all 1s (two's-complement), a width-agnostic way to say "all bytes present."
  Leaving them unset could let a downstream block / the AXIS protocol checker
  treat bytes as null.

- **No TUSER/TID/TDEST (`ap_axiu<40,0,0,0>`).**
  *Why:* the link is point-to-point (one source -> one sink), so there is no
  routing to do. TDEST/TID only matter behind an AXI-Stream switch that fans a
  stream out to multiple destinations; we have none, so those wires would be dead.

- **Uniform `axis_t` on both input and output** even though the input imag is
  always 0 (real XADC samples).
  *Why:* one shared 40-bit type keeps the code simple; it costs only ~20 idle
  input wires. A separate 20-bit input stream could reclaim them later (e.g. to
  match a DMA data width) — deferred as a minor optimization.

- **`#pragma HLS INTERFACE axis` on the top-level stream ports.**
  *Why:* it makes each top-level `hls::stream` a standard AXI4-Stream port
  (TDATA/TVALID/TREADY/TLAST...) that snaps into Xilinx AXIS IP. Without it a
  top-level stream is a generic `ap_fifo` port; an *internal* stream (function to
  function) is just an on-chip FIFO.

- **Deferred:** block-level control (`ap_ctrl_chain`/`ap_ctrl_none`) for
  frame-to-frame overlap is left to Hour 4 — Hours 2-3 only prove the streaming
  interface is functionally correct.

### 8.1 Hour-4 fix — restore frame throughput

**STATUS: DONE (dataflow half).** Refactored `fft_axis` into `read_in` /
`fft_dataflow` / `write_out` and added `#pragma HLS dataflow`. HLS extracted
3 processes; **interval dropped 113 -> 20 cycles** (~5.6x), latency unchanged
(~113), DSP 12, Fmax 152, cosim PASS 4/4 (frames 20 cycles apart in sim). The
`X`/`OUT` buffers became ping-pong (PIPO) memories. See `hls_synthesis_results.md`
section 5.e. Honest note: the dataflow pragma alone achieved the overlap under
`ap_ctrl_hs` (I had expected it to also need `ap_ctrl_chain` — it didn't).
`ap_ctrl_none`/`ap_ctrl_chain` remains a recommended integration refinement
(continuous free-running, clears the `HLS 200-786` warning), not a throughput fix.

**Original plan (for reference):**

**Problem:** the AXIS wrapper `fft_axis` runs read-16 -> compute -> write-16 in
strict sequence, and `ap_ctrl_hs` blocks the next frame until the current one
finishes. So interval = read + compute + write ≈ 16 + 74 + 16 ≈ **113 cycles**
(measured in cosim) — a ~6x throughput regression vs the core's interval of 19.
Correctness and per-frame latency are fine; only *how often* a frame can start
is bad.

**Fix (two changes):**
1. **Make `fft_axis` a dataflow region** (`#pragma HLS dataflow`): read / compute
   / write become three concurrent processes connected by ping-pong buffers, so
   read(N+1), compute(N), and write(N-1) run at the same time instead of in
   sequence.
2. **Change block control to `ap_ctrl_chain`** (successive frames pipeline) or
   **`ap_ctrl_none`** (free-running / purely data-driven, ideal for a live DAQ) —
   this removes the per-frame start/done barrier of `ap_ctrl_hs`.

**Why it helps (theory):** pipelining converts a *sequential* interval into an
*overlapped* one: `interval = t_read + t_compute + t_write` becomes
`interval = max(t_read, t_compute, t_write)`. Here read=16, write=16, and the FFT
core sustains ~19, so the interval collapses to `max(16,19,16) ≈ 19-20`. It's the
same pipelining idea as the FFT stages, applied one level up (the loading-dock
accepts the next truck while the line builds the current and ships the previous).

**Estimated outcome:** interval **~113 -> ~19-24** (≈5-6x throughput); latency
per frame roughly **unchanged** (~110 cycles — a frame still traverses all three
phases); Fmax ~152 MHz; DSP still 12; small area bump for the ping-pong buffers.
Then `export_design` to package the Vivado IP. Verify with csim/cosim (expect
4/4) and read the new interval from csynth. (Exact interval TBD — ping-pong
fill/drain may leave it slightly above 19.)

### 8.2 Block-level control + IP export — design decisions (Day 8, Hour 4)

Two final integration decisions turned the verified stream block into a
drop-in Vivado IP.

- **`ap_ctrl_none` (free-running), not `ap_ctrl_hs` or `ap_ctrl_chain`.**
  The block-level control protocol decides *how the block is told to start and
  how it reports done*. There are three choices:
  - `ap_ctrl_hs` (HLS default): a start/done handshake — the block waits for
    `ap_start`, runs one call, raises `ap_done`. Successive frames can't overlap
    (the source of the 113-cycle regression in 8.1), and it adds `ap_start/
    ap_done/ap_idle/ap_ready` ports plus the `HLS 200-786` warning.
  - `ap_ctrl_chain`: like `hs` but lets consecutive calls pipeline — good when a
    *parent* block sequences the calls.
  - `ap_ctrl_none` (chosen): **no control handshake at all.** The block is purely
    data-driven — it runs whenever its AXI-Stream input has data and its output
    can accept, gated only by TVALID/TREADY. This is exactly right for a live DAQ
    where the XADC produces samples continuously and nothing "starts" the FFT per
    frame; TLAST already delimits frames.
  *Why `none` over `chain`:* our data plane is self-synchronising through the
  AXIS handshake and TLAST — there is no parent block issuing per-frame `ap_start`
  pulses, so a start/done protocol is dead weight. `none` removes the four
  control ports, clears `HLS 200-786`, and matches "the hardware simply flows
  data" semantics. Applied as `#pragma HLS INTERFACE ap_ctrl_none port=return`.
  *Result:* csynth confirms `Setting interface mode on function 'fft_axis' to
  'ap_ctrl_none'`; the port list drops `ap_start/done/idle/ready`, keeping only
  the AXIS ports + `ap_clk`/`ap_rst_n`. cosim still PASS 4/4.
  *Cosim caveat that didn't bite:* `ap_ctrl_none` removes `ap_done`, so I
  expected cosim to fail (no completion signal for the testbench). It passed —
  Vitis's dataflow testbench bounds each frame with the deadlock/transaction
  monitor and TLAST instead of `ap_done`. Good to know: free-running blocks are
  still cosim-able.

- **`export_design -format ip_catalog` — package as a Vivado IP-catalog block.**
  *What it does:* takes the generated RTL and wraps it as an IP-XACT bundle
  (`export.zip`) with the AXIS port interfaces described, so Vivado's IP catalog
  can instantiate `fft_axis` in a block design and auto-connect it to the XADC,
  a DMA, or MicroBlaze. *Why this format:* `ip_catalog` is the block-design flow
  (vs `syn_dcp`/`ip_catalog` alternatives) — the canonical path for
  `XADC -> FFT -> DMA -> MicroBlaze` SoC assembly. Given cosmetic VLNV identity
  `wadhwani:daq:fft_axis:1.0` via `-vendor/-library/-version` so it's findable in
  the catalog. Placed *after* `csynth_design` in the tcl (it packages synthesized
  RTL — nothing exists to export before synthesis). Output:
  `mini_daq_fft_hls/sol1/impl/export.zip`. (The date-overflow bug hit here; see
  3.13.)

## 9. FAQ — AXI-Stream & verification concepts

**Q: csim vs cosim?** csim compiles the C/C++ with gcc and runs it on the CPU —
it tests the *algorithm* (fast). cosim runs the HLS-*generated RTL* in a
simulator (xsim), driven by the same testbench — it tests the *hardware*,
cycle-accurate. csim answers "is my C correct?"; cosim answers "does the
generated hardware match my C?" (and gives measured latency/interval).

**Q: What is AXI4-Stream and what do the wires do?** A one-directional,
point-to-point streaming bus. TDATA = payload; TVALID (from source) = "data is
valid"; TREADY (from sink) = "I can accept it"; a **beat transfers only when
TVALID and TREADY are both high** (this handshake gives lossless back-pressure).
TLAST = last beat of a frame; TKEEP/TSTRB = per-byte valid/type qualifiers.

**Q: What is a data beat?** One transfer on the bus — the TDATA (+ side-signals)
handed across in a single successful handshake. Here 1 beat = 1 complex sample;
16 beats = 1 FFT frame (TLAST on the 16th). "Beat" means an *actual* transfer,
which only happens on a cycle where both TVALID and TREADY are high.

**Q: What is a sink (and source/master/slave)?** The sink is the receiver of a
stream (drives TREADY); the source/master is the sender (drives TVALID/TDATA).
Data flows source -> sink. In `fft_axis`, the input port is a sink (`in.read()`),
the output port is a source (`out.write()`).

**Q: Why is TDATA 40 bits?** 20-bit real + 20-bit imag (two Q5.15 values), the
smallest byte-aligned width holding one complete complex sample per beat.

**Q: What is routing (TDEST/TID)?** Choosing among multiple destinations when a
stream switch fans data out to several sinks. TDEST = the "address" on the beat;
TID = which source it came from. Irrelevant for a single point-to-point link, so
we set those widths to 0.

**Q: What does `#pragma HLS INTERFACE axis` do?** Turns a top-level `hls::stream`
argument into a physical AXI4-Stream port. Without it: an internal stream is an
on-chip FIFO, and a top-level stream defaults to a generic `ap_fifo` interface.
With it: a standard AXIS port that interoperates with Xilinx streaming IP.
(Note: AXI-Stream is a standardized *point-to-point* interface, not a shared
addressed bus like AXI memory-mapped.)

**Q: Why `keep = strb = -1`?** `-1` fills an unsigned fixed-width field with all
1s, i.e. "all bytes valid" — the width-agnostic idiom.

**Q: Difference between `fft_dataflow` and `fft_axis`?** `fft_axis` is the outer
AXI-Stream I/O shell (bus <-> arrays); `fft_dataflow` is the inner engine that
does the overlapped 4-stage FFT compute. `fft_axis` does NOT direct the
inter-stage pipelining — that is `fft_dataflow`'s `dataflow` pragma. Once
`fft_axis` is the top, `fft_dataflow` becomes an internal block (its arrays are
on-chip buffers, not external ports).

---

## 10. XADC DAQ front-end — design decisions (Day 10)

The reused XADC project (`rtl/XADC controller`) is a pot→LED demo (reads VAUX5 via
DRP, latches the top 8 of 12 bits to LEDs — see `docs/controller_verification.md`).
For the DAQ it is being rebuilt as a new module **`xadc_daq.vhd`** that turns a
conditioned analog input into verified Q5.15 samples. The pot→LED demo is left
untouched as a fallback. Decisions and why:

- **Convert inside `xadc_daq` (emit Q5.15 directly), not raw codes.**
  *Why:* the module then hands out samples already in the FFT's number system, so
  the downstream AXI-Stream framer is trivial (pack into `TDATA[19:0]`, `TLAST`
  every 16th). Clean separation of concerns — the front-end's job is "give me
  real-world samples in Q5.15." *Trade-off:* the module is now DAQ-specific rather
  than a generic ADC reader — acceptable.

- **Output interface = `sample(19 downto 0)` (Q5.15) + `sample_valid` (one-cycle pulse).**
  *Why:* `sample` is exactly the 20 bits `fft_axis` packs into `TDATA[19:0]`;
  `sample_valid` is the handshake the framer / FFT read side keys off. One sample
  emitted per conversion.

- **Use the full 12-bit result, center (−2048), then shift left 4.**
  `raw = drp_do(15 downto 4)`; `centered = raw − 2048`; `sample = centered << 4`
  (sign-extended to 20 bits).
  *Why full 12 bits:* the demo threw away 4 bits (`[15:8]`); the DAQ keeps the full
  resolution. *Why −2048:* XADC unipolar reads 0…4095 for 0…1 V, so mid-scale 2048
  maps mid-rail to zero (signed −2048…+2047). *Why <<4:* maps ADC full-scale to
  Q5.15 ±1.0 (2048 = 2¹¹, Q5.15 1.0 = 2¹⁵), landing the sample in [−1.0, +1.0) —
  well inside ±16 so the FFT's bit-growth has headroom. *Consequences:* it is a
  **normalized** mapping (full-scale = ±1.0), so absolute-voltage calibration, if
  ever wanted, is a Python-side scale factor; and any residual DC (signal not
  perfectly mid-rail) shows up in bin 0 — expected and ignorable.

- **Unipolar mode + external mid-rail bias (`BIPOLAR` generic, default false).**
  *Why:* simplest path for a single-ended source, and it matches the subtract-2048
  conversion. Bipolar (XADC returns signed two's-complement, skip the subtract) is
  kept as a generic for a future differential source but doesn't save the biasing
  circuit (only the *difference* is bipolar), so it isn't worth the overhead now.
  *Consequence:* requires an external conditioning circuit to put the signal in 0–1 V.

- **Compile-time generics: `DADDR=0x15` (VAUX5), `BIPOLAR=false`, `SHIFT=4`.**
  *Why:* channel, polarity, and full-scale scaling become configurable without
  touching logic — parameterized like N, at zero runtime cost. Runtime
  configurability (register file / MicroBlaze control, live channel/rate switching)
  is deferred — simpler build; that's Phase-4 territory.

- **Sample rate + averaging live in the XADC Wizard IP, not the RTL.**
  *Why:* Fs (~1 MSPS) sets Nyquist (500 kHz) and FFT bin spacing (Fs/16 =
  **62.5 kHz/bin**) — the main DAQ knobs — but they sit in the IP's ADC-clock
  divider / averaging config. Changing Fs means regenerating the IP, not editing
  `xadc_daq`. Documented, not exposed as RTL generics.

- **Input = a *conditioned* external analog signal on VAUX5.**
  *Why / consequence:* the XADC input accepts **0–1 V only**, so a bench source
  (function generator, etc.) cannot connect directly — over-range risks damaging
  the pin. A front-end must attenuate, DC-bias to mid-rail, anti-alias below
  Nyquist, and protect the input. This is a hardware task outside the RTL. For
  demos, pick test tones at bin centers (k·Fs/16) and below Nyquist to avoid
  leakage/aliasing.

- **Verification approach (Hour 3):** because the conversion is internal and
  deterministic, `xadc_daq` is **unit-testable by mocking the DRP side** — drive
  `drp_do` with known codes and `drdy`, and check the Q5.15 output (mid-scale → ~0,
  full-scale → ±expected) and that `sample_valid` pulses once per read. No analog
  stimulus needed.

---

## 11. SoC integration (Day 11)

### 11.1 MicroBlaze SoC scaffold (Hours 1–2)

Built in a **new Vivado project at `C:\daq_soc`** (space-free, local), part
`xc7a35tftg256-1`. Build flow mirrors the HLS one: the sources (RTL, `.xci`, the
block-design Tcl exported via `write_bd_tcl` into `soc/`) live in the Mini-DAQ repo;
the generated project is regenerated in `daq_soc` and **not** committed. *Why:*
Vivado inside the OneDrive-synced, space-containing path caused file-lock failures
on the sim log and broke Webtalk on the space in "Wadhwani Lab Research" — the same
reason HLS builds in `C:\hls_minidaq`.

Block design `daq_bd`, created via Block Automation on MicroBlaze:
**MicroBlaze + 32 KB local memory + MDM (debug) + Clocking Wizard + Processor
System Reset** plus an AXI interconnect. The `fft_axis` IP was added to the catalog
from `hls/ip/fft_axis_1.0.zip`.

- **Clock:** an external port `sys_clk_100` → the board's 100 MHz oscillator
  (pin **N14**, LVCMOS33, `create_clock -period 10`) → the Clocking Wizard's
  `clk_in1`. It is the only external pin at this stage (MDM uses internal JTAG,
  memory is on-chip; the analog + UART pins come with the data plane).
- **Reset (no board button):** tied off with constants, with the SoC self-resetting
  via the clock's `locked`. The Clocking Wizard `reset` (active-**high**) is driven
  by a Constant `0`; the Processor System Reset's `ext_reset_in`/`aux_reset_in`
  (active-**low**) are driven by a Constant `1`. **Gotcha:** the proc-reset
  "Ext Reset Logic Level" field is read-only in IP Integrator, so the polarity is
  matched from the *constant value*, not by flipping the field — an active-low input
  cannot be de-asserted by `0`, which would silently hold the CPU in reset even
  though the design *validates*. `dcm_locked` (from the wizard's `locked`) then
  releases the SoC reset once the clock stabilizes on power-up.

Validated clean — a bare CPU + AXI backbone. The DAQ data plane (§11.2) mounts onto
it.

### 11.2 Data-plane: repack + FIFO (Hour 3)

The FFT result stream (`fft_axis`: 40-bit AXIS beat per bin — real Q5.15 in
`[19:0]`, imag Q5.15 in `[39:20]`) has to reach the MicroBlaze and then the host.
Decisions and why:

- **FFT output → CPU over an AXI-Stream FIFO, not DMA.** The UART throttles the
  *display* rate to ~10–30 fps regardless of N, so the CPU only pulls the
  occasional frame — a FIFO handles that at both N=16 and N=256. DMA's advantage
  (bulk, CPU-offloaded, high sustained rate) is only needed for full-rate lossless
  capture, which this DAQ doesn't do. Simpler bring-up, no DMA driver. FIFO depth
  is a parameter, sized for one full (half-spectrum) frame.

- **Send both real and imag to the CPU.** Python draws a magnitude spectrum
  `|X[k]| = sqrt(re² + im²)`, which needs *both* components. Magnitude is computed
  in Python (no on-chip sqrt) and phase is discarded — but you cannot get magnitude
  from real alone, so both must go across.

- **Repack 40→32: truncate each 20-bit value to 16, pack real+imag into one
  32-bit word.** The CPU reads 32-bit words and 40 bits don't fit one. For a
  *display*, 16 bits is already far more resolution than a plot can render, so
  truncating lets real+imag share a single word — one read per bin, and half the
  FIFO and UART traffic. Keeping full Q5.15 would force two reads/bin (or a wider
  multi-read FIFO) to preserve precision the screen throws away.

- **Truncate by dropping the LOW 4 bits (LSBs) → Q5.11, never the top.** *This is
  the crux.* The output swings to ~±8 (the DC bin hit 8.0 in verification), so it
  genuinely uses the integer bits. Dropping the **top** 4 bits collapses the range
  Q5.15→Q1.15 (±16→±1) and clips every bin above magnitude 1 — i.e. the spectral
  peaks, the whole point of the plot: catastrophic. Dropping the **bottom** 4 bits
  keeps the full ±16 range (peaks intact) and only coarsens resolution 2⁻¹⁵→2⁻¹¹,
  a low-level noise floor invisible on a plot. **Principle: preserve dynamic range /
  headroom, sacrifice precision** — clipping large values is fatal, low-level
  quantization noise is nothing. Keep bits `[19:4]` of each value.

- **Carry only the N/2+1 unique bins, dropped BEFORE the FIFO.** A real input gives
  a conjugate-symmetric spectrum (`X[N−k] = X[k]*`), so bins 9–15 are redundant
  mirrors of 7–1. Keep only bins 0…N/2 (9 for N=16; **129 for the 256-point
  endgame**). Dropping them before the FIFO halves FIFO depth, CPU reads, and UART
  traffic — and that halving compounds at 256, directly easing FIFO/BRAM size and
  the UART bottleneck.

- **One `fft_repack` stage does both jobs.** As beats stream out of `fft_axis` in
  bin order, it truncates 40→32 (`{OUT_R[19:4], OUT_I[19:4]}`), forwards only beats
  0…N/2, drops the rest, and asserts `TLAST` on beat N/2 — emitting an (N/2+1)-beat
  frame of 32-bit words (two Q5.11 halves). Parameterized on N so it scales to 256.
  Host side: split each word into two signed 16-bit values, ÷2¹¹, then magnitude
  (absolute scale is arbitrary for a plot anyway).

_Phase 1 HLS bring-up log + Day-10 XADC front-end + Day-11 integration decisions.
Companion to docs/hls_synthesis_results.md, docs/controller_verification.md._
