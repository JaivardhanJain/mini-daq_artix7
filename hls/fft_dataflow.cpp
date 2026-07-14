#include "fft.h"

/* ==================================================================
 * Dataflow FFT architecture (pp4fpgas Fig 5.7 idea), sized for N = 16.
 * Stages connected by buffers; #pragma HLS dataflow overlaps them.
 *
 * Twiddles come from a precomputed ROM (no runtime cos/sin). The ROM
 * holds the 8 distinct W16^m = exp(-j*2*pi*m/16) values as (real,imag):
 *     c = cos(2*pi*m/16),  s = -sin(2*pi*m/16)
 * applied as complex multiply (c + j*s).
 * Stage `stage` uses W_DFTpts^j = W16^(j * SIZE/DFTpts), so the ROM
 * index is  j * (SIZE >> stage).  Uses reverse_bits() from bit_reverse.cpp.
 *
 * DTYPE is Q5.15 fixed-point (see fft.h).
 * ================================================================== */

static const DTYPE TW_R[SIZE / 2] = {   /* cos(2*pi*m/16), m = 0..7 */
     (DTYPE) 1.0,
     (DTYPE) 0.9238795325112867,
     (DTYPE) 0.7071067811865476,
     (DTYPE) 0.3826834323650898,
     (DTYPE) 0.0,
     (DTYPE)-0.3826834323650898,
     (DTYPE)-0.7071067811865476,
     (DTYPE)-0.9238795325112867
};
static const DTYPE TW_I[SIZE / 2] = {   /* -sin(2*pi*m/16), m = 0..7 */
     (DTYPE) 0.0,
     (DTYPE)-0.3826834323650898,
     (DTYPE)-0.7071067811865476,
     (DTYPE)-0.9238795325112867,
     (DTYPE)-1.0,
     (DTYPE)-0.9238795325112867,
     (DTYPE)-0.7071067811865476,
     (DTYPE)-0.3826834323650898
};

/* non-in-place bit reverse: reads in, writes to bit-reversed index in out */
void bit_reverse_df(DTYPE in_R[SIZE], DTYPE in_I[SIZE],
                    DTYPE out_R[SIZE], DTYPE out_I[SIZE]) {
    unsigned int i;
    for (i = 0; i < SIZE; i++) {
        unsigned int r = reverse_bits(i);
        out_R[r] = in_R[i];
        out_I[r] = in_I[i];
    }
}

/* one FFT stage, in -> out, twiddles from the ROM */
static void fft_stage(DTYPE in_R[SIZE], DTYPE in_I[SIZE],
                      DTYPE out_R[SIZE], DTYPE out_I[SIZE], int stage) {
    int DFTpts = 1 << stage;          /* 2^stage */
    int numBF  = DFTpts >> 1;         /* DFTpts/2 (butterfly width) */
    int wstep  = SIZE >> stage;       /* ROM index step = SIZE/DFTpts */
    int total  = SIZE >> 1;           /* N/2 = 8 butterflies per stage */

    /* Flattened: one pipelined loop over all N/2 butterflies, so every
     * stage gets a single pipeline fill (balances stage 4). pos/group are
     * the old j (twiddle position) and block index; since numBF/DFTpts are
     * compile-time constants per stage, %/ / fold into shifts/masks. */
    for (int b = 0; b < total; b++) {
        #pragma HLS PIPELINE II=1
        #pragma HLS LOOP_TRIPCOUNT min=8 max=8
        int pos     = b % numBF;            /* twiddle position (= old j) */
        int group   = b / numBF;            /* which butterfly block */
        int i       = pos + group * DFTpts;
        int i_lower = i + numBF;
        DTYPE c = TW_R[pos * wstep];
        DTYPE s = TW_I[pos * wstep];
        DTYPE tR = in_R[i_lower] * c - in_I[i_lower] * s;
        DTYPE tI = in_I[i_lower] * c + in_R[i_lower] * s;
        out_R[i]       = in_R[i] + tR;
        out_I[i]       = in_I[i] + tI;
        out_R[i_lower] = in_R[i] - tR;
        out_I[i_lower] = in_I[i] - tI;
    }
}

/* one wrapper per stage so each is a distinct dataflow process */
void fft_stage_one  (DTYPE iR[SIZE], DTYPE iI[SIZE], DTYPE oR[SIZE], DTYPE oI[SIZE]) { fft_stage(iR, iI, oR, oI, 1); }
void fft_stage_two  (DTYPE iR[SIZE], DTYPE iI[SIZE], DTYPE oR[SIZE], DTYPE oI[SIZE]) { fft_stage(iR, iI, oR, oI, 2); }
void fft_stage_three(DTYPE iR[SIZE], DTYPE iI[SIZE], DTYPE oR[SIZE], DTYPE oI[SIZE]) { fft_stage(iR, iI, oR, oI, 3); }
void fft_stage_four (DTYPE iR[SIZE], DTYPE iI[SIZE], DTYPE oR[SIZE], DTYPE oI[SIZE]) { fft_stage(iR, iI, oR, oI, 4); }

/* top level: input -> bit-reverse -> 4 stages -> output, overlapped */
void fft_dataflow(DTYPE X_R[SIZE], DTYPE X_I[SIZE],
                  DTYPE OUT_R[SIZE], DTYPE OUT_I[SIZE]) {
#pragma HLS dataflow
    DTYPE S1_R[SIZE], S1_I[SIZE];
    DTYPE S2_R[SIZE], S2_I[SIZE];
    DTYPE S3_R[SIZE], S3_I[SIZE];
    DTYPE S4_R[SIZE], S4_I[SIZE];

    bit_reverse_df  (X_R,  X_I,  S1_R, S1_I);
    fft_stage_one   (S1_R, S1_I, S2_R, S2_I);
    fft_stage_two   (S2_R, S2_I, S3_R, S3_I);
    fft_stage_three (S3_R, S3_I, S4_R, S4_I);
    fft_stage_four  (S4_R, S4_I, OUT_R, OUT_I);
}
