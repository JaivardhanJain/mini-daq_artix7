#ifndef FFT_H
#define FFT_H

#include "ap_fixed.h"
#include "hls_stream.h"      /* must precede '#define SIZE' below --        */
#include "ap_axi_sdata.h"    /* these headers use template<size_t SIZE>.   */

/* ------------------------------------------------------------------
 * Mini-DAQ FFT configuration  (Phase 1: N = 16)
 * ------------------------------------------------------------------ */
#define SIZE 16          /* number of points (must be a power of 2)   */
#define M    4           /* number of stages = log2(SIZE)             */
#define FFT_BITS M       /* index width for bit-reversal (= log2 SIZE) */

/* Datapath type: Q5.15 fixed-point.
 *   ap_fixed<20,5> = 20 bits total, 5 integer bits (incl sign),
 *   15 fractional -> range [-16, 16).
 * The 5 integer bits hold the FFT's bit-growth: a 16-point sum can
 * reach ~16, so a plain Q1.15 (ap_fixed<16,1>, range [-1,1)) would
 * OVERFLOW. Verified: max value across the golden vectors is 8.0.
 * (Full per-stage bit-growth, 16->20, is a later refinement; one
 *  uniform 20-bit type is the simple, correct first cut.)
 */
typedef ap_fixed<20,5> DTYPE;

/* --- AXI4-Stream interface (Day 8) ---------------------------------
 * One complex Q5.15 sample per beat, packed into a 40-bit TDATA:
 *   data[19:0]  = real (Q5.15 raw bits)
 *   data[39:20] = imag (Q5.15 raw bits)
 * TLAST marks the 16th sample of each frame.
 * (hls_stream.h / ap_axi_sdata.h are included at the top of this file,
 *  above '#define SIZE' -- they contain template<size_t SIZE>, which the
 *  SIZE macro would otherwise corrupt.) */
typedef ap_axiu<40, 0, 0, 0> axis_t;   /* 40-bit payload + TLAST/TKEEP/TSTRB */

void fft_axis(hls::stream<axis_t> &in, hls::stream<axis_t> &out);
void fft_dataflow(DTYPE X_R[SIZE], DTYPE X_I[SIZE], DTYPE OUT_R[SIZE], DTYPE OUT_I[SIZE]);
void fft(DTYPE X_R[SIZE], DTYPE X_I[SIZE]);
void bit_reverse(DTYPE X_R[SIZE], DTYPE X_I[SIZE]);
unsigned int reverse_bits(unsigned int input);

#endif /* FFT_H */
