#include <cstdio>
#include <cstring>
#include <cmath>
#include "fft.h"

/* HLS csim/cosim testbench for the AXI-Stream FFT (fft_axis).
 * For each golden vector: pack 16 samples into an input stream, run
 * fft_axis, pop 16 results, compute magnitudes, diff vs golden mag.
 * Parses with fscanf (Vitis apcc miscompiles strtod).
 *   ./fft_tb_axis [path/to/fft_test_vectors.txt]
 */

#define Q_SCALE 32768.0
#define TOL     0.01

static FILE *open_vectors(int argc, char **argv) {
    const char *cands[] = {
        (argc > 1) ? argv[1] : NULL,
        "fft_test_vectors.txt",
        "../../../../fft_test_vectors.txt",
        "../model/fft_test_vectors.txt",
        "../../model/fft_test_vectors.txt",
        "../../../model/fft_test_vectors.txt",
    };
    for (int i = 0; i < 6; i++)
        if (cands[i]) { FILE *f = fopen(cands[i], "r"); if (f) { fprintf(stderr, "[tb] reading %s\n", cands[i]); return f; } }
    return NULL;
}

int main(int argc, char **argv) {
    FILE *f = open_vectors(argc, argv);
    if (!f) { printf("ERROR: cannot open fft_test_vectors.txt\n"); return 2; }

    char tok[256], name[128] = "(unnamed)";
    double insamp[SIZE], expmag[SIZE];
    int have_in = 0, total = 0, passed = 0, k;
    double gmax = 0;

    while (fscanf(f, "%255s", tok) == 1) {
        if (tok[0] == '#') { int ch; while ((ch = fgetc(f)) != EOF && ch != '\n') { } continue; }
        if (tok[0] == '[') { sscanf(tok, "[%127[^]]]", name); continue; }
        if (strcmp(tok, "in:") == 0) {
            have_in = 1;
            for (k = 0; k < SIZE; k++) if (fscanf(f, "%lf", &insamp[k]) != 1) { have_in = 0; break; }
            continue;
        }
        if (strcmp(tok, "mag:") == 0 && have_in) {
            int okr = 1;
            for (k = 0; k < SIZE; k++) if (fscanf(f, "%lf", &expmag[k]) != 1) { okr = 0; break; }
            if (!okr) { have_in = 0; continue; }

            /* --- pack the input frame into a stream --- */
            hls::stream<axis_t> in_s, out_s;
            for (int n = 0; n < SIZE; n++) {
                DTYPE r = (DTYPE)(insamp[n] / Q_SCALE);
                DTYPE im = (DTYPE)0;
                axis_t t;
                t.data = 0;
                t.data.range(19, 0)  = r.range(19, 0);
                t.data.range(39, 20) = im.range(19, 0);
                t.keep = -1; t.strb = -1;
                t.last = (n == SIZE - 1) ? 1 : 0;
                in_s.write(t);
            }

            fft_axis(in_s, out_s);

            /* --- pop the result frame and compare magnitudes --- */
            double me = 0; int w = -1;
            for (k = 0; k < SIZE; k++) {
                axis_t t = out_s.read();
                DTYPE r, im;
                r.range(19, 0)  = t.data.range(19, 0);
                im.range(19, 0) = t.data.range(39, 20);
                double rr = (double)r, ii = (double)im;
                if (fabs(rr) > gmax) gmax = fabs(rr);
                if (fabs(ii) > gmax) gmax = fabs(ii);
                double mag = sqrt(rr * rr + ii * ii);
                double e = fabs(mag - expmag[k]);
                if (e > me) { me = e; w = k; }
            }

            total++;
            int p = (me <= TOL); if (p) passed++;
            printf("[%-14s] %s   max|dMag| = %.5f  @bin %d\n", name, p ? "PASS" : "FAIL", me, w);
            have_in = 0;
        }
    }
    fclose(f);
    printf("\n==== %d/%d vectors passed (tol=%.3f) | max|value|=%.4f ====\n", passed, total, TOL, gmax);
    return (passed == total) ? 0 : 1;
}
