# Mini-DAQ FFT — Verification Methodology

**What this document is:** a standalone account of *how correctness of the
16-point HLS FFT is established* — the reference-model philosophy, the layered
simulation flow, what each test actually proves, the known coverage gaps, the
planned randomized-differential upgrade, and where all of this sits in the broader
verification taxonomy (simulation-based vs formal). It is the "how do we know it's
right" companion to `hls_engineering_log.md` (the narrative build log) and
`hls_synthesis_results.md` (the measured numbers).

**Design under test:** 16-point radix-2 DIT FFT, Q5.15 fixed-point
(`ap_fixed<20,5>`), dataflow architecture, AXI4-Stream top (`fft_axis`), on
XC7A35T-FTG256-1. **Reference of record:** the Python golden model
(`model/`), a direct DFT cross-checked against NumPy.

---

## 1. Philosophy — correct-first, against a trusted reference

Verification here follows one principle applied at every layer: **run the design
under test (DUT) on inputs, compare its outputs against a reference we already
trust, and accept only agreement within a defined tolerance.** Correctness is
established *before* optimization — the algorithm was proven right, then the
pragmas/fixed-point/interface changes were each re-checked against the same
reference so no optimization could silently break it ("correct-first,
fast-second").

The two ingredients of any such check are a **trusted reference** and a **set of
inputs**. Everything below is about strengthening one or the other.

## 2. The trusted reference (the golden model)

The reference is the **direct DFT** — the literal definition of the transform:

```
X[k] = Σ_n  x[n] · e^(−j·2π·k·n/N)
```

This is an O(N²) double loop with nothing clever in it to get wrong, which is
exactly what makes it a trustworthy gold standard. The fast radix-2 FFT (and its
fixed-point HLS realization) are *optimizations* of this definition; verification
asks whether they still agree with it. The Python golden model implements this
(plus a radix-2 path and Q1.15 quantization) and is itself cross-checked against
NumPy, so the reference chain bottoms out in a tool we trust. Test vectors are
exported to `model/fft_test_vectors.txt`.

## 3. Why fixed-point means "within tolerance," not "equal"

The reference runs in double precision (effectively exact); the DUT runs in Q5.15,
where every value is rounded to the nearest 1/32768. The two therefore never match
bit-for-bit — there is always quantization/rounding error. So the acceptance
criterion is **"agree within a tolerance,"** and that tolerance is grounded in the
arithmetic, not guessed: the Q5.15 LSB is 2⁻¹⁵ ≈ 3.05e-5, and rounding accumulates
over the log₂N = 4 butterfly stages (growing slightly with signal magnitude),
giving an expected worst-case error on the order of a few LSB up to ~1e-2. The
tolerance is set just above the measured worst case.

## 4. The verification stack (layers)

Each layer answers a different question; together they build confidence from
"algorithm is right" up to "the synthesized hardware matches and fits."

1. **Golden model (Python)** — *is the algorithm itself correct?* Direct DFT +
   radix-2 + Q1.15, cross-checked vs NumPy.
2. **Test vectors** — DC, single sine (bin 3), two-tone (bins 3 & 5), impulse;
   inputs plus expected reference outputs (§5).
3. **C simulation (csim)** — *is my C/C++ correct?* Runs the HLS FFT on the CPU
   over each vector, diffs against golden within tolerance, returns non-zero on any
   fail. Result: **4/4 pass**, max magnitude error ~1e-4.
4. **Pre-checks (gcc/g++ + `ap_fixed` emulation)** — caught bugs and confirmed the
   Q5.15 range was sufficient (peak 8.0 < 16) before spending a Vitis run.
5. **Co-simulation (cosim)** — *does the generated hardware match the C?* Runs the
   HLS-generated RTL in xsim, driven by the same self-checking testbench. Result:
   **C/RTL co-simulation PASS**, and it confirmed the timing estimates (interval
   19–20, latency ~74–113) with a real cycle-accurate run.
6. **csynth utilization + timing** — *does it fit and close timing?* Read DSP/LUT/FF
   and Fmax to prove the design fits the XC7A35T (12 DSP / 13%, 151.77 MHz).
7. **Randomized differential test (planned, §7)** — *is it correct across the input
   space, not just four points?*

Layers 1–6 are complete; layer 7 is designed and pending.

## 5. The directed test vectors — what each one tests

Four hand-chosen ("directed") vectors, each aimed at a distinct behavior. Bins are
numbered 0…15; for a **real** input the spectrum is conjugate-symmetric, so a tone
at bin `k` also appears mirrored at bin `N−k`.

**1. DC — constant input** (`x[n] = 0.5` for all n). Expected: all energy in bin 0,
`X[0] = Σx[n] = 8.0`, other bins ≈ 0. Tests the **accumulation path**, the
**worst-case bit-growth** (bin 0 is the largest possible output — this is where
overflow first shows, and it is what proved Q1.15 overflows and drove the move to
**Q5.15**), and **cancellation** (non-DC bins must sum to zero, which needs correct
twiddle symmetry).

**2. Single sine — pure tone at bin 3** (`x[n] = sin(2π·3·n/16)`). Expected: energy
at bin 3 (and its real-input mirror, bin 13); other bins ≈ 0. Tests **frequency
localization and twiddle correctness** — a single frequency must land in exactly
the right bin; wrong twiddles would smear or misplace the energy. Also confirms
real-input **conjugate symmetry**.

**3. Two-tone — bins 3 and 5 together** (`sin(2π·3·n/16) + sin(2π·5·n/16)`).
Expected: clean peaks at bins 3 and 5 (mirrors 13, 11). Tests **linearity /
superposition** — two simultaneous frequencies must resolve into two separate bins
with no cross-talk; a nonlinear bug (overflow wrap, bad rounding) would create
spurious intermodulation bins.

**4. Impulse — unit sample** (`x[0] = value`, else 0). Expected: a **flat spectrum**
— `|X[k]|` constant across all bins (the DFT of a delta is flat). This is the best
**structural coverage** of the four: an impulse contains every frequency equally, so
every output bin is non-zero and every twiddle multiply and butterfly path is
exercised at once; against a known flat line, any single broken path shows up as one
deviating bin. Also checks **bit-reversal / data routing**.

Together they span four distinct failure surfaces — accumulation + bit-growth (DC),
frequency placement + twiddles (sine), linearity (two-tone), and whole-datapath
structural coverage (impulse).

## 6. Coverage gaps — why the four are a smoke test, not a sign-off

The four are a strong smoke test but do **not** constitute a correctness sign-off:

- **Magnitude-only comparison.** The testbench diffs `|X[k]|`, so a sign flip or a
  phase error that preserves magnitude passes all four. `a+bi` and `a−bi` share a
  magnitude. → compare **real and imag** (or magnitude *and* phase).
- **No input-space coverage.** Four fixed, "clean" patterns; fixed-point
  rounding-error accumulation on *arbitrary* inputs is untested.
- **No boundary/overflow testing.** Inputs never pushed near ±full-scale, so
  saturation/overflow behavior at the Q5.15 edges is unexercised.
- **Missing bins.** Bins 3 and 5 tested; never bin 1 or the Nyquist bin (8).
- **cosim added no input coverage** — it re-ran the *same* four inputs as RTL vs C.

## 7. Randomized differential testing (IMPLEMENTED & PASSING)

The high-value upgrade: compare the DUT against the reference over thousands of
random frames — turning four spot checks into statistical confidence across the
input space.

**Result (implemented in `fft_tb_axis.cpp`, run 2026-07-21):**
- **csim:** 10,000 random frames — **worst error 4.6 LSB** (0.000139), worst
  relative Parseval residual 6.1e-5. All six boundary/corner frames pass (worst
  4.1 LSB, the bin-1 tone). Tolerance set to `3e-4` (~9.8 LSB, ~2× the worst).
- **cosim:** 16 random + 4 directed + 6 boundary frames driven through the RTL —
  **C/RTL co-simulation PASS**, worst 3.2 LSB. RTL matches C on random inputs.
- Headline: **the fixed-point 16-point FFT agrees with the exact DFT to within
  ~5 LSB of Q5.15 across the input space** — the FFT is fully verified.

- **Reference** = double-precision direct O(N²) DFT (obviously correct; same
  unnormalized definition as the golden model). The DUT is the fixed-point HLS FFT.
- **~10,000 seeded-random frames**, inputs bounded `|x| ≤ 0.5` so the DC bin
  (≤ N·0.5 = 8) stays inside Q5.15's ±16 — an overflow would corrupt the comparison
  and mask real bugs.
- **Compare real AND imag** (closes the phase gap), track the worst absolute error
  over all frames/bins, assert `< TOL`.
- **Reference the *quantized* input** — feed the reference the same Q5.15 values the
  DUT sees, so the metric isolates the FFT's internal arithmetic error from input
  quantization.
- **Explicit stress frames:** near-full-scale all-positive / all-negative (bounded
  so DC < 16), impulse, DC, single tones at **bin 1 and the Nyquist bin**, plus a
  **Parseval invariant** (`Σ_k |X[k]|² = N · Σ_n |x[n]|²`) as a cheap,
  reference-free energy-conservation net.
- **Tolerance from LSB analysis:** LSB = 2⁻¹⁵ ≈ 3.05e-5; expect worst ≈ 1e-3…1e-2 —
  set generous, then tighten to the measured worst (that measured worst-case error
  is itself a quotable result).
- **Where it runs:** the 10k volume in **csim** (seconds); **cosim** keeps the four
  curated vectors plus ~a dozen random frames as a spot check (RTL sim is too slow
  for 10k).

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
      sr += xr[n]*c - xi[n]*s;  si += xr[n]*s + xi[n]*c;
    }
    Xr[k] = sr; Xi[k] = si;
  }
}

int random_diff_test() {
  const int NTRIAL = 10000; const double AMP = 0.5, TOL = 5e-3;
  srand(12345);                                   // reproducible
  double worst = 0;
  for (int t = 0; t < NTRIAL; t++) {
    double xr[SIZE], xi[SIZE]; DTYPE in_R[SIZE], in_I[SIZE], out_R[SIZE], out_I[SIZE];
    for (int n = 0; n < SIZE; n++) {
      double v = ((double)rand()/RAND_MAX*2 - 1) * AMP;
      in_R[n] = (DTYPE)v; in_I[n] = (DTYPE)0;     // quantize to Q5.15
      xr[n] = (double)in_R[n]; xi[n] = 0.0;       // reference sees the QUANTIZED input
    }
    double Xr[SIZE], Xi[SIZE]; ref_dft(xr, xi, Xr, Xi);
    run_dut(in_R, in_I, out_R, out_I);            // pack->fft_axis->unpack (existing tb helper)
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

### 7.1 Methodology & rationale — why this verification path works

**The tolerance was measured, not assumed — a three-step calibration.**

1. **Run loose first** (`TOLD = 1e-2`, 10,000 csim frames). The purpose of the
   first run is to *measure* the FFT's real worst-case error, not to gate on a
   guessed number. A deliberately loose tolerance guarantees the run completes and
   prints the worst error instead of aborting on a false failure that hides it. In
   fixed-point verification the tolerance is an **output** of the process, not an
   input — you find out what the arithmetic actually does, *then* decide what's
   acceptable. Measured worst: **4.6 LSB**.
2. **Tighten to the measurement** (`TOLD = 3e-4` ≈ 9.8 LSB, ~2× the measured
   worst). A tolerance so loose that anything passes verifies nothing — it can
   never catch a regression. Re-setting the gate to just above the observed worst
   turns it into a real guard: any future change (a datatype tweak, a new
   optimization, scaling N) that pushes the error past ~2× today's worst now
   **fails**. The 2× margin (rather than 1×) is deliberate — it absorbs
   run-to-run variation from other random seeds, so the test is a meaningful guard
   rather than a brittle trip-wire.
3. **Cross-check the RTL with a small cosim** (16 random + 4 directed + 6 boundary
   frames) to confirm the generated hardware matches the C.

**Why 10k frames in csim but only 16 in cosim.** The two runs do different jobs,
and each is placed where it is cheap. **csim** compiles the C and runs it on the
CPU — thousands of frames cost *seconds*, so csim is where **input-space coverage**
lives (10k random frames → statistical confidence the *algorithm* is right across
inputs). **cosim** runs the HLS-generated RTL in a cycle-accurate simulator —
roughly a couple of seconds per frame, so 10k frames would take *hours*. But
cosim's job is **not** input coverage; it is to prove **RTL == C**. The RTL is
deterministic and its structure does not depend on the data values, so a *small*
random sample (16), together with the directed and boundary frames, is sufficient
to confirm the hardware reproduces the C behaviour — running the full 10k there
would be enormous cost for zero added assurance. Heavy coverage in csim, an
RTL-equivalence spot-check in cosim: the standard, correct division of labour.

**Why this is a strong functional-verification path.** It layers independent kinds
of check, each catching a different class of bug:

- a **trusted reference** — the O(N²) direct DFT, i.e. the definition, obviously correct;
- **directed** vectors — targeted failure modes (bit-growth, twiddles, linearity, structural coverage);
- **constrained-random** frames — the input-space coverage the directed set cannot give;
- **boundary / corner** frames — near-full-scale range edges plus bin 1 and the Nyquist bin;
- an **invariant** — Parseval energy conservation, a reference-free net;
- a **cross-domain** check — cosim proving the RTL equals the C.

Two design choices sharpen it: comparing **real and imag** (not magnitude) closes
the phase-error gap, and feeding the reference the **quantized** input isolates the
FFT's own arithmetic error from input quantization. The output is not a binary
pass but a **quantified worst-case error (4.6 LSB)** — a number that can be defended.

**Why the FFT is now "verified."** It agrees with the mathematical definition of
the DFT across the input space to within ~5 LSB of Q5.15; the energy invariant
holds; the boundary and corner cases are clean; and the synthesized RTL is
confirmed equal to the C. A calibrated tolerance now guards against regressions.
That is the difference between "it passes four cases" and "it is verified." (Scope
note, per §8: this is thorough *simulation-based functional verification* —
sampling, not exhaustive formal proof — which is the appropriate, industry-standard
bar for a fixed-point DSP datapath.)

## 8. Verification taxonomy — where this project sits

**None of this is formal verification** — it is *simulation-based functional
verification*. The distinction:

**Formal verification** proves or disproves that a design meets a formal spec
**exhaustively over all inputs/states, without running test cases** — it reasons
symbolically and returns a proof or a counterexample. The key word is *exhaustive*:
simulation *samples* the input space, formal *covers* it (Dijkstra: "testing shows
the presence, not the absence, of bugs"). The sampling really is a sliver — a
16-point Q5.15 frame has 2^(16×20) ≈ 10⁹⁶ possibilities, so 10k random frames is a
vanishing fraction. Formal's three hardware families: **equivalence checking (LEC)**
(two representations compute the same function — e.g. RTL vs gate netlist),
**model/property checking (FPV)** (assertions proven over all reachable states —
JasperGold, VC Formal), and **theorem proving** (interactive proof — ACL2, Coq).

**This project = simulation-based (dynamic) functional verification.** The four
vectors are **directed testing**; the random harness is **constrained-random**; and
because it checks against an independent reference it is **differential /
golden-model** testing. **cosim is co-simulation** — RTL-vs-C equivalence checked by
*simulating both on the same stimulus*, so it is dynamic, not formal. Everything here
samples inputs and yields *statistical* confidence, never a proof of absence.

**Could an FFT be formally verified, and why simulation is the norm?** Parts could —
equivalence-check the HLS RTL against the HLS C, or property-check "no overflow given
bounded inputs"; specialized **datapath/word-level** formal tools exist for
arithmetic blocks. But full formal proof of a fixed-point FFT is hard, which is *why*
DSP blocks are verified by simulation-with-a-reference. The obstacle is fixed-point
rounding: the Q5.15 FFT is deliberately **not bit-exact** to the ideal DFT — it is
*approximately* equal, within an error bound. Equivalence checking proves *exact*
equality, so it doesn't apply against a floating reference; and proving a
*bounded-error* property ("always within k LSB of the true DFT") over a wide
arithmetic datapath is exactly the quantitative, real-valued property formal tools
struggle with. Simulation with a golden model sidesteps this by *measuring* the
actual error empirically and cheaply, yielding a concrete worst-case number.

**Interview answer to "did you formally verify it?"** *"No — simulation-based
functional verification with a reference model (directed + constrained-random +
differential, plus co-simulation for C/RTL behavioral equivalence). Formal
verification is the next rung; it's a poor fit for the fixed-point datapath because
the design is approximate-by-design, but it would help on bounded properties like
no-overflow or on C-to-RTL equivalence of the control logic."*

## 9. Status

| Item | Status |
|---|---|
| Golden model (direct DFT + radix-2 + Q1.15, vs NumPy) | Done |
| Directed vectors (DC, sine, two-tone, impulse) | Done |
| csim vs golden (magnitude) | **4/4 pass**, max err ~1e-4 |
| cosim (RTL vs C, same vectors) | **PASS** |
| csynth utilization/timing sign-off | Done (12 DSP, 152 MHz, fits) |
| Randomized differential test (complex compare) | **DONE** — 10k frames, worst 4.6 LSB (csim); 16 frames cosim PASS |
| Boundary / overflow frames + corner bins | **DONE** — 6 frames pass (worst 4.1 LSB) |
| Parseval energy invariant | **DONE** — residual < 6.1e-5 |

_Companion to `docs/hls_engineering_log.md` (§4–4.3) and
`docs/hls_synthesis_results.md`. Phase 1 HLS bring-up._
