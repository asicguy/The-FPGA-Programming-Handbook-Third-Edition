# ---------------------------------------------------------------------------
# The MIPI camera hierarchy
# ---------------------------------------------------------------------------
# Reproduced from AMD's AUP-ZU3 PYNQ base overlay,
# base/run_create_mipi.tcl -- Copyright (C) 2025 Advanced Micro Devices, Inc.,
# SPDX-License-Identifier: BSD-3-Clause. The pipeline, the IP configuration and
# every instance name are theirs; what CH12 adds is this comment block, and in
# project 3 an accelerator hung off the same interconnect.
#
#   OV5647 --MIPI CSI-2, 2 lanes, RAW10--> mipi_csi2_rx_subsyst
#     -> axis_subset_converter (RAW10 -> RAW8)
#     -> demosaic (Bayer -> RGB)
#     -> gamma_lut
#     -> v_proc_sys (colour-space conversion)
#     -> axis_channel_swap (to B,G,R)
#     -> pixel_pack (two 24-bit pixels -> 64-bit words)
#     -> axi_vdma S2MM -> DDR
#
# The sensor fitted to this board is an OV5647 -- a Raspberry Pi Camera Module
# v1 -- not the Pcam 5C the pipeline was originally built around. That is a
# smaller change than it sounds: both sensors send RAW10 Bayer over two MIPI
# lanes, so every block below stays as it is. What moved is the line rate, and
# the sensor driver, which is now CH12's own Python (sw/ov5647.py) instead of
# PYNQ's `Pcam5C` and its `libpcam5c.so`.
#
# EVERY INSTANCE NAME INSIDE THIS HIERARCHY IS STILL SPELLED THE WAY AMD SPELLS
# IT, and that is not tidiness. A hierarchy driver binds by looking for
# `gpio_ip_reset`, `mipi_csi2_rx_subsyst`, `demosaic`, `gamma_lut`,
# `v_proc_sys` and `pixel_pack` by name -- CH12's `Ov5647Camera` checks for
# exactly the same set as PYNQ's `Pcam5C` does, so either driver can bind to
# this hierarchy and a board with a Pcam 5C fitted still works. Rename one IP
# and the camera does not come up, and the failure is `ol.mipi` simply not
# existing rather than an error that points at the cause.
#
# The hierarchy itself must be called `mipi` for the same reason.
#
# One number worth knowing: the axis_channel_swap TDATA_REMAP is what puts blue
# in the low byte. That is why CH12's filter treats a pixel as B,G,R,A rather
# than R,G,B,A the way CH11 did -- see HLS/src/video_filter.hpp.

proc ch12_create_mipi_hier {parentCell nameHier} {

    if {$parentCell eq "" || $nameHier eq ""} {
        error "ch12_create_mipi_hier: empty argument"
    }
    set parentObj [get_bd_cells $parentCell]
    if {$parentObj eq ""} {
        error "ch12_create_mipi_hier: no cell '$parentCell'"
    }
    set parentType [get_property TYPE $parentObj]
    if {$parentType ne "hier"} {
        error "ch12_create_mipi_hier: parent <$parentObj> has TYPE = <$parentType>, expected <hier>"
    }

    set oldCurInst [current_bd_instance .]
    current_bd_instance $parentObj
    set hier_obj [create_bd_cell -type hier $nameHier]
    current_bd_instance $hier_obj

    # --- interface pins ----------------------------------------------------
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0    M00_AXI
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0    S_AXI_LITE
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0     cam_gpio
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0    csirxss_s_axi
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 mipi_phy_if_0
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0    S00_AXI
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0      IIC_0_0
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0    S_AXI

    # --- pins ---------------------------------------------------------------
    create_bd_pin -dir O -type intr csirxss_csi_irq
    create_bd_pin -dir I -type clk  lite_aclk
    create_bd_pin -dir I -type rst  lite_aresetn
    create_bd_pin -dir O -type intr s2mm_introut
    create_bd_pin -dir I -type clk  video_aclk
    create_bd_pin -dir O -type rst  peripheral_aresetn
    create_bd_pin -dir I -type rst  aux_reset_in
    create_bd_pin -dir O -type intr iic2intc_irpt

    # --- the datapath -------------------------------------------------------
    set axi_interconnect [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect]
    set_property CONFIG.NUM_MI {1} $axi_interconnect

    # S2MM only: this VDMA writes camera frames into DDR and never reads.
    set axi_vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma]
    set_property -dict [list \
        CONFIG.c_include_mm2s {0} \
        CONFIG.c_include_s2mm_dre {0} \
        CONFIG.c_m_axi_s2mm_data_width {128} \
        CONFIG.c_num_fstores {4} \
        CONFIG.c_s2mm_genlock_mode {2} \
        CONFIG.c_s2mm_linebuffer_depth {4096} \
        CONFIG.c_s2mm_max_burst_length {256} \
    ] $axi_vdma

    # RAW10 -> RAW8: drop the two low bits of each 10-bit sample.
    set axis_subset_converter [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 axis_subset_converter]
    set_property -dict [list \
        CONFIG.M_HAS_TLAST {1} \
        CONFIG.M_TDATA_NUM_BYTES {2} \
        CONFIG.M_TDEST_WIDTH {10} \
        CONFIG.M_TUSER_WIDTH {1} \
        CONFIG.S_HAS_TLAST {1} \
        CONFIG.S_TDATA_NUM_BYTES {3} \
        CONFIG.S_TDEST_WIDTH {10} \
        CONFIG.S_TUSER_WIDTH {1} \
        CONFIG.TDATA_REMAP {tdata[19:12],tdata[9:2]} \
        CONFIG.TDEST_REMAP {tdest[9:0]} \
        CONFIG.TLAST_REMAP {tlast[0]} \
        CONFIG.TUSER_REMAP {tuser[0:0]} \
    ] $axis_subset_converter

    set demosaic [create_bd_cell -type ip -vlnv xilinx.com:ip:v_demosaic:1.1 demosaic]
    set_property -dict [list \
        CONFIG.MAX_COLS {3840} \
        CONFIG.MAX_ROWS {2160} \
        CONFIG.SAMPLES_PER_CLOCK {2} \
    ] $demosaic

    set gamma_lut [create_bd_cell -type ip -vlnv xilinx.com:ip:v_gamma_lut:1.1 gamma_lut]
    set_property -dict [list \
        CONFIG.MAX_COLS {3840} \
        CONFIG.MAX_ROWS {2160} \
        CONFIG.SAMPLES_PER_CLOCK {2} \
    ] $gamma_lut

    # Two GPIO channels: channel 1 resets the video IP, channel 2 is the
    # camera's own reset line, which defaults to 1 (released).
    set gpio_ip_reset [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio_ip_reset]
    set_property -dict [list \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_ALL_OUTPUTS_2 {1} \
        CONFIG.C_DOUT_DEFAULT_2 {0x00000001} \
        CONFIG.C_GPIO2_WIDTH {1} \
        CONFIG.C_GPIO_WIDTH {1} \
        CONFIG.C_IS_DUAL {1} \
    ] $gpio_ip_reset

    # 2 lanes at 437.5 Mbps, RAW10, two pixels per clock. The IO positions are
    # board facts; the line rate is a sensor fact.
    #
    # 437.5 Mbps is what the OV5647's PLL produces as programmed in
    # sw/ov5647_regs.py: a 218.75 MHz link frequency, doubled because MIPI
    # signals on both clock edges. The Pcam 5C ran at 672. The IP takes an
    # integer, so 438.
    #
    # HS_SETTLE is where a wrong line rate actually bites. The D-PHY spec
    # allows 85 ns + 6 UI to 145 ns + 10 UI, and one UI is 1/437.5 Mbps =
    # 2.29 ns, so the legal window here is 98.7 ns to 167.8 ns and 133 is the
    # middle of it. Note that the old 149 ns is *also* inside that window,
    # which is why an OV5647 will capture through a bitstream built for the
    # Pcam 5C -- a useful thing to know when bisecting a camera that has
    # stopped working, and not a reason to leave the number wrong.
    set mipi_csi2_rx_subsyst [create_bd_cell -type ip -vlnv xilinx.com:ip:mipi_csi2_rx_subsystem:6.0 mipi_csi2_rx_subsyst]
    set_property -dict [list \
        CONFIG.CLK_LANE_IO_LOC {AD5} \
        CONFIG.CMN_NUM_LANES {2} \
        CONFIG.CMN_NUM_PIXELS {2} \
        CONFIG.CMN_PXL_FORMAT {RAW10} \
        CONFIG.CSI_BUF_DEPTH {4096} \
        CONFIG.C_CLK_LANE_IO_POSITION {26} \
        CONFIG.C_CSI_FILTER_USERDATATYPE {true} \
        CONFIG.C_DATA_LANE0_IO_POSITION {41} \
        CONFIG.C_DATA_LANE1_IO_POSITION {39} \
        CONFIG.C_DPHY_LANES {2} \
        CONFIG.C_EN_BG0_PIN0 {false} \
        CONFIG.C_EN_BG1_PIN0 {false} \
        CONFIG.C_HS_LINE_RATE {438} \
        CONFIG.C_HS_SETTLE_NS {133} \
        CONFIG.DATA_LANE0_IO_LOC {AG3} \
        CONFIG.DATA_LANE1_IO_LOC {AG4} \
        CONFIG.DPY_EN_REG_IF {true} \
        CONFIG.DPY_LINE_RATE {438} \
        CONFIG.HP_IO_BANK_SELECTION {64} \
        CONFIG.SupportLevel {1} \
    ] $mipi_csi2_rx_subsyst

    # Topology 3 is colour-space conversion only.
    set v_proc_sys [create_bd_cell -type ip -vlnv xilinx.com:ip:v_proc_ss:2.3 v_proc_sys]
    set_property -dict [list \
        CONFIG.C_COLORSPACE_SUPPORT {2} \
        CONFIG.C_CSC_ENABLE_WINDOW {false} \
        CONFIG.C_MAX_COLS {3840} \
        CONFIG.C_MAX_DATA_WIDTH {8} \
        CONFIG.C_MAX_ROWS {2160} \
        CONFIG.C_TOPOLOGY {3} \
    ] $v_proc_sys

    # This is the block that decides the byte order every later stage sees.
    set axis_channel_swap [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 axis_channel_swap]
    set_property -dict [list \
        CONFIG.M_HAS_TKEEP {1} \
        CONFIG.M_HAS_TLAST {1} \
        CONFIG.M_HAS_TREADY {1} \
        CONFIG.M_HAS_TSTRB {1} \
        CONFIG.M_TDATA_NUM_BYTES {6} \
        CONFIG.M_TUSER_WIDTH {1} \
        CONFIG.S_HAS_TKEEP {1} \
        CONFIG.S_HAS_TLAST {1} \
        CONFIG.S_HAS_TREADY {1} \
        CONFIG.S_HAS_TSTRB {1} \
        CONFIG.S_TDATA_NUM_BYTES {6} \
        CONFIG.S_TUSER_WIDTH {1} \
        CONFIG.TDATA_REMAP {tdata[39:24], tdata[47:40], tdata[15:0], tdata[23:16]} \
        CONFIG.TLAST_REMAP {tlast[0]} \
        CONFIG.TUSER_REMAP {tuser[0:0]} \
    ] $axis_channel_swap

    # PYNQ's own HLS IP -- no source in this repo, taken prebuilt from the
    # AUP-ZU3 checkout. PixelPacker binds to it by VLNV and drives its 32bpp
    # mode, which is what makes camera frames 4 bytes per pixel.
    create_bd_cell -type ip -vlnv xilinx.com:hls:pixel_pack_2:1.0 pixel_pack

    set proc_sys_reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset]
    set_property CONFIG.C_AUX_RESET_HIGH {0} $proc_sys_reset

    set axi_interconnect_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0]
    set_property CONFIG.NUM_MI {5} $axi_interconnect_0

    # 100 MHz in, 200 MHz out, for the D-PHY. This is why PL0 must be 100 MHz.
    set clk_wiz_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
    set_property -dict [list \
        CONFIG.CLKOUT1_JITTER {102.086} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200} \
        CONFIG.MMCM_CLKOUT0_DIVIDE_F {6.000} \
        CONFIG.USE_RESET {false} \
    ] $clk_wiz_0

    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_1
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_0

    # --- interface connections ---------------------------------------------
    connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins S_AXI_LITE] [get_bd_intf_pins axi_vdma/S_AXI_LITE]
    connect_bd_intf_net -intf_net Conn2 [get_bd_intf_pins axi_interconnect_0/S00_AXI] [get_bd_intf_pins S00_AXI]
    connect_bd_intf_net -intf_net Conn3 [get_bd_intf_pins axi_iic_0/IIC] [get_bd_intf_pins IIC_0_0]
    connect_bd_intf_net -intf_net Conn4 [get_bd_intf_pins axi_iic_0/S_AXI] [get_bd_intf_pins S_AXI]
    connect_bd_intf_net -intf_net axi_interconnect_0_M00_AXI [get_bd_intf_pins gamma_lut/s_axi_CTRL] [get_bd_intf_pins axi_interconnect_0/M00_AXI]
    connect_bd_intf_net -intf_net axi_interconnect_0_M01_AXI [get_bd_intf_pins v_proc_sys/s_axi_ctrl] [get_bd_intf_pins axi_interconnect_0/M01_AXI]
    connect_bd_intf_net -intf_net axi_interconnect_0_M02_AXI [get_bd_intf_pins gpio_ip_reset/S_AXI] [get_bd_intf_pins axi_interconnect_0/M02_AXI]
    connect_bd_intf_net -intf_net axi_interconnect_0_M03_AXI [get_bd_intf_pins pixel_pack/s_axi_control] [get_bd_intf_pins axi_interconnect_0/M03_AXI]
    connect_bd_intf_net -intf_net axi_interconnect_0_M04_AXI [get_bd_intf_pins demosaic/s_axi_CTRL] [get_bd_intf_pins axi_interconnect_0/M04_AXI]
    connect_bd_intf_net -intf_net axi_interconnect_M00_AXI [get_bd_intf_pins M00_AXI] [get_bd_intf_pins axi_interconnect/M00_AXI]
    connect_bd_intf_net -intf_net axi_interconnect_M26_AXI [get_bd_intf_pins csirxss_s_axi] [get_bd_intf_pins mipi_csi2_rx_subsyst/csirxss_s_axi]
    connect_bd_intf_net -intf_net axi_vdma_0_M_AXI_S2MM [get_bd_intf_pins axi_interconnect/S00_AXI] [get_bd_intf_pins axi_vdma/M_AXI_S2MM]
    connect_bd_intf_net -intf_net axis_channel_swap_m_axis [get_bd_intf_pins axis_channel_swap/M_AXIS] [get_bd_intf_pins pixel_pack/stream_in_48]
    connect_bd_intf_net -intf_net axis_subset_converter_0_M_AXIS [get_bd_intf_pins axis_subset_converter/M_AXIS] [get_bd_intf_pins demosaic/s_axis_video]
    connect_bd_intf_net -intf_net dm0_m_axis_video [get_bd_intf_pins demosaic/m_axis_video] [get_bd_intf_pins gamma_lut/s_axis_video]
    connect_bd_intf_net -intf_net gammalut_m_axis [get_bd_intf_pins gamma_lut/m_axis_video] [get_bd_intf_pins v_proc_sys/s_axis]
    connect_bd_intf_net -intf_net gpio_ip_reset_GPIO2 [get_bd_intf_pins cam_gpio] [get_bd_intf_pins gpio_ip_reset/GPIO2]
    connect_bd_intf_net -intf_net mipi_csi2_rx_subsyst_0_video_out [get_bd_intf_pins axis_subset_converter/S_AXIS] [get_bd_intf_pins mipi_csi2_rx_subsyst/video_out]
    connect_bd_intf_net -intf_net mipi_phy_if_0_1 [get_bd_intf_pins mipi_phy_if_0] [get_bd_intf_pins mipi_csi2_rx_subsyst/mipi_phy_if]
    connect_bd_intf_net -intf_net pixel_pack_m_axis [get_bd_intf_pins pixel_pack/stream_out_64] [get_bd_intf_pins axi_vdma/S_AXIS_S2MM]
    connect_bd_intf_net -intf_net v_proc_sys_0_m_axis [get_bd_intf_pins v_proc_sys/m_axis] [get_bd_intf_pins axis_channel_swap/S_AXIS]

    # --- port connections ---------------------------------------------------
    connect_bd_net -net aux_reset_in_1 [get_bd_pins aux_reset_in] [get_bd_pins proc_sys_reset_1/aux_reset_in] [get_bd_pins proc_sys_reset_1/dcm_locked] [get_bd_pins proc_sys_reset_1/ext_reset_in]
    connect_bd_net -net axi_gpio_ip_reset_gpio_io_o [get_bd_pins gpio_ip_reset/gpio_io_o] [get_bd_pins proc_sys_reset/aux_reset_in]
    connect_bd_net -net axi_iic_0_iic2intc_irpt [get_bd_pins axi_iic_0/iic2intc_irpt] [get_bd_pins iic2intc_irpt]
    connect_bd_net -net axi_vdma_mipi_s2mm_introut [get_bd_pins axi_vdma/s2mm_introut] [get_bd_pins s2mm_introut]
    connect_bd_net -net clk_wiz_0_clk_out1 [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins mipi_csi2_rx_subsyst/dphy_clk_200M]
    connect_bd_net -net mipi_csi2_rx_subsyst_0_csirxss_csi_irq [get_bd_pins mipi_csi2_rx_subsyst/csirxss_csi_irq] [get_bd_pins csirxss_csi_irq]
    connect_bd_net -net net_zynq_us_ss_0_clk_out2 [get_bd_pins video_aclk] [get_bd_pins axi_interconnect/ACLK] [get_bd_pins axi_interconnect/M00_ACLK] [get_bd_pins axi_interconnect/S00_ACLK] [get_bd_pins axi_vdma/m_axi_s2mm_aclk] [get_bd_pins axi_vdma/s_axis_s2mm_aclk] [get_bd_pins axis_subset_converter/aclk] [get_bd_pins demosaic/ap_clk] [get_bd_pins gamma_lut/ap_clk] [get_bd_pins gpio_ip_reset/s_axi_aclk] [get_bd_pins mipi_csi2_rx_subsyst/video_aclk] [get_bd_pins v_proc_sys/aclk] [get_bd_pins axis_channel_swap/aclk] [get_bd_pins pixel_pack/ap_clk] [get_bd_pins proc_sys_reset/slowest_sync_clk] [get_bd_pins axi_interconnect_0/S00_ACLK] [get_bd_pins axi_interconnect_0/M00_ACLK] [get_bd_pins axi_interconnect_0/M01_ACLK] [get_bd_pins axi_interconnect_0/M02_ACLK] [get_bd_pins axi_interconnect_0/M03_ACLK] [get_bd_pins proc_sys_reset_1/slowest_sync_clk] [get_bd_pins axi_interconnect_0/M04_ACLK] [get_bd_pins axi_interconnect_0/ACLK]
    connect_bd_net -net net_zynq_us_ss_0_dcm_locked [get_bd_pins proc_sys_reset_1/peripheral_aresetn] [get_bd_pins axi_interconnect/ARESETN] [get_bd_pins axi_interconnect/M00_ARESETN] [get_bd_pins axi_interconnect/S00_ARESETN] [get_bd_pins axis_subset_converter/aresetn] [get_bd_pins gpio_ip_reset/s_axi_aresetn] [get_bd_pins mipi_csi2_rx_subsyst/video_aresetn] [get_bd_pins proc_sys_reset/ext_reset_in] [get_bd_pins peripheral_aresetn] [get_bd_pins axi_interconnect_0/S00_ARESETN] [get_bd_pins axi_interconnect_0/M00_ARESETN] [get_bd_pins axi_interconnect_0/M01_ARESETN] [get_bd_pins axi_interconnect_0/M02_ARESETN] [get_bd_pins axi_interconnect_0/M03_ARESETN] [get_bd_pins axi_interconnect_0/M04_ARESETN] [get_bd_pins axi_interconnect_0/ARESETN]
    connect_bd_net -net net_zynq_us_ss_0_peripheral_aresetn [get_bd_pins lite_aresetn] [get_bd_pins axi_vdma/axi_resetn] [get_bd_pins mipi_csi2_rx_subsyst/lite_aresetn] [get_bd_pins axi_iic_0/s_axi_aresetn]
    connect_bd_net -net net_zynq_us_ss_0_s_axi_aclk [get_bd_pins lite_aclk] [get_bd_pins axi_vdma/s_axi_lite_aclk] [get_bd_pins mipi_csi2_rx_subsyst/lite_aclk] [get_bd_pins clk_wiz_0/clk_in1] [get_bd_pins axi_iic_0/s_axi_aclk]
    connect_bd_net -net soft_peripheral_aresetn [get_bd_pins proc_sys_reset/peripheral_aresetn] [get_bd_pins demosaic/ap_rst_n] [get_bd_pins gamma_lut/ap_rst_n] [get_bd_pins v_proc_sys/aresetn] [get_bd_pins axis_channel_swap/aresetn] [get_bd_pins pixel_pack/ap_rst_n]

    current_bd_instance $oldCurInst
}
