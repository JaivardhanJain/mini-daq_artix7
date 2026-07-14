#include <math.h>
#include "fft.h"

/* bit_reverse() and reverse_bits() now live in bit_reverse.c
 * (pp4fpgas Fig 5.6 version). */

/* ------------------------------------------------------------------
 * fft: baseline radix-2 decimation-in-time FFT, in place, complex.
 * This is the "typical software" version from pp4fpgas Ch.5 -- correct,
 * but NOT yet optimized for hardware (no interface/optimization pragmas,
 * runtime cos/sin instead of a twiddle ROM). Verify it against the
 * golden vectors first, then restructure.
 * ------------------------------------------------------------------ */
void fft(DTYPE X_R[SIZE], DTYPE X_I[SIZE]) {
    DTYPE temp_R;          /* butterfly temp, real part */
    DTYPE temp_I;          /* butterfly temp, imag part */
    int i, j, k;
    int i_lower;           /* index of lower point in butterfly */
    int step, stage, DFTpts;
    int numBF;             /* butterflies per sub-DFT */
    int N2 = SIZE >> 1;    /* N/2 */

    bit_reverse(X_R, X_I);

    step = N2;
    DTYPE a, e, c, s;

stage_loop:
    for (stage = 1; stage <= M; stage++) {   /* M = log2(SIZE) stages */
        DFTpts = 1 << stage;                 /* points in this sub-DFT = 2^stage */
        numBF  = DFTpts / 2;                 /* butterflies per sub-DFT */
        k = 0;                               /* (vestigial: twiddle-table index) */
        e = -6.283185307178 / DFTpts;        /* -2*pi / DFTpts */
        a = 0.0;

    butterfly_loop:
        for (j = 0; j < numBF; j++) {
            c = cos(a);
            s = sin(a);
            a = a + e;
            /* all butterflies sharing this twiddle W^k */
        dft_loop:
            for (i = j; i < SIZE; i += DFTpts) {
                i_lower = i + numBF;         /* lower point of the butterfly */
                temp_R = X_R[i_lower] * c - X_I[i_lower] * s;
                temp_I = X_I[i_lower] * c + X_R[i_lower] * s;
                X_R[i_lower] = X_R[i] - temp_R;
                X_I[i_lower] = X_I[i] - temp_I;
                X_R[i]       = X_R[i] + temp_R;
                X_I[i]       = X_I[i] + temp_I;
            }
            k += step;
        }
        step = step / 2;
    }
}
