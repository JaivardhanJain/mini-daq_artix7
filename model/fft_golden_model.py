"""
================================================================================
 Mini-DAQ  |  16-point FFT GOLDEN MODEL
================================================================================
Purpose
-------
This is the "source of truth" for the whole project. Before we write any
hardware (RTL) or HLS, we build a small, trusted FFT here in Python. Later,
when we simulate the Verilog FFT in ModelSim, we feed it the SAME inputs and
check its outputs against the numbers this script produces. If they match, the
hardware is correct.

It contains four things:
  1. direct_dft()     - the textbook DFT formula, O(N^2). Slow but obviously
                        correct. Our first reference.
  2. fft_radix2()     - a decimation-in-time radix-2 FFT built from butterflies
                        and twiddle factors. This is the algorithm the hardware
                        will implement. O(N log N).
  3. fft_fixed()      - a Q1.15 fixed-point version with full bit-growth. This
                        mirrors what the hardware datapath actually does and lets
                        us measure quantization error before we build anything.
  4. test signals + a test-vector exporter for ModelSim.

Author: JJ  |  Phase 1, Day 1
================================================================================
"""

import numpy as np

# ------------------------------------------------------------------------------
# GLOBAL CONFIG
# ------------------------------------------------------------------------------
N = 16          # FFT size (number of points). Written as a variable so we can
                # bump it to 32/64/256 later with no code changes.
Q = 15          # Fixed-point fractional bits. Q1.15 = 1 sign bit + 15 frac bits.
SCALE = 1 << Q  # = 2^15 = 32768. A float value v is stored as the integer
                # round(v * SCALE). So 1.0 -> 32768, 0.5 -> 16384, etc.


# ==============================================================================
# 1. DIRECT DFT  -  the definition, straight from the formula
# ==============================================================================
def direct_dft(x):
    """Compute the DFT the literal way: X[k] = sum_n x[n] * e^(-j2*pi*k*n/N).

    This is O(N^2) and slow, but it is a transcription of the math with no
    cleverness, so it is the reference we trust the most.
    """
    N = len(x)
    X = np.zeros(N, dtype=complex)          # output: N complex numbers
    for k in range(N):                      # one output bin at a time
        for n in range(N):                  # correlate signal with test freq k
            angle = -2j * np.pi * k * n / N
            X[k] += x[n] * np.exp(angle)    # accumulate the running sum
    return X


# ==============================================================================
# 2. RADIX-2 FFT  -  the fast algorithm the hardware will implement
# ==============================================================================
def fft_radix2(x):
    """Recursive decimation-in-time radix-2 FFT.

    The idea: split the input into even-indexed and odd-indexed samples,
    take the FFT of each half, then recombine with 'butterflies'. Recurse
    until the pieces are size 1. This is the exact structure of the RTL.
    """
    N = len(x)
    if N == 1:                       # base case: a size-1 DFT is the sample itself
        return np.array(x, dtype=complex)

    even = fft_radix2(x[0::2])       # FFT of samples 0,2,4,...  (even indices)
    odd  = fft_radix2(x[1::2])       # FFT of samples 1,3,5,...  (odd indices)

    X = np.zeros(N, dtype=complex)
    for k in range(N // 2):
        # Twiddle factor: a unit-length complex number that rotates the phase.
        # W_N^k = e^(-j2*pi*k/N) = cos(theta) - j*sin(theta).
        W = np.exp(-2j * np.pi * k / N)

        t = W * odd[k]               # rotate the odd half ONCE, reuse it twice

        # The butterfly. Note the symmetry W_N^(k+N/2) = -W_N^k, which is why
        # the bottom output uses a minus sign with the same 't'.
        X[k]          = even[k] + t   # top output
        X[k + N // 2] = even[k] - t   # bottom output
    return X


# ==============================================================================
# 3. FIXED-POINT FFT  -  Q1.15, full bit-growth (models the hardware datapath)
# ==============================================================================
def to_fixed(v):
    """Convert a float in [-1, 1) to a Q1.15 integer (round to nearest)."""
    return int(round(v * SCALE))


def cmul_fixed(ar, ai, br, bi):
    """Complex multiply of two fixed-point numbers, with rounding.

    Inputs are integers in Q-format. Multiplying two Qx.15 numbers gives a
    result scaled by 2^15 too much, so after the multiply we shift right by Q
    (with rounding) to get back to Q-format. This is exactly the round-and-
    truncate step the DSP48 multiplier will do in hardware.
    (a+jb)*(c+jd) = (ac-bd) + j(ad+bc)
    """
    re = ar * br - ai * bi
    im = ar * bi + ai * br
    # round-to-nearest right shift by Q bits:
    re = (re + (1 << (Q - 1))) >> Q
    im = (im + (1 << (Q - 1))) >> Q
    return re, im


def fft_fixed(xr, xi):
    """Recursive radix-2 FFT on Q1.15 integers, FULL bit-growth.

    We never scale the adds down, so the word length grows ~1 bit per stage
    (16 -> 20 bits over 4 stages for N=16). Python ints are unbounded, so this
    faithfully models a 'full-growth' hardware datapath with no overflow.
    xr, xi are lists of integers (real and imaginary parts).
    """
    N = len(xr)
    if N == 1:
        return list(xr), list(xi)

    er, ei = fft_fixed(xr[0::2], xi[0::2])   # even half
    orr, oi = fft_fixed(xr[1::2], xi[1::2])  # odd half

    Xr = [0] * N
    Xi = [0] * N
    for k in range(N // 2):
        # Quantize the twiddle factor to Q1.15 integers (a ROM lookup in HW).
        wr = to_fixed(np.cos(-2 * np.pi * k / N))
        wi = to_fixed(np.sin(-2 * np.pi * k / N))

        tr, ti = cmul_fixed(orr[k], oi[k], wr, wi)   # W * odd[k]

        Xr[k]          = er[k] + tr      # top output  (add, grows 1 bit)
        Xi[k]          = ei[k] + ti
        Xr[k + N // 2] = er[k] - tr      # bottom output (subtract)
        Xi[k + N // 2] = ei[k] - ti
    return Xr, Xi


def fft_fixed_wrapper(x_float):
    """Helper: take a float signal, quantize to Q1.15, run fixed FFT, and
    return the result rescaled back to float so we can compare with the
    floating-point reference."""
    xr = [to_fixed(v) for v in x_float]   # real input
    xi = [0] * len(x_float)               # imaginary part is zero (real signal)
    Xr, Xi = fft_fixed(xr, xi)
    # Rescale integers back to float (divide out the Q1.15 scale factor).
    return np.array([complex(r, i) / SCALE for r, i in zip(Xr, Xi)])


# ==============================================================================
# 4. TEST SIGNALS  -  known inputs with known, easy-to-check outputs
# ==============================================================================
def sig_dc(N, level=0.5):
    """Constant signal -> all energy in bin 0 only."""
    return np.full(N, level)


def sig_sine(N, bin_k, amp=0.5):
    """A sine sitting exactly on bin 'bin_k' -> one clean spike at that bin."""
    n = np.arange(N)
    return amp * np.sin(2 * np.pi * bin_k * n / N)


def sig_two_tone(N, k1, k2, amp=0.25):
    """Two sines -> two spikes, at bins k1 and k2."""
    n = np.arange(N)
    return amp * (np.sin(2 * np.pi * k1 * n / N) + np.sin(2 * np.pi * k2 * n / N))


def sig_impulse(N):
    """A single unit impulse -> a flat spectrum (all bins equal magnitude)."""
    x = np.zeros(N)
    x[0] = 0.9
    return x


# ==============================================================================
# 5. VERIFICATION + TEST-VECTOR EXPORT
# ==============================================================================
def compare(name, x):
    """Run all three FFTs on signal x, print magnitudes, and report errors."""
    ref_np = np.fft.fft(x)          # numpy: the ultimate ground truth
    ref_dft = direct_dft(x)         # our hand DFT
    ref_r2 = fft_radix2(x)          # our radix-2 (the HW algorithm)
    fx = fft_fixed_wrapper(x)       # our Q1.15 fixed-point model

    # Errors relative to numpy:
    err_dft = np.max(np.abs(ref_dft - ref_np))
    err_r2 = np.max(np.abs(ref_r2 - ref_np))
    err_fx = np.max(np.abs(fx - ref_np))

    print(f"\n--- {name} ---")
    print("bin :   |numpy|   |radix2|  |fixedpt|")
    for k in range(len(x)):
        print(f"{k:3d} : {abs(ref_np[k]):8.3f}  {abs(ref_r2[k]):8.3f}  {abs(fx[k]):8.3f}")
    print(f"max error  direct_dft vs numpy : {err_dft:.2e}")
    print(f"max error  radix2     vs numpy : {err_r2:.2e}")
    print(f"max error  FIXED-PT   vs numpy : {err_fx:.4f}   <-- quantization error")
    return ref_np


def export_test_vectors(filename="fft_test_vectors.txt"):
    """Write known input/output pairs to a file for the ModelSim testbench.

    Format per test: input samples as Q1.15 hex, then expected output
    magnitudes (float). The hardware testbench will read the inputs, run the
    RTL FFT, and compare against these expected values.
    """
    tests = {
        "dc":       sig_dc(N),
        "sine_bin3": sig_sine(N, 3),
        "two_tone_3_5": sig_two_tone(N, 3, 5),
        "impulse":  sig_impulse(N),
    }
    with open(filename, "w") as f:
        f.write("# Mini-DAQ FFT test vectors  (N=%d, Q1.%d)\n" % (N, Q))
        for name, x in tests.items():
            X = np.fft.fft(x)
            f.write(f"\n[{name}]\n")
            f.write("# input samples as signed Q1.15 integers:\n")
            f.write("in:  " + " ".join(str(to_fixed(v)) for v in x) + "\n")
            f.write("# expected output magnitudes (float reference):\n")
            f.write("mag: " + " ".join(f"{abs(v):.4f}" for v in X) + "\n")
    print(f"\nWrote test vectors to {filename}")


# ==============================================================================
# MAIN
# ==============================================================================
if __name__ == "__main__":
    print("=" * 60)
    print(f"Mini-DAQ FFT golden model   N={N}, Q1.{Q}")
    print("=" * 60)

    compare("DC signal (expect spike at bin 0)", sig_dc(N))
    compare("Sine on bin 3 (expect spike at bins 3 and 13)", sig_sine(N, 3))
    compare("Two tones bins 3 & 5", sig_two_tone(N, 3, 5))
    compare("Impulse (expect flat spectrum)", sig_impulse(N))

    export_test_vectors()
    print("\nDone. If the three 'max error' lines are ~0 (except fixed-point,")
    print("which is small), the golden model is trustworthy.")
