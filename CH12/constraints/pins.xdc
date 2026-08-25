# CH12 pin constraints -- AUP-ZU3 camera connector.
#
# Only three pins need constraining here. The MIPI D-PHY lanes are not among
# them: the clock lane (AD5) and the two data lanes (AG3, AG4) are set inside
# the MIPI CSI-2 RX Subsystem configuration in build_bd.tcl, because the IP
# places its own D-PHY primitives from those properties and an XDC assignment
# would collide with them.
#
# Values taken from AMD's AUP-ZU3 base overlay constraints
# (AUP-ZU3/base/constraints/base.xdc, BSD-3-Clause).

# Camera control bus (I2C). The pull-ups are on the FPGA rather than the board.
set_property PACKAGE_PIN K14      [get_ports IIC_0_0_scl_io]
set_property PACKAGE_PIN L14      [get_ports IIC_0_0_sda_io]
set_property IOSTANDARD LVCMOS18  [get_ports IIC_0_0_scl_io]
set_property IOSTANDARD LVCMOS18  [get_ports IIC_0_0_sda_io]
set_property PULLUP true          [get_ports IIC_0_0_scl_io]
set_property PULLUP true          [get_ports IIC_0_0_sda_io]

# Camera enable, driven from the second channel of gpio_ip_reset. It powers up
# asserted (C_DOUT_DEFAULT_2), so the camera is alive before anything talks to
# it over I2C.
set_property PACKAGE_PIN J14      [get_ports {rpi_enb[0]}]
set_property IOSTANDARD LVCMOS18  [get_ports {rpi_enb[0]}]
