#include "fft.h"

/* ------------------------------------------------------------------
 * reverse_bits: return `input` with its low FFT_BITS bits reversed.
 * Meant to be FULLY UNROLLED in HLS -> collapses to pure wiring.
 * ------------------------------------------------------------------ */
unsigned int reverse_bits(unsigned int input) {
    int i;
    unsigned int rev = 0;
    for (i = 0; i < FFT_BITS; i++) {
        rev = (rev << 1) | (input & 1);   /* push input's LSB into rev */
        input = input >> 1;               /* expose the next input bit */
    }
    return rev;
}

/* ------------------------------------------------------------------
 * bit_reverse: reorder X_R/X_I into bit-reversed index order, in place.
 * The (i < reversed) guard swaps each pair exactly once.
 * ------------------------------------------------------------------ */
void bit_reverse(DTYPE X_R[SIZE], DTYPE X_I[SIZE]) {
    unsigned int reversed;
    unsigned int i;
    DTYPE temp;
    for (i = 0; i < SIZE; i++) {
        reversed = reverse_bits(i);
        if (i < reversed) {
            temp = X_R[i]; X_R[i] = X_R[reversed]; X_R[reversed] = temp;
            temp = X_I[i]; X_I[i] = X_I[reversed]; X_I[reversed] = temp;
        }
    }
}
