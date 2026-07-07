# Mini-DAQ — Design Notes (Phase 1)

Rationale for the fixed decisions. Kept so future-me (and interviewers) can see
*why*, not just *what*.

## Number format: Q1.15 fixed-point
- Chose fixed-point over floating-point because real DSP/ASIC datapaths are
  fixed-point (cheaper area, power, timing) and it demonstrates the skills
  hardware interviewers probe: bit-growth, scaling, quantization.
- Floating-point in hand-written RTL is either huge (IEEE-754) or a vendor
  black box — both defeat the "I hand-wrote the datapath" goal.
- Q1.15 = 1 sign bit + 15 fractional bits, range [-1, 1). Standard DSP format,
  maps cleanly onto the DSP48 multiplier. XADC 12-bit samples are left-justified
  into it.
- Float lives only in the golden model as the accuracy yardstick.

## Bit-growth: full growth (no per-stage scaling)
- Radix-2 adds can grow magnitude ~1 bit per stage. 4 stages -> 16-bit input
  grows to ~20-bit output.
- Chose full growth (widen datapath) over scale-by-2-per-stage because at N=16
  the extra bits are nearly free on Artix-7, there is no overflow, and it stays
  bit-exact vs the golden model (easy verification).
- Scale-by-2 is what large FFTs (1024+) do; noted as the "at scale" alternative
  for interviews, not needed here.
- Verified: Q1.15 full-growth quantization error vs NumPy is ~0.0001 (negligible).

## FFT size: N = 16 (parameterized)
- 16 keeps debugging tractable and hits the July 24 milestone; small enough to
  verify by eye, big enough to show real microarchitecture.
- Written parameterized so bumping to 64-256 later is a near one-line change
  (bigger twiddle ROM + more stages).
- Caveat: 16 points = only 8 usable bins, too coarse for a *useful* instrument.
  Plan: scale N up after the deadline for a credible-looking spectrum.

## Algorithm: radix-2 decimation-in-time
- Simplest to hand-code in RTL and easiest to verify. Higher radices (4,
  split-radix) are more efficient but more complex — not worth it for a first
  hardware FFT.

## Other decisions
- Single clock domain (no CDC) for now — no throughput reason for two clocks at
  these data rates. CDC is an optional post-deadline stretch (ASIC talking point).
- Magnitude (sqrt of re^2+im^2) computed in Python on the host, not in hardware,
  to keep the RTL lean for Phase 1.

## Verification approach
- Python golden model (direct DFT + radix-2 + Q1.15 fixed-point) is the source
  of truth. Test vectors exported to model/fft_test_vectors.txt.
- RTL will be checked in ModelSim against these same vectors (self-checking TB).
