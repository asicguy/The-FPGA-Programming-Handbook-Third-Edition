# Vivado block design for CH12 project 1: MIPI camera to DisplayPort.
#
#   vivado -mode batch -source build_bd.tcl        -> out/camera_dp.bit + .hwh
#
# No accelerator. The camera writes frames into DDR and the PS puts them on the
# DisplayPort, and that is the whole design. It exists on its own because
# camera bring-up has a great many ways to go wrong that have nothing to do
# with a filter -- a renamed IP, a misrouted interrupt, an I2C bus at the wrong
# address -- and every one of them is easier to find in a design that contains
# nothing else.
#
#   OV5647 -> [ mipi hierarchy ] -> VDMA S2MM -> DDR -> DPDMA -> DisplayPort
#
# The DisplayPort end of that is hardened silicon in the PS: the DPDMA scans
# out of DDR on its own and no PL logic is involved. The Mali GPU is not
# involved either -- it is a renderer that would be one possible producer of
# those pixels, and here the producer is the camera.
#
# Produces out/camera_dp.bit and .hwh.

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir .. common config.tcl]
source [file join $script_dir .. common ps_config.tcl]
source [file join $script_dir .. common mipi_hier.tcl]

set proj_name camera_dp
set proj_dir  $script_dir/vivado
set bd_name   design_1
set out_dir   $script_dir/out

ch12_require_dir $ch12_board_repo "AUP-ZU3 board files"
ch12_require_dir [lindex $ch12_pynq_ip 0] "PYNQ's prebuilt pixel_pack_2 IP"

create_project $proj_name $proj_dir -part $ch12_part -force
set_property ip_repo_paths $ch12_pynq_ip [current_project]
update_ip_catalog -rebuild

set_property board_part_repo_paths [list $ch12_board_repo] [current_project]
set_property board_part $ch12_board_part [current_project]

create_bd_design $bd_name

# PL0 100 MHz for AXI4-Lite (and for the CSI-2 subsystem's clk_wiz, which
# multiplies it to the 200 MHz the D-PHY needs); PL1 300 MHz for the video
# datapath; IRQ1 for the camera's I2C controller.
# HP0 only -- the camera VDMA is the only thing writing to DDR from the PL.
ch12_add_ps 100 $ch12_video_mhz 0 1 {0}

# HPM0_FPD carries the video IP control traffic at 300 MHz, HP0 takes the
# VDMA's writes. Both are AMD's arrangement, kept because the alternative is
# retiming a pipeline that already closes.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
] [get_bd_cells zynq_ultra_ps_e_0]

# 128, and not the 32 the slaves behind it actually want. This is the single
# most expensive line in the chapter to get wrong, so it is worth the paragraph.
#
# The PS-PL master port width is not part of the bitstream. It lives in
# FPD_SLCR.AFI_FS, which psu_init writes ONCE, at boot, from whatever design
# the board booted with -- for a PYNQ image that is the base overlay, and the
# base overlay uses 128. Loading a bitstream reprograms the fabric and the PL
# clocks and nothing else, so a design built with 32 here comes up driving a
# 32-bit interface into a PS port still configured for 128.
#
# The failure is silent and total. Every access to this port's aperture --
# 0xA0000000, which is demosaic, gamma_lut, gpio_ip_reset, pixel_pack and
# v_proc_sys -- never completes. There is no bus timeout on ZynqMP, so the
# master that issued it wedges forever: the CPU hangs with no panic and no
# console output, and a JTAG probe of the same address wedges the debug port
# too. Meanwhile HPM0_LPD at 0x80000000 is 32 bits in both designs, so the
# interconnect, the IIC and the VDMA all answer perfectly and the design looks
# healthy right up until something touches the camera's video IP.
#
# The AXI interconnect inside the mipi hierarchy converts 128 down to the
# 32-bit AXI4-Lite the slaves want, at no cost worth measuring on a control
# path. ch12_check_ps_ports below fails the build if this ever drifts again.

ch12_create_mipi_hier / mipi

# --- external ports ---------------------------------------------------------
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 CAM
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 IIC_0_0
create_bd_port -dir O -from 0 -to 0 rpi_enb

connect_bd_intf_net [get_bd_intf_ports CAM]     [get_bd_intf_pins mipi/mipi_phy_if_0]
connect_bd_intf_net [get_bd_intf_ports IIC_0_0] [get_bd_intf_pins mipi/IIC_0_0]
connect_bd_net      [get_bd_ports rpi_enb]      [get_bd_pins mipi/cam_gpio_tri_o]

# --- clocks and resets ------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_lite

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins mipi/lite_aclk] \
    [get_bd_pins rst_lite/slowest_sync_clk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] \
    [get_bd_pins mipi/video_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins mipi/aux_reset_in] \
    [get_bd_pins rst_lite/ext_reset_in]

connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins mipi/lite_aresetn]

# --- interrupts -------------------------------------------------------------
# The camera's I2C controller goes to pl_ps_irq1[0] and nowhere else: that is
# SPI 136, which dts/camera_dp.dtsi declares as <0 104 4> because the GIC
# binding counts SPIs from 32. Put it on irq0 and Linux's xiic driver waits
# forever for an interrupt that arrives somewhere else.
connect_bd_net [get_bd_pins mipi/iic2intc_irpt] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property CONFIG.NUM_PORTS {2} [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins mipi/csirxss_csi_irq] [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins mipi/s2mm_introut]    [get_bd_pins xlconcat_0/In1]

# --- interrupt controller ------------------------------------------------
# PYNQ needs this even though nothing here uses interrupts.
#
# Wiring xlconcat straight to pl_ps_irq0 is electrically fine and it is what
# an RTL engineer would do. It is also enough to stop `ol.mipi` existing.
# PYNQ attributes an interrupt to an IP by tracing it to an AXI Interrupt
# Controller and reading which of its inputs the signal lands on; with a bare
# concat there is nothing to trace to, so `axi_vdma` gets no `interrupts`
# entry, and `AxiVDMA.__init__` does an unconditional `self.s2mm_introut`
# and dies with
#     AttributeError: 'AxiVDMA' object has no attribute 's2mm_introut'
#
# The accelerator and the camera are both polled in this chapter, so the
# controller is pure metadata -- but it is metadata the driver refuses to
# start without. AMD's base overlay has one for the same reason.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0
set_property -dict [list \
    CONFIG.C_IRQ_CONNECTION {1} \
    CONFIG.C_HAS_FAST {0} \
    CONFIG.C_KIND_OF_INTR {0xFFFFFFFC} \
] [get_bd_cells axi_intc_0]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins axi_intc_0/intr]
connect_bd_net [get_bd_pins axi_intc_0/irq]  [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# --- AXI ---------------------------------------------------------------------
# Three AXI4-Lite slaves on the 100 MHz control path.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 lite_periph
set_property -dict [list CONFIG.NUM_MI {4} CONFIG.NUM_SI {1}] [get_bd_cells lite_periph]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins lite_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M00_AXI] [get_bd_intf_pins mipi/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M01_AXI] [get_bd_intf_pins mipi/csirxss_s_axi]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M02_AXI] [get_bd_intf_pins mipi/S_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M03_AXI] [get_bd_intf_pins axi_intc_0/s_axi]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_intc_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins axi_intc_0/s_axi_aresetn]
foreach p {ACLK S00_ACLK M00_ACLK M01_ACLK M02_ACLK M03_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins lite_periph/$p]
}
foreach p {ARESETN S00_ARESETN M00_ARESETN M01_ARESETN M02_ARESETN M03_ARESETN} {
    connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins lite_periph/$p]
}

# The video IP's own control interconnect lives inside the hierarchy and runs
# on video_aclk, so it is fed from HPM0_FPD rather than from the 100 MHz path.
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins mipi/S00_AXI]

# The VDMA's writes to DDR.
connect_bd_intf_net [get_bd_intf_pins mipi/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# --- addresses ---------------------------------------------------------------
# These are AMD's addresses, and at least one of them is load bearing:
# dts/camera_dp.dtsi declares the I2C controller at 0x80140000, and the camera
# driver finds its bus by walking /dev/i2c-* looking for the label that node
# carries. Move the IIC and the camera does not enumerate.
assign_bd_address
set_property offset 0x80000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_intc_0_Reg}]
set_property offset 0x80140000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_iic_0_Reg}]
set_property offset 0x80150000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_vdma_Reg}]
set_property offset 0x80160000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_mipi_csi2_rx_subsyst_Reg}]
set_property offset 0xA0000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_demosaic_Reg}]
set_property offset 0xA0010000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_gamma_lut_Reg}]
set_property offset 0xA0020000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_gpio_ip_reset_Reg}]
set_property offset 0xA0030000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_pixel_pack_Reg}]
set_property offset 0xA0040000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_v_proc_sys_Reg}]

add_files -fileset constrs_1 -norecurse $script_dir/constraints/pins.xdc

ch12_finish $proj_dir $proj_name $bd_name $out_dir camera_dp 12
exit
