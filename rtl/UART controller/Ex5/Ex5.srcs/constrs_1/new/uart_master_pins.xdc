# Clock (100 MHz)
set_property PACKAGE_PIN N14 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} -add [get_ports clk]

# 8 slide switches -> sw[0..7]
set_property PACKAGE_PIN F4 [get_ports {sw[0]}]
set_property PACKAGE_PIN G4 [get_ports {sw[1]}]
set_property PACKAGE_PIN H4 [get_ports {sw[2]}]
set_property PACKAGE_PIN J4 [get_ports {sw[3]}]
set_property PACKAGE_PIN J3 [get_ports {sw[4]}]
set_property PACKAGE_PIN H3 [get_ports {sw[5]}]
set_property PACKAGE_PIN L3 [get_ports {sw[6]}]
set_property PACKAGE_PIN K3 [get_ports {sw[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw[*]}]

# UART TX
set_property PACKAGE_PIN P15 [get_ports tx]
set_property IOSTANDARD LVCMOS33 [get_ports tx]