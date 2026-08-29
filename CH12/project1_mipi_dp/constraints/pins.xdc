# CH12 project 1 -- camera pin constraints
#
# From AMD's AUP-ZU3 base overlay, base/constraints/base.xdc
# (Copyright (C) 2025 Advanced Micro Devices, Inc., BSD-3-Clause).
#
# Only the I2C bus appears here. The MIPI D-PHY lanes are NOT constrained in
# this file and that is not an omission: their package pins are set inside the
# CSI-2 subsystem's own configuration (CLK_LANE_IO_LOC, DATA_LANE0_IO_LOC,
# DATA_LANE1_IO_LOC and the matching IO_POSITION properties in
# common/mipi_hier.tcl), because the subsystem generates its own IO primitives
# and will not accept placement from outside.
#
# LVCMOS18 with pull-ups: the Pcam's I2C lines are open-drain and the board
# does not fit external pull-ups.

set_property PACKAGE_PIN L14 [get_ports IIC_0_0_sda_io]
set_property PACKAGE_PIN K14 [get_ports IIC_0_0_scl_io]
set_property IOSTANDARD LVCMOS18 [get_ports IIC_0_0_scl_io]
set_property IOSTANDARD LVCMOS18 [get_ports IIC_0_0_sda_io]
set_property PULLUP true [get_ports IIC_0_0_scl_io]
set_property PULLUP true [get_ports IIC_0_0_sda_io]

# The camera's enable/reset line, driven by gpio_ip_reset channel 2. Its GPIO
# reset default is 1, so the camera comes out of reset without software help.
set_property PACKAGE_PIN J14 [get_ports {rpi_enb[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {rpi_enb[0]}]
