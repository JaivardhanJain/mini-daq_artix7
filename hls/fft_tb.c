#include <stdio.h>
#include <string.h>
#include <math.h>
#include "fft.h"

/* HLS csim testbench for the dataflow FFT.
 * Reads model/fft_test_vectors.txt, runs fft_dataflow on each vector,
 * computes bin magnitudes, and diffs vs the golden "mag:" reference.
 * Returns 0 iff every vector passes.
 *
 * NOTE: parses with fscanf (not strtod) -- Vitis HLS apcc miscompiles
 * strtod ("conflicting types for '__strtod'").
 *
 * Run:  ./fft_tb [path/to/fft_test_vectors.txt]
 */

void fft_dataflow(DTYPE X_R[SIZE], DTYPE X_I[SIZE],
                  DTYPE OUT_R[SIZE], DTYPE OUT_I[SIZE]);

#define Q_SCALE 32768.0   /* Q1.15: float value = integer / 2^15 */
#define TOL     0.01      /* magnitude match tolerance */

static FILE *open_vectors(int argc, char **argv) {
    const char *cands[] = {
        (argc > 1) ? argv[1] : NULL,
        "fft_test_vectors.txt",
        "../../../../fft_test_vectors.txt",   /* copied next to project root */
        "../model/fft_test_vectors.txt",
        "../../model/fft_test_vectors.txt",
        "../../../model/fft_test_vectors.txt",
    };
    for (int i = 0; i < 6; i++) {
        if (cands[i]) {
            FILE *f = fopen(cands[i], "r");
            if (f) { fprintf(stderr, "[tb] reading %s\n", cands[i]); return f; }
        }
    }
    return NULL;
}

static void skip_line(FILE *f) {
    int ch;
    while ((ch = fgetc(f)) != EOF && ch != '\n') { }
}

int main(int argc, char **argv) {
    FILE *f = open_vectors(argc, argv);
    if (!f) {
        printf("ERROR: cannot open fft_test_vectors.txt (pass its path as arg 1)\n");
        return 2;
    }

    char tok[256], name[128] = "(unnamed)";
    double insamp[SIZE], expmag[SIZE];
    int have_in = 0, total = 0, passed = 0, k;

    while (fscanf(f, "%255s", tok) == 1) {
        if (tok[0] == '#') { skip_line(f); continue; }        /* comment */
        if (tok[0] == '[') { sscanf(tok, "[%127[^]]]", name); continue; } /* [name] */

        if (strcmp(tok, "in:") == 0) {
            have_in = 1;
            for (k = 0; k < SIZE; k++)
                if (fscanf(f, "%lf", &insamp[k]) != 1) { have_in = 0; break; }
            continue;
        }

        if (strcmp(tok, "mag:") == 0 && have_in) {
            int ok_read = 1;
            for (k = 0; k < SIZE; k++)
                if (fscanf(f, "%lf", &expmag[k]) != 1) { ok_read = 0; break; }
            if (!ok_read) { have_in = 0; continue; }

            DTYPE xr[SIZE], xi[SIZE], orr[SIZE], oii[SIZE];
            for (int n = 0; n < SIZE; n++) {
                xr[n] = (DTYPE)(insamp[n] / Q_SCALE);   /* Q1.15 -> float */
                xi[n] = (DTYPE)0;
            }

            fft_dataflow(xr, xi, orr, oii);

            double maxerr = 0; int worst = -1;
            for (k = 0; k < SIZE; k++) {
                double mag = sqrt((double)orr[k] * orr[k] + (double)oii[k] * oii[k]);
                double err = fabs(mag - expmag[k]);
                if (err > maxerr) { maxerr = err; worst = k; }
            }

            total++;
            int ok = (maxerr <= TOL);
            if (ok) passed++;
            printf("[%-14s] %s   max|dMag| = %.5f  @bin %d\n",
                   name, ok ? "PASS" : "FAIL", maxerr, worst);
            have_in = 0;
        }
    }

    fclose(f);
    printf("\n==== %d/%d vectors passed (tol = %.3f) ====\n", passed, total, TOL);
    return (passed == total) ? 0 : 1;
}
