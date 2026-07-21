# ==================================================================
# run_cosim.tcl  --  csynth + cosim with a SMALL random-frame count.
# RTL sim is slow, so the 2nd -argv value caps the random differential
# frames (16). The full 10k differential run stays in csim (run_csim.tcl).
#     copy sources to C:\hls_minidaq, then:  vitis_hls -f run_cosim.tcl
# ==================================================================

open_project -reset mini_daq_fft_cosim
set_top fft_axis
add_files fft_axis.cpp
add_files fft_dataflow.cpp
add_files bit_reverse.cpp
add_files -tb fft_tb_axis.cpp

open_solution -reset "sol1"
set_part {xc7a35tftg256-1}
create_clock -period 10 -name default

csynth_design
# 2nd argv = random frame count for cosim (small!)
cosim_design -argv {C:/hls_minidaq/fft_test_vectors.txt 16}
exit
