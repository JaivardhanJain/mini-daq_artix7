# ==================================================================
# run_csim.tcl  --  csim ONLY (fast functional check).
# Use while iterating on the testbench (fft_tb_axis.cpp); skips
# csynth / cosim / export. Run from the space-free build folder:
#     copy sources to C:\hls_minidaq, then:  vitis_hls -f run_csim.tcl
# ==================================================================

open_project -reset mini_daq_fft_csim
set_top fft_axis
add_files fft_axis.cpp
add_files fft_dataflow.cpp
add_files bit_reverse.cpp
add_files -tb fft_tb_axis.cpp

open_solution -reset "sol1"
set_part {xc7a35tftg256-1}
create_clock -period 10 -name default

csim_design -argv {C:/hls_minidaq/fft_test_vectors.txt}
exit
