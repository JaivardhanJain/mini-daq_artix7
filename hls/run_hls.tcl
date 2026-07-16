# ==================================================================
# run_hls.tcl  --  C synthesis for the Mini-DAQ dataflow FFT (Q5.15)
# ------------------------------------------------------------------
# Run from a SPACE-FREE working folder (Vitis forbids spaces in paths):
#     copy sources to C:\hls_minidaq, then:
#     vitis_hls -f run_hls.tcl
# ==================================================================

open_project mini_daq_fft_hls
set_top fft_axis                     ;# AXI-Stream top (wraps fft_dataflow)

# --- design sources (C++, ap_fixed + hls::stream) ---
add_files fft_axis.cpp
add_files fft_dataflow.cpp
add_files bit_reverse.cpp

# --- testbench + golden vectors ---
add_files -tb fft_tb_axis.cpp

open_solution "sol1"
set_part {xc7a35tftg256-1}           ;# Mini-DAQ board: XC7A35T-FTG256 (speed grade -1)
create_clock -period 10 -name default ;# 10 ns = 100 MHz

# 1) functional check vs golden vectors (Hour 2: streaming csim)
csim_design -argv {C:/hls_minidaq/fft_test_vectors.txt}

# 2) C synthesis -> RTL (Hour 3: re-enable)
csynth_design

# 3) co-simulation vs generated RTL (Hour 3: re-enable)
cosim_design -argv {C:/hls_minidaq/fft_test_vectors.txt}

# 4) package the RTL as a Vivado IP-catalog bundle (Day 8, final step)
#    Output: mini_daq_fft_hls/sol1/impl/ip/*.zip  (drop into Vivado IP catalog)
export_design -format ip_catalog -rtl verilog \
    -display_name "Mini-DAQ 16-pt FFT (AXIS)" \
    -vendor wadhwani -library daq -version 1.0

exit
