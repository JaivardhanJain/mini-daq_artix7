# ==================================================================
# run_hls.tcl  --  C synthesis for the Mini-DAQ dataflow FFT (Q5.15)
# ------------------------------------------------------------------
# Run from a SPACE-FREE working folder (Vitis forbids spaces in paths):
#     copy sources to C:\hls_minidaq, then:
#     vitis_hls -f run_hls.tcl
# ==================================================================

open_project mini_daq_fft_hls
set_top fft_dataflow                 ;# top-level function to synthesize

# --- design sources (C++ now, for ap_fixed) ---
add_files fft_dataflow.cpp
add_files bit_reverse.cpp

# --- testbench + golden vectors ---
add_files -tb fft_tb.cpp

open_solution "sol1"
set_part {xc7a35tftg256-1}           ;# Mini-DAQ board: XC7A35T-FTG256 (speed grade -1)
create_clock -period 10 -name default ;# 10 ns = 100 MHz

# 1) functional check vs golden vectors
csim_design -argv {C:/hls_minidaq/fft_test_vectors.txt}

# 2) C synthesis -> RTL + timing/area/II report
csynth_design

# 3) (optional, later) verify generated RTL matches C
# cosim_design -argv {C:/hls_minidaq/fft_test_vectors.txt}

exit
