#include <cstdio>
#include <cstring>
#include <cmath>
#include "fft.h"

/* HLS csim testbench for the Q5.15 dataflow FFT.
 * Reads model/fft_test_vectors.txt, runs fft_dataflow, computes bin
 * magnitudes, diffs vs the golden "mag:" reference. Returns 0 iff all pass.
 * Parses with fscanf (Vitis apcc miscompiles strtod).
 *   ./fft_tb [path/to/fft_test_vectors.txt]
 */

void fft_dataflow(DTYPE X_R[SIZE], DTYPE X_I[SIZE],
                  DTYPE OUT_R[SIZE], DTYPE OUT_I[SIZE]);

#define Q_SCALE 32768.0   /* Q1.15 input: float value = integer / 2^15 */
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
    if (!f) { printf("ERROR: cannot open fft_test_vectors.txt (pass path as arg 1)\n"); return 2; }

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

            DTYPE xr[SIZE], xi[SIZE], orr[SIZE], oii[SIZE];
            for (int n = 0; n < SIZE; n++) { xr[n] = (DTYPE)(insamp[n] / Q_SCALE); xi[n] = (DTYPE)0.0; }

            fft_dataflow(xr, xi, orr, oii);

            double me = 0; int w = -1;
            for (k = 0; k < SIZE; k++) {
                double rr = (double)orr[k], ii = (double)oii[k];
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
    printf("\n==== %d/%d vectors passed (tol=%.3f) | max|value|=%.4f (range < 16 OK) ====\n",
           passed, total, TOL, gmax);
    return (passed == total) ? 0 : 1;
}
