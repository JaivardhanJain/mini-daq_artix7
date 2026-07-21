# Clock (100 MHz)
set_property PACKAGE_PIN N14 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} -add [get_ports clk]

# UART RX
set_property PACKAGE_PIN P16 [get_ports rx]
set_property IOSTANDARD LVCMOS33 [get_ports rx]

# 8 LEDs -> led[0..7]
set_property PACKAGE_PIN C11 [get_ports {led[0]}]
set_property PACKAGE_PIN C12 [get_ports {led[1]}]
set_property PACKAGE_PIN C13 [get_ports {led[2]}]
set_property PACKAGE_PIN D13 [get_ports {led[3]}]
set_property PACKAGE_PIN D11 [get_ports {led[4]}]
set_property PACKAGE_PIN E11 [get_ports {led[5]}]
set_property PACKAGE_PIN E12 [get_ports {led[6]}]
set_property PACKAGE_PIN E13 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]