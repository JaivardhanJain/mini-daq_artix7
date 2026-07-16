# Mini-DAQ HLS FFT — Engineering Log & Interview Prep

**What this document shows:** an honest, blow-by-blow record of building the
16-point FFT in Vitis HLS — what was built, every problem hit, what was tried,
how each was fixed, and exactly what each directive did and saved. It is the
narrative/"story" doc; the raw before/after synthesis tables live in the
companion `hls_synthesis_results.md`. Written so the decisions can be defended
from memory (e.g. in an interview).

---

## 1. What was built

A 16-point, radix-2 decimation-in-time FFT as an HLS **dataflow** pipeline:

```
input -> bit_reverse -> stage1 -> stage2 -> stage3 -> stage4 -> output
```

- Split into 5 concurrent processes (bit-reverse + 4 butterfly stages),
  connected by intermediate buffers.
- Twiddle factors in a precomputed **ROM** (no runtime sin/cos).
- Number format **Q5.15 fixed-point** (`ap_fixed<20,5>`).
- Inner butterfly loop pipelined at **II=1**.
- Target **XC7A35T-FTG256-1**, 100 MHz.
- Verified by C simulation against the Python golden model's test vectors.

Files: `fft.h`, `fft_dataflow.cpp` (stages + top), `bit_reverse.cpp`
(`reverse_bits` + in-place `bit_reverse`), `fft_tb.cpp` (testbench),
`run_hls.tcl` (build script).

---

## 2. Directives used — what each did and what it saved

### 2.1 `#pragma HLS dataflow` (top-level function)
**What it does:** turns the sequence of stage-function calls into concurrent
processes that run at the same time on different data, connected by
handshaked buffers (ping-pong / PIPO memories that HLS inserts automatically).
**What it saved:** without it, the stages run one-after-another and throughput
= sum of all stage latencies. With it, the stages overlap so throughput is set
by the **slowest single stage**, and successive FFT frames pipeline through the
4 stages. This is *task-level* (coarse-grain) pipelining.
**Evidence:** synthesis log — "Applying dataflow ... detected/extracted 5
process functions"; buffers implemented as PIPO.

### 2.2 `#pragma HLS PIPELINE II=1` (inner butterfly loop)
**What it does:** overlaps successive iterations of the butterfly loop so a new
butterfly starts every clock cycle (Initiation Interval = 1). This is
*operation-level* (fine-grain) pipelining, nested inside the coarse dataflow.
**What it saved:** without it, each butterfly finishes before the next starts,
so the effective II equals the butterfly's latency (its "Depth"). With it, II
drops to 1 — roughly a **Depth-times throughput improvement** on the loop.
**Evidence:** synthesis reported `Final II = 1` on every stage's loop.
**Why no ARRAY_PARTITION was needed:** each array (in_R, in_I, out_R, out_I)
sees only 2 accesses per cycle, which a standard 2-port BRAM already supplies —
so II=1 was reachable without splitting memories. (Partitioning would only be
needed if the butterflies were *unrolled* to run several per cycle.)

### 2.3 Twiddle ROM (design change, enables clean synthesis)
**What it does:** the 8 distinct W16 twiddle values are stored in a `static
const` array. HLS synthesizes it as a small ROM and each stage indexes it by
`j * (SIZE >> stage)`.
**What it saved:** replaced runtime `cos()`/`sin()`, which HLS would implement
as a large, slow floating-point trig core. The ROM is a handful of constants
and a lookup.
**Evidence:** synthesis log — "Implementing memory ..._TW_R_rom using auto ROMs".

### 2.4 `reverse_bits` fully unrolled (automatic, but by design)
**What it does:** the bit-reversal loop is written to be fully unrolled; when it
is, each output bit is just a specific input bit.
**What it saved:** it collapses to pure **wiring with zero logic / near-zero
latency**, instead of a sequential shift/OR loop whose latency scales with the
bit count. HLS unrolled it automatically (factor 4 = FFT_BITS) when pipelining
the parent loop.

### 2.5 Loop-flatten + `LOOP_TRIPCOUNT` (applied)
Each stage's two nested loops were rewritten as a single flat loop over all
N/2 = 8 butterflies, with `#pragma HLS PIPELINE II=1` and
`#pragma HLS LOOP_TRIPCOUNT min=8 max=8`.
**What it did:** the nested loops weren't a perfect nest (twiddle reads sat
between them), so HLS pipelined only the inner loop and stage 4 paid a pipeline
fill per butterfly (~48 cycles). The flat loop gets one fill.
**What it saved:** stage 4 dropped ~48 -> 14 cycles; stages balanced to
10/14/14/14 (bit_rev 18); top-level latency resolved to 74 cycles, interval 19.
And less control logic: LUT 1587 -> 1350 (-15%), FF 2078 -> 1668 (-20%).
The constant loop bound (8) also resolved the previously-`?` latency report,
making the `LOOP_TRIPCOUNT` redundant but kept as documentation.

### 2.6 Pending directive (understood, not yet applied)
- `ap_ctrl_chain` interface — enables frame-to-frame overlap so consecutive
  FFTs pipeline (needed for a continuous streaming DAQ; see 3.8).

---

## 3. Problems hit and how they were solved (chronological)

### 3.1 Baseline code synthesizes to poor hardware
**Symptom / understanding:** the pp4fpgas "typical software" FFT compiles but
would give slow, huge hardware — runtime `cos`/`sin`, no interface or
optimization pragmas, in-place single arrays with port pressure.
**Action:** treated it as a *starting point*, not the deliverable. Rebuilt it as
the dataflow architecture (Fig 5.7 idea) with separate stage functions.

### 3.2 Needed a functional reference before optimizing
**Action:** used the Python golden model (direct DFT + radix-2 + Q1.15) and its
exported test vectors as the source of truth. Wrote a C testbench that runs the
FFT, computes bin magnitudes, and diffs them against the golden `mag:` values.
Verified 4/4 vectors pass *before* touching pragmas. (Correct-first, fast-second.)

### 3.3 Vitis rejects project paths containing spaces
**Symptom:** `ERROR: [HLS 200-70] Project/solution path '...Wadhwani Lab
Research/Mini DAQ/...' contains illegal character ' '.`
**Cause:** Vitis shells out to compilers/tools whose command lines break on
unquoted spaces, so it forbids spaces in the project path outright.
**What was tried:** running directly in the OneDrive project folder — failed.
**Fix:** created a space-free scratch build folder `C:\hls_minidaq`, copied the
sources there, and ran `vitis_hls -f run_hls.tcl` from there. Source of truth
stays in the project folder; the scratch folder is just for building.

### 3.4 apcc miscompiles `strtod` in the testbench
**Symptom:** `error: conflicting types for '__strtod'` during csim compile.
**Cause:** a known Vitis HLS quirk — its bundled compiler (`apcc`) generates a
conflicting declaration for a few libc functions, `strtod` among them.
**Fix:** rewrote the testbench parser to read numbers with `fscanf` instead of
`strtod`. csim then compiled and passed 4/4.

### 3.5 Float design is DSP-bound (does not fit)
**Symptom:** first csynth (32-bit float) used **90 DSP48s** — 200% of the
XC7A15T (45 DSP) and 100% of the XC7A35T (90 DSP), plus 86% LUT.
**Cause:** floating-point multipliers/adders are DSP-hungry (a float multiply
~3 DSP, float add ~2), and the FFT has many.
**Fix:** switched the datapath type to **fixed-point** — the project's planned
Q1.15/Q5.15 decision. This is an *area* fix (type change), distinct from the
*throughput* fixes (the pipeline/dataflow directives).

### 3.6 `ap_fixed` is C++-only; project was C
**Symptom:** VS Code `cannot open source file "ap_fixed.h"` (cosmetic include
path) — but the real blocker is that `ap_fixed` is a C++ template and the files
were `.c` (compiled as C, no templates).
**Fix:** converted the HLS sources from `.c` to `.cpp` (standard for any HLS
design using `ap_fixed`/`ap_int`/`hls::stream`) and pointed the tcl at the
`.cpp` files. Algorithm unchanged.

### 3.7 A naive `ap_fixed<16,1>` would overflow
**Symptom / analysis:** Q1.15 (`ap_fixed<16,1>`) has range [-1, 1), but the FFT
sums grow with bit-growth — the DC bin reaches 8.0. That would overflow/wrap.
**Fix:** used **Q5.15 (`ap_fixed<20,5>`)**, range [-16, 16) — the 5 integer bits
hold the growth, matching the design-notes "16->20 bits over 4 stages" plan.
**Verification:** pre-checked in an ap_fixed emulation and confirmed in Vitis
csim: 4/4 pass, max error 0.0001, **peak value 8.0 < 16** (2x headroom).

### 3.8 "dataflow-on-top ... ap_ctrl_hs" warning
**Symptom:** `WARNING [HLS 200-786] ... Overlapped execution of successive
kernel calls will not happen unless interface mode 'ap_ctrl_chain' is used.`
**Meaning:** the 4 stages overlap *within* one FFT call, but consecutive FFT
frames don't yet overlap. For a continuous streaming DAQ we'd switch the
top-level control to `ap_ctrl_chain`. Noted as a follow-up; fine for now.

### 3.9 Stage 4 is the throughput bottleneck ("cannot flatten") — RESOLVED
**Symptom:** `WARNING [HLS 200-960] Cannot flatten loop ... the outer loop is
not a perfect loop` on stages 2-4.
**Cause:** the two stage loops aren't a perfect nest (the twiddle ROM reads sit
between the outer and inner loop), so HLS pipelines only the inner loop. Stage
4's inner loop runs once, so its 8 butterflies live in the outer loop and each
pays a fresh pipeline fill — making stage 4 the slowest stage.
**Fix (done):** rewrote each stage as a single flat 8-iteration loop (deriving
the twiddle position and indices from one counter). The warnings disappeared,
stage 4 dropped ~48 -> 14 cycles, stages balanced (10/14/14/14), and LUT/FF
dropped ~15-20%. csim still 4/4. (See 2.5.)

### 3.10 Latency reported as `?` — RESOLVED
**Symptom:** top-level and stages 2-4 show `?` for latency/interval.
**Cause:** the loop bounds vary with `stage`, so HLS can't statically bound
them (the same TRIPCOUNT situation the pp4fpgas text describes).
**Fix (done):** the loop-flatten made the loop bound a compile-time constant
(8), which by itself resolved the `?` (top latency 74, interval 19).
`#pragma HLS LOOP_TRIPCOUNT min=8 max=8` was added as documentation.

### 3.11 "out of bound array access" warnings
**Symptom:** HLS 214-167 on the butterfly array writes.
**Analysis:** false alarms — `i_lower = i + numBF` is always < 16; csim passing
confirms no real overflow. Can be silenced later with an `assert` on the index.

### 3.12 `SIZE` macro collides with `hls_stream.h` template (Day 8)
**Symptom:** csim of the AXI-Stream version failed to compile:
`error: expected '>' before numeric constant` pointing at `#define SIZE 16`,
expanded inside `hls_stream_thread_unsafe.h`'s `template<size_t SIZE>`.
**Cause:** `fft.h` did `#define SIZE 16` and then `#include "hls_stream.h"`
*after* it. The preprocessor textually replaced the header's `SIZE` template
parameter with `16`, producing `template<size_t 16>` -- nonsense. `SIZE` is too
generic a macro name.
**Fix (done):** moved `#include "hls_stream.h"` and `#include "ap_axi_sdata.h"`
to the top of `fft.h`, *above* `#define SIZE`, so the headers are parsed while
`SIZE` is still an ordinary identifier. Streaming logic was unaffected.
**Cleaner long-term fix (deferred):** rename the macro `SIZE` -> `FFT_SIZE`
everywhere to avoid the collision entirely.
**Lesson:** include third-party/library headers before defining short, common
macro names; or namespace your macros (`FFT_SIZE`).

---

## 4. Verification methodology (how correctness was ensured)

1. **Golden model first** — Python direct DFT (O(N^2), obviously correct) +
   radix-2 + Q1.15 fixed-point, cross-checked against NumPy.
2. **Test vectors** — DC, single sine (bin 3), two-tone (bins 3 & 5), impulse;
   input as Q1.15 integers, expected output magnitudes as float reference.
3. **C simulation (csim)** — runs the HLS FFT on each vector, computes bin
   magnitudes, diffs vs golden with a tolerance; returns non-zero on any fail
   so the tool flags it.
4. **Pre-checks** before Vitis — compiled and ran with gcc/g++ against a direct
   DFT and against an `ap_fixed` emulation to catch bugs and confirm the Q5.15
   range was sufficient, before spending a Vitis run.
5. **csynth** — read timing (Fmax), II per loop, and utilization; used the
   utilization table to prove the fixed-point design fits.

---

## 5. Results (measured)

Three synthesis runs, in order: **Run 1** float baseline (dataflow + pipeline +
twiddle ROM) -> **Run 2** switch to Q5.15 fixed-point -> **Run 3** loop-flatten.
5.a compares Run 1->2 (area); 5.b compares Run 2->3 (latency/balance).
(Full reasoning also in `hls_synthesis_results.md`.)

### 5.a  Float baseline vs Q5.15 fixed-point (the AREA win)

| Metric          | Run 1: Float | Run 2: Q5.15 | Change             |
|-----------------|--------------|--------------|--------------------|
| DSP48           | 90           | 12           | -87% (7.5x fewer)  |
| LUT             | 8,986        | 1,587        | -82%               |
| FF              | 13,982       | 2,078        | -85%               |
| BRAM_18K        | 0            | 0            | —                  |
| Estimated Fmax  | 168 MHz      | 152 MHz      | both > 100 MHz     |
| Butterfly depth | 21 cycles    | 6 (stg1: 2)  | ~3.5x shorter      |
| csim            | 4/4 pass     | 4/4 pass     | both correct       |

**Why it changed:** float multiply/add cores each eat several DSP48s plus large
mantissa align/normalize/round logic (LUT + FF); a Q5.15 (20-bit) multiply fits
one DSP48 and the adds go to LUTs — so DSP, LUT and FF all collapse. Fmax dips
slightly (168->152) because the float cores are very deeply pipelined (depth 21,
short per-stage paths, high clock ceiling) while the fixed MAC has fewer
pipeline registers (depth 6) and a marginally longer path — *educated guess*,
still > 100 MHz. On the XC7A35T this is **13% DSP / 7% LUT / 4% FF** vs float at
100% DSP, leaving ~7/8 of the fabric for the rest of the SoC. (Stage 1 uses
**0 DSP** — twiddle W^0 = 1, pure add/sub; stages 2-4 use 4 each.)

### 5.b  Q5.15 nested vs flattened loops (the LATENCY / BALANCE win)

| Metric             | Run 2: Nested    | Run 3: Flattened          |
|--------------------|------------------|---------------------------|
| DSP48              | 12               | 12  (unchanged)           |
| LUT                | 1,587            | 1,350  (-15%)             |
| FF                 | 2,078            | 1,668  (-20%)             |
| Estimated Fmax     | 152 MHz          | 152 MHz  (unchanged)      |
| Stage 4 latency    | ~48 (bottleneck) | 14                        |
| Per-stage latency  | ? / imbalanced   | 10 / 14 / 14 / 14 (bit_rev 18) |
| Top-level latency  | ? (unresolved)   | 74 cycles (0.74 us)       |
| Top-level interval | ?                | 19 cycles                 |
| csim               | 4/4 pass         | 4/4 pass                  |

**Why it changed:** DSP is unchanged because the flatten only alters loop
*control*, not the arithmetic. LUT/FF drop because one flat loop needs a single
counter and one pipeline fill instead of two counters, strided addressing, and
a fill/drain repeated per outer iteration — less control logic and fewer flush
registers (*educated guess*). Stage 4 falls ~48->14 because the nested loops
weren't a perfect nest, so HLS pipelined only the inner loop and stage 4 (inner
trip = 1) paid a pipeline fill per butterfly; the flat loop pays one fill, so
all stages balance. And the constant loop bound (8) let HLS finally compute the
latency that was `?` before.

---

## 5.c  Cosim — RTL verification (Day 8, Hour 1)

Ran `cosim_design`: the generated Verilog RTL was simulated in xsim, driven by
the same self-checking C testbench. **Result: `C/RTL co-simulation PASS`** (4/4
vectors, pre- and post-sim C checks). This is the step that proves HLS built
what the C meant — csim only ran the C on the CPU; cosim ran the actual
hardware. It also confirmed the estimates with a real sim: measured interval
= **19 cycles** (transactions 190 ns apart) and latency ~76 ≈ the 74 estimate,
deadlock detector clean. So 74/19 are now measured, not estimated.

## 6. Known remaining work (honest status)

- **AXI-Stream interfaces** (Day 8, Hours 2-3, in progress) to integrate with
  XADC -> FFT -> MicroBlaze.
- `ap_ctrl_chain` / `ap_ctrl_none` for frame-to-frame overlap (Day 8, Hour 4).
- `export_design` to package the Vivado IP (Day 8, Hour 4).
- Later: per-stage bit-growth types (vs the single uniform Q5.15), scale N to 64-256.

---

## 7. Likely interview questions (and the honest answers)

- **"Why fixed-point and not float?"** Float was correct but used 90 DSP and
  maxed the chip; Q5.15 cut it to 12 DSP (13% of the device) with the same csim
  pass and equivalent accuracy (error ~1e-4). Measured, not assumed.
- **"What does the dataflow pragma actually do vs pipeline?"** Dataflow overlaps
  whole stages (coarse, task level, handshaked buffers); pipeline overlaps loop
  iterations within a stage (fine, cycle level, II). I used both, nested.
- **"How did you get II=1, and did you need array partitioning?"** Pipelined the
  butterfly loop; II=1 was reachable without partitioning because each array
  only needs 2 accesses/cycle, which a 2-port BRAM supplies. Partitioning is
  only needed when unrolling butterflies to run several per cycle.
- **"Why is one stage a bottleneck?"** The two loops aren't a perfect nest, so
  only the inner loop pipelines; stage 4's inner loop runs once, so it pays a
  pipeline fill per butterfly. Fix is to flatten to a single loop.
- **"Why the twiddle ROM?"** To avoid a runtime sin/cos core — the twiddles are
  known constants, so a small ROM lookup is far cheaper.
- **"How did you verify it?"** Python golden model -> test vectors -> csim diff,
  with gcc/ap_fixed pre-checks before each Vitis run.
- **"What would you do next / what's not done?"** See section 6 — I can name the
  exact remaining directives and integration steps and what each buys.

---

## 8. AXI-Stream interface — design decisions (Day 8, Hours 2-3)

The FFT was re-interfaced from memory-mapped array ports (`ap_memory`) to
AXI4-Stream so it can drop into the streaming DAQ pipeline (XADC -> FFT ->
MicroBlaze/DMA). Key decisions and why:

- **AXI4-Stream, not AXI4-Lite or full AXI4 memory-mapped.** The FFT datapath
  is a *stream*: samples are consumed in order, one after another, with no
  addressing. AXI4-Stream matches that exactly and sustains 1 beat/cycle with
  back-pressure — ideal for a continuous XADC feed.
  *Why not AXI4-Lite:* it is a single-word, register-oriented, memory-mapped
  interface meant for **control/status** (start/done/config), not bulk data — far
  too slow and semantically wrong for the sample stream.
  *Why not full AXI4-MM:* addressed bursts + IDs are machinery the FFT never
  needs (no random access to its input), so it would be pure overhead.
  *Ecosystem:* Xilinx DMA (MM2S/S2MM), AXIS FIFOs, and DSP IP all speak
  AXI-Stream, so this is the canonical `XADC -> FFT -> DMA -> MicroBlaze` flow.
  *Not either/or:* the final design will likely pair **AXI4-Stream for the data
  plane** with a small **AXI4-Lite control plane** (start/stop, Phase-4
  mode-select, status). Full AXI4-MM would only apply if the FFT had to master
  DRAM directly for large buffered transforms — not the case for N=16.

- **Wrap, don't rewrite.** Added a thin top wrapper `fft_axis` that does only
  stream I/O and calls the *unchanged, verified* `fft_dataflow` core.
  *Why:* the FFT math was already csim/cosim-verified; re-interfacing should not
  risk it. `fft_axis` = the loading dock; `fft_dataflow` = the assembly line.

- **40-bit TDATA = one complex Q5.15 sample per beat** (`data[19:0]`=real,
  `data[39:20]`=imag).
  *Why 40:* a Q5.15 value is 20 bits; a complex number is two of them = 40, the
  tightest fit. It is also byte-aligned (40 = 5 bytes), which AXI-Stream wants
  (TKEEP/TSTRB are 1 bit/byte). *Alternatives:* 32 bits is too small to hold two
  20-bit values; 64 bits works but wastes 24 idle bits/beat. 40 is the minimal
  clean width.

- **One sample per beat / 16 beats per frame, TLAST on the 16th.**
  *Why:* keeps "1 sample = 1 beat" so framing is simple; TLAST delimits each
  16-point spectrum for a downstream DMA/consumer. Splitting real/imag across
  beats would double the beat count and complicate framing.

- **`keep = strb = -1` (all ones).**
  *Why:* asserts "all 5 bytes are valid data." `-1` in an unsigned N-bit field
  is all 1s (two's-complement), a width-agnostic way to say "all bytes present."
  Leaving them unset could let a downstream block / the AXIS protocol checker
  treat bytes as null.

- **No TUSER/TID/TDEST (`ap_axiu<40,0,0,0>`).**
  *Why:* the link is point-to-point (one source -> one sink), so there is no
  routing to do. TDEST/TID only matter behind an AXI-Stream switch that fans a
  stream out to multiple destinations; we have none, so those wires would be dead.

- **Uniform `axis_t` on both input and output** even though the input imag is
  always 0 (real XADC samples).
  *Why:* one shared 40-bit type keeps the code simple; it costs only ~20 idle
  input wires. A separate 20-bit input stream could reclaim them later (e.g. to
  match a DMA data width) — deferred as a minor optimization.

- **`#pragma HLS INTERFACE axis` on the top-level stream ports.**
  *Why:* it makes each top-level `hls::stream` a standard AXI4-Stream port
  (TDATA/TVALID/TREADY/TLAST...) that snaps into Xilinx AXIS IP. Without it a
  top-level stream is a generic `ap_fifo` port; an *internal* stream (function to
  function) is just an on-chip FIFO.

- **Deferred:** block-level control (`ap_ctrl_chain`/`ap_ctrl_none`) for
  frame-to-frame overlap is left to Hour 4 — Hours 2-3 only prove the streaming
  interface is functionally correct.

## 9. FAQ — AXI-Stream & verification concepts

**Q: csim vs cosim?** csim compiles the C/C++ with gcc and runs it on the CPU —
it tests the *algorithm* (fast). cosim runs the HLS-*generated RTL* in a
simulator (xsim), driven by the same testbench — it tests the *hardware*,
cycle-accurate. csim answers "is my C correct?"; cosim answers "does the
generated hardware match my C?" (and gives measured latency/interval).

**Q: What is AXI4-Stream and what do the wires do?** A one-directional,
point-to-point streaming bus. TDATA = payload; TVALID (from source) = "data is
valid"; TREADY (from sink) = "I can accept it"; a **beat transfers only when
TVALID and TREADY are both high** (this handshake gives lossless back-pressure).
TLAST = last beat of a frame; TKEEP/TSTRB = per-byte valid/type qualifiers.

**Q: What is a data beat?** One transfer on the bus — the TDATA (+ side-signals)
handed across in a single successful handshake. Here 1 beat = 1 complex sample;
16 beats = 1 FFT frame (TLAST on the 16th). "Beat" means an *actual* transfer,
which only happens on a cycle where both TVALID and TREADY are high.

**Q: What is a sink (and source/master/slave)?** The sink is the receiver of a
stream (drives TREADY); the source/master is the sender (drives TVALID/TDATA).
Data flows source -> sink. In `fft_axis`, the input port is a sink (`in.read()`),
the output port is a source (`out.write()`).

**Q: Why is TDATA 40 bits?** 20-bit real + 20-bit imag (two Q5.15 values), the
smallest byte-aligned width holding one complete complex sample per beat.

**Q: What is routing (TDEST/TID)?** Choosing among multiple destinations when a
stream switch fans data out to several sinks. TDEST = the "address" on the beat;
TID = which source it came from. Irrelevant for a single point-to-point link, so
we set those widths to 0.

**Q: What does `#pragma HLS INTERFACE axis` do?** Turns a top-level `hls::stream`
argument into a physical AXI4-Stream port. Without it: an internal stream is an
on-chip FIFO, and a top-level stream defaults to a generic `ap_fifo` interface.
With it: a standard AXIS port that interoperates with Xilinx streaming IP.
(Note: AXI-Stream is a standardized *point-to-point* interface, not a shared
addressed bus like AXI memory-mapped.)

**Q: Why `keep = strb = -1`?** `-1` fills an unsigned fixed-width field with all
1s, i.e. "all bytes valid" — the width-agnostic idiom.

**Q: Difference between `fft_dataflow` and `fft_axis`?** `fft_axis` is the outer
AXI-Stream I/O shell (bus <-> arrays); `fft_dataflow` is the inner engine that
does the overlapped 4-stage FFT compute. `fft_axis` does NOT direct the
inter-stage pipelining — that is `fft_dataflow`'s `dataflow` pragma. Once
`fft_axis` is the top, `fft_dataflow` becomes an internal block (its arrays are
on-chip buffers, not external ports).

_Phase 1 HLS bring-up log. Companion to docs/hls_synthesis_results.md._
