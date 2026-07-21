#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include "fft.h"

/* HLS csim/cosim testbench for the AXI-Stream FFT (fft_axis).
 * For each golden vector: pack 16 samples into an input stream, run
 * fft_axis, pop 16 results, compute magnitudes, diff vs golden mag.
 * Parses with fscanf (Vitis apcc miscompiles strtod).
 *   ./fft_tb_axis [path/to/fft_test_vectors.txt]
 */

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
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

/* Drive the DUT: pack a frame from in_R/in_I, run fft_axis, unpack into out_R/out_I. */
static void run_dut(DTYPE in_R[SIZE], DTYPE in_I[SIZE], DTYPE out_R[SIZE], DTYPE out_I[SIZE]) {
    hls::stream<axis_t> in_s, out_s;

    /* --- pack the input frame into the stream --- */
    for (int n = 0; n < SIZE; n++) {
        axis_t t;
        t.data = 0;
        t.data.range(19, 0)  = in_R[n].range(19, 0);
        t.data.range(39, 20) = in_I[n].range(19, 0);
        t.keep = -1; t.strb = -1;
        t.last = (n == SIZE - 1) ? 1 : 0;
        in_s.write(t);
    }

    fft_axis(in_s, out_s);

    /* --- pop the result frame --- */
    for (int k = 0; k < SIZE; k++) {
        axis_t t = out_s.read();
        out_R[k].range(19, 0) = t.data.range(19, 0);
        out_I[k].range(19, 0) = t.data.range(39, 20);
    }
}

static void ref_dft(const double xr[SIZE], const double xi[SIZE], double Xr[SIZE], double Xi[SIZE]) {
    for (int k = 0; k < SIZE; k++) {
        double sr = 0.0, si = 0.0;
        for (int n = 0; n < SIZE; n++) {
            double a = -2.0 * M_PI * (double)k * (double)n / (double)SIZE;
            double c = cos(a), s = sin(a);
            sr += xr[n]*c - xi[n]*s;
            si += xr[n]*s + xi[n]*c;
        }
        Xr[k] = sr;
        Xi[k] = si;
    }
}

/* Run DUT + reference on one ALREADY-QUANTIZED frame.
 * Returns worst |error| over real and imag across all bins; sets *pres to the
 * relative Parseval residual |Sum|X|^2 - N*Sum|x|^2| / (N*Sum|x|^2). */
static double check_frame(DTYPE in_R[SIZE], DTYPE in_I[SIZE], double *pres) {
    DTYPE  out_R[SIZE], out_I[SIZE];
    double xr[SIZE], xi[SIZE], Xr[SIZE], Xi[SIZE];

    /* reference sees the QUANTIZED input -> error reflects only the FFT's arithmetic */
    for (int n = 0; n < SIZE; n++) { xr[n] = (double)in_R[n]; xi[n] = (double)in_I[n]; }

    run_dut(in_R, in_I, out_R, out_I);
    ref_dft(xr, xi, Xr, Xi);

    double worst = 0.0, e_time = 0.0, e_freq = 0.0;
    for (int k = 0; k < SIZE; k++) {
        double er = fabs((double)out_R[k] - Xr[k]);
        double ei = fabs((double)out_I[k] - Xi[k]);
        if (er > worst) worst = er;
        if (ei > worst) worst = ei;
        e_freq += (double)out_R[k]*(double)out_R[k] + (double)out_I[k]*(double)out_I[k];
    }
    for (int n = 0; n < SIZE; n++) e_time += xr[n]*xr[n] + xi[n]*xi[n];

    double denom = (double)SIZE * e_time;              /* Parseval: Sum|X|^2 = N*Sum|x|^2 */
    if (pres) *pres = (denom > 1e-12) ? fabs(e_freq - denom) / denom : 0.0;
    return worst;
}

/* ---- Step 3: randomized differential test (bulk input-space coverage) ---- */
static int random_diff_test(int NTRIAL) {
    const double AMP    = 0.5;     /* |x| <= 0.5 keeps DC <= 8 < 16 (no overflow) */
    const double TOLD   = 3.0e-4;  /* ~2x measured worst 4.6 LSB; 3e-4 ~= 9.8 LSB */

    srand(12345);                  /* fixed seed = reproducible */
    double worst = 0.0, worst_pres = 0.0; int worst_frame = -1;

    for (int t = 0; t < NTRIAL; t++) {
        DTYPE in_R[SIZE], in_I[SIZE];
        for (int n = 0; n < SIZE; n++) {
            double v = ((double)rand() / RAND_MAX * 2.0 - 1.0) * AMP;
            in_R[n] = (DTYPE)v;    /* quantize to Q5.15 */
            in_I[n] = (DTYPE)0;
        }
        double pres; double w = check_frame(in_R, in_I, &pres);
        if (w > worst)         { worst = w; worst_frame = t; }
        if (pres > worst_pres)   worst_pres = pres;
    }

    int pass = (worst < TOLD);
    printf("\n[random-diff] %d frames | worst|err| = %.6f (%.1f LSB) @frame %d | "
           "worst Parseval = %.2e | tol = %.4f -> %s\n",
           NTRIAL, worst, worst * Q_SCALE, worst_frame, worst_pres, TOLD, pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}

/* ---- Step 4: boundary + corner-bin stress frames ---- */
static int one_frame(const char *label, const double src[SIZE], double tol) {
    DTYPE in_R[SIZE], in_I[SIZE];
    for (int n = 0; n < SIZE; n++) { in_R[n] = (DTYPE)src[n]; in_I[n] = (DTYPE)0; }
    double pres; double w = check_frame(in_R, in_I, &pres);
    int pass = (w < tol);
    printf("[bnd %-13s] %s  worst|err| = %.6f (%.1f LSB)  Parseval = %.2e\n",
           label, pass ? "PASS" : "FAIL", w, w * Q_SCALE, pres);
    return pass ? 0 : 1;
}

static int boundary_test(void) {
    const double TOLD = 3.0e-4;   /* ~2x measured worst 4.1 LSB; 3e-4 ~= 9.8 LSB */
    double s[SIZE]; int fails = 0;

    for (int n = 0; n < SIZE; n++) s[n] =  0.9;   fails += one_frame("all +0.9", s, TOLD);   /* near +full scale */
    for (int n = 0; n < SIZE; n++) s[n] = -0.9;   fails += one_frame("all -0.9", s, TOLD);   /* near -full scale */
    for (int n = 0; n < SIZE; n++) s[n] =  0.0;   s[0] = 0.5;
                                                  fails += one_frame("impulse",  s, TOLD);
    for (int n = 0; n < SIZE; n++) s[n] =  0.5;   fails += one_frame("DC 0.5",   s, TOLD);
    for (int n = 0; n < SIZE; n++) s[n] = 0.5 * sin(2.0*M_PI*1.0*n/SIZE);
                                                  fails += one_frame("tone bin1", s, TOLD);   /* low bin */
    for (int n = 0; n < SIZE; n++) s[n] = 0.5 * cos(2.0*M_PI*8.0*n/SIZE);
                                                  fails += one_frame("tone Nyq8", s, TOLD);   /* Nyquist bin */

    printf("[boundary] %s\n", fails ? "FAIL" : "all PASS");
    return fails ? 1 : 0;
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

            /* --- build the input frame and run the DUT via the shared helper --- */
            DTYPE in_R[SIZE], in_I[SIZE], out_R[SIZE], out_I[SIZE];
            for (int n = 0; n < SIZE; n++) {
                in_R[n] = (DTYPE)(insamp[n] / Q_SCALE);
                in_I[n] = (DTYPE)0;
            }
            run_dut(in_R, in_I, out_R, out_I);

            /* --- compare magnitudes vs golden --- */
            double me = 0; int w = -1;
            for (k = 0; k < SIZE; k++) {
                double rr = (double)out_R[k], ii = (double)out_I[k];
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
    int rc4 = (passed == total) ? 0 : 1;

    /* --- extended differential verification --- */
    int ntrial = (argc > 2) ? atoi(argv[2]) : 10000;  /* pass a small count for cosim */
    int rc_rand = random_diff_test(ntrial);
    printf("\n---- boundary / corner-bin frames ----\n");
    int rc_bnd  = boundary_test();

    return (rc4 == 0 && rc_rand == 0 && rc_bnd == 0) ? 0 : 1;
}
