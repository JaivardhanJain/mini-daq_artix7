#include "fft.h"

/* ==================================================================
 * fft_axis  --  AXI4-Stream wrapper around the verified fft_dataflow.
 *
 * Reads one 16-sample frame off the input stream, runs the FFT, and
 * writes the 16 results out (TLAST on the last). The core FFT math is
 * unchanged (still fft_dataflow); this only adapts the I/O to streams.
 *
 * Payload packing (per beat): data[19:0]=real, data[39:20]=imag,
 * both Q5.15 raw bits.
 * ================================================================== */
void fft_axis(hls::stream<axis_t> &in, hls::stream<axis_t> &out) {
#pragma HLS INTERFACE axis port=in
#pragma HLS INTERFACE axis port=out

    DTYPE X_R[SIZE], X_I[SIZE], OUT_R[SIZE], OUT_I[SIZE];

    /* ---- read one frame of 16 complex samples ---- */
read_in:
    for (int n = 0; n < SIZE; n++) {
#pragma HLS PIPELINE II=1
        axis_t t = in.read();          /* blocks until a sample arrives */
        DTYPE r, im;
        r.range(19, 0)  = t.data.range(19, 0);
        im.range(19, 0) = t.data.range(39, 20);
        X_R[n] = r;
        X_I[n] = im;
    }

    /* ---- run the verified FFT core ---- */
    fft_dataflow(X_R, X_I, OUT_R, OUT_I);

    /* ---- write one frame of 16 results, TLAST on the last ---- */
write_out:
    for (int k = 0; k < SIZE; k++) {
#pragma HLS PIPELINE II=1
        axis_t t;
        t.data.range(19, 0)  = OUT_R[k].range(19, 0);
        t.data.range(39, 20) = OUT_I[k].range(19, 0);
        t.keep = -1;                   /* all bytes valid */
        t.strb = -1;
        t.last = (k == SIZE - 1) ? 1 : 0;
        out.write(t);
    }
}
