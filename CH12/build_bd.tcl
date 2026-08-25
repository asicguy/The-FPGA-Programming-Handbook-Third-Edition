# Vivado block design for the CH12 streaming Sobel video pipeline.
#
#   vivado -mode batch -source build_bd.tcl -tclargs hls    -> out_hls/
#   vivado -mode batch -source build_bd.tcl -tclargs sv     -> out_sv/
#   vivado -mode batch -source build_bd.tcl -tclargs vhdl   -> out_vhdl/
#
# One script for all three implementations: the block design is identical apart
# from which sobel_stream IP is instantiated, and duplicating four hundred lines
# of IP Integrator Tcl to change one VLNV would be a good way to let the three
# designs drift apart.
#
# The camera front end is AMD's, from the AUP-ZU3 PYNQ base overlay
# (AUP-ZU3/base/run_create_mipi.tcl, Copyright (C) 2025 Advanced Micro Devices,
# Inc., SPDX-License-Identifier: BSD-3-Clause). It is reproduced here with the
# filter spliced into the video path and the parts CH12 does not need -- audio,
# PMOD, Grove, the MicroBlaze subsystems, the LEDs -- left out. Every IP name
# inside the `mipi` hierarchy is kept exactly as AMD spells it, because PYNQ's
# Pcam5C driver identifies the hierarchy by looking for gpio_ip_reset,
# mipi_csi2_rx_subsyst, demosaic, gamma_lut, v_proc_sys, pixel_pack and
# axi_vdma by name, and libpcam5c.so on the board configures four of them
# through their base addresses.
#
# Produces  out_<variant>/sobel_stream.bit  and  .hwh, the two files PYNQ needs.

# ---------------------------------------------------------------------------
# EDIT THESE FOR YOUR SETUP
# ---------------------------------------------------------------------------
set part_name  {xczu3eg-sfvc784-2-e}

# The board preset configures the PS DDR controller. Without it the PS is left
# at defaults, which will not match the board's memory. The AUP-ZU3 comes in
# 4GB and 8GB variants; pick the one matching your board.
#   realdigital.org:aup-zu3-8gb:part0:1.0
#   realdigital.org:aup-zu3-4gb:part0:1.0
set board_part {realdigital.org:aup-zu3-8gb:part0:1.0}

set script_dir [file dirname [file normalize [info script]]]

# Board files are not installed into Vivado, so point at the repo checkout.
set board_repo [file normalize [file join $script_dir .. .. aup-zu3-board-files]]

# pixel_pack_2 and pixel_unpack_2 are PYNQ's own HLS IP: the blocks that convert
# between the 48-bit two-pixel video stream and the packed 24/32-bit words the
# VDMA moves to and from DDR. PYNQ's PixelPacker driver binds to both by VLNV.
# They ship prebuilt in the AUP-ZU3 repo; if you have moved that checkout,
# change this path.
set pynq_hls_ip [file normalize [file join $script_dir .. .. AUP-ZU3 pynq boards ip hls]]
set pynq_ip_repo [list \
    [file join $pynq_hls_ip pixel_pack_2   pixel_pack_2_zu3_solution   impl ip] \
    [file join $pynq_hls_ip pixel_unpack_2 pixel_unpack_2_zu3_solution impl ip]]

# ---------------------------------------------------------------------------
set variant "hls"
if {[llength $argv] > 0} { set variant [lindex $argv 0] }
if {[lsearch -exact {hls sv vhdl} $variant] < 0} {
    error "unknown variant '$variant' -- expected hls, sv or vhdl"
}

set proj_name sobel_video_$variant
set proj_dir  $script_dir/vivado_$variant
set bd_name   design_1
set out_dir   $script_dir/out_$variant
set ip_repo   $script_dir/ip_repo_$variant

# 300 MHz: video_aclk, the clock the whole MIPI datapath runs at in AMD's
# reference pipeline. 100 MHz: the AXI4-Lite control domain.
set video_mhz 300
set lite_mhz  100

file mkdir $out_dir

if {![file isdirectory $board_repo]} {
    error "Board files not found at $board_repo -- clone aup-zu3-board-files there"
}
foreach d $pynq_ip_repo {
    if {![file isdirectory $d]} {
        error "PYNQ HLS IP not found at $d -- clone the AUP-ZU3 repo there, or\
               build it from pynq/boards/ip/hls with build_ip.tcl"
    }
}

# ===========================================================================
# Phase 1: get the filter into the IP catalog
# ===========================================================================
set ip_repo_list $pynq_ip_repo

if {$variant eq "hls"} {
    set hls_ip [file normalize [file join $script_dir HLS sobel_stream hls impl ip]]
    if {![file isdirectory $hls_ip]} {
        error "HLS IP not found at $hls_ip -- run HLS/build_hls.sh first"
    }
    lappend ip_repo_list $hls_ip
    set filter_vlnv aup:hls:sobel_stream:1.0
} else {
    # A module reference will not take a SystemVerilog top file, so package the
    # filter properly. ipx infers the AXI interfaces from the port names, which
    # is one more reason they are spelled exactly as Vitis HLS spells them.
    file delete -force $ip_repo
    file mkdir $ip_repo
    create_project -in_memory -part $part_name pack_tmp

    if {$variant eq "sv"} {
        add_files -norecurse [glob $script_dir/SystemVerilog/hdl/*.sv]
        set_property file_type SystemVerilog [get_files *.sv]
    } else {
        add_files -norecurse [list \
            $script_dir/VHDL/hdl/axis_skid.vhd \
            $script_dir/VHDL/hdl/sobel_stream_ctrl.vhd \
            $script_dir/VHDL/hdl/sobel_stream_core.vhd \
            $script_dir/VHDL/hdl/sobel_stream.vhd]
    }
    update_compile_order -fileset sources_1
    set_property top sobel_stream [current_fileset]

    ipx::package_project -root_dir $ip_repo -vendor aup -library rtl \
        -taxonomy /UserIP -import_files -force
    set core [ipx::current_core]
    set_property name sobel_stream $core
    set_property version 1.0 $core
    set_property display_name "Streaming Sobel Video Filter (RTL $variant)" $core

    ipx::infer_bus_interfaces xilinx.com:interface:aximm_rtl:1.0 $core
    ipx::infer_bus_interfaces xilinx.com:interface:axis_rtl:1.0  $core
    ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
    ipx::associate_bus_interfaces -busif stream_in     -clock ap_clk $core
    ipx::associate_bus_interfaces -busif stream_out    -clock ap_clk $core

    # ipx infers the interfaces but NOT the register definitions, and without
    # them PYNQ cannot build sobel.register_map -- it raises "register_map only
    # available if the .hwh is provided". Declare them so the offsets and names
    # match the HLS build byte for byte.
    set mm [ipx::get_memory_maps s_axi_control -of_objects $core]
    if {$mm eq ""} {
        set mm [ipx::add_memory_map s_axi_control $core]
        set_property slave_memory_map_ref s_axi_control \
            [ipx::get_bus_interfaces s_axi_control -of_objects $core]
    }
    # Exactly ONE address block must remain. package_project auto-creates
    # "reg0"; leaving it alongside ours gives the interface two address blocks,
    # and PYNQ then keys the IP as "sobel/s_axi_control" rather than "sobel", so
    # the register map disappears.
    foreach ab [ipx::get_address_blocks -of_objects $mm] {
        ipx::remove_address_block [get_property name $ab] $mm
    }
    set blk [ipx::add_address_block Reg $mm]
    set_property base_address 0          $blk
    set_property range        65536      $blk
    set_property width        32         $blk
    set_property usage        register   $blk
    set_property access       read-write $blk

    proc add_reg {blk name offset desc} {
        set r [ipx::add_register $name $blk]
        set_property address_offset $offset $r
        set_property size 32 $r
        set_property description $desc $r
        return $r
    }
    add_reg $blk img_width  0x10 "pixels per line, must be even"
    add_reg $blk img_height 0x18 "lines per frame"
    add_reg $blk mode       0x20 "0 gray, 1 sobel, 2 invert, 3 colour passthrough"

    set_property core_revision 1 $core
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::save_core $core
    close_project

    lappend ip_repo_list $ip_repo
    set filter_vlnv aup:rtl:sobel_stream:1.0
}

# ===========================================================================
# Phase 2: the block design
# ===========================================================================
create_project $proj_name $proj_dir -part $part_name -force

# board_part_repo_paths has to be set before board_part, or the preset is not in
# the catalog yet when we ask for it.
set_property board_part_repo_paths [list $board_repo] [current_project]
set_property board_part $board_part [current_project]
set_property ip_repo_paths $ip_repo_list [current_project]
update_ip_catalog -rebuild

create_bd_design $bd_name

# ---------------------------------------------------------------------------
# The camera hierarchy.
#
#   csi2_rx --> subset --> demosaic --> gamma_lut --> v_proc_ss (CSC)
#           --> channel_swap --> [ sobel ] --> pixel_pack --> VDMA --> DDR
#
# RAW10 arrives two pixels per beat from a two-lane D-PHY. The subset converter
# drops the two low bits of each 10-bit sample to give RAW8; the demosaic turns
# the Bayer mosaic into RGB; the gamma LUT and the colour-space converter finish
# the picture; the channel swap reorders the bytes to the B,G,R the filter and
# PYNQ both expect; pixel_pack packs two 24-bit pixels into the 64-bit words the
# VDMA writes.
# ---------------------------------------------------------------------------
proc create_hier_cell_mipi { parentCell nameHier filter_vlnv } {

    set parentObj [get_bd_cells $parentCell]
    set oldCurInst [current_bd_instance .]
    current_bd_instance $parentObj

    set hier_obj [create_bd_cell -type hier $nameHier]
    current_bd_instance $hier_obj

    # Interface pins
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M00_AXI
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_LITE
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 csirxss_s_axi
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S00_AXI
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 mipi_phy_if_0
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0  IIC_0_0
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 cam_gpio

    # Pins
    create_bd_pin -dir I -type clk clk_100
    create_bd_pin -dir I -type rst rst_100n
    create_bd_pin -dir I -type clk clk_video
    create_bd_pin -dir I -type rst rst_video_n
    create_bd_pin -dir O -type intr iic2intc_irpt

    # --- MIPI CSI-2 receiver -----------------------------------------------
    # Two data lanes on AG3/AG4 with the clock lane on AD5, RAW10, two pixels
    # per clock, 672 Mbps a lane. These are the Pcam 5C's pins and line rate on
    # this board; the IO locations live in the IP configuration rather than in
    # an XDC because the D-PHY primitives are placed from them.
    set csi [create_bd_cell -type ip -vlnv xilinx.com:ip:mipi_csi2_rx_subsystem:6.0 mipi_csi2_rx_subsyst]
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
        CONFIG.C_HS_LINE_RATE {672} \
        CONFIG.C_HS_SETTLE_NS {149} \
        CONFIG.DATA_LANE0_IO_LOC {AG3} \
        CONFIG.DATA_LANE1_IO_LOC {AG4} \
        CONFIG.DPY_EN_REG_IF {true} \
        CONFIG.DPY_LINE_RATE {672} \
        CONFIG.HP_IO_BANK_SELECTION {64} \
        CONFIG.SupportLevel {1} \
    ] $csi

    # RAW10 two-pixel beats are 24 bits with each sample in [9:2] of its byte
    # pair; this keeps the top eight bits of each and hands the demosaic RAW8.
    set subset [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 axis_subset_converter]
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
    ] $subset

    set demosaic [create_bd_cell -type ip -vlnv xilinx.com:ip:v_demosaic:1.1 demosaic]
    set_property -dict [list \
        CONFIG.MAX_COLS {3840} \
        CONFIG.MAX_ROWS {2160} \
        CONFIG.SAMPLES_PER_CLOCK {2} \
    ] $demosaic

    set gamma [create_bd_cell -type ip -vlnv xilinx.com:ip:v_gamma_lut:1.1 gamma_lut]
    set_property -dict [list \
        CONFIG.MAX_COLS {3840} \
        CONFIG.MAX_ROWS {2160} \
        CONFIG.SAMPLES_PER_CLOCK {2} \
    ] $gamma

    set vproc [create_bd_cell -type ip -vlnv xilinx.com:ip:v_proc_ss:2.3 v_proc_sys]
    set_property -dict [list \
        CONFIG.C_COLORSPACE_SUPPORT {2} \
        CONFIG.C_CSC_ENABLE_WINDOW {false} \
        CONFIG.C_MAX_COLS {3840} \
        CONFIG.C_MAX_DATA_WIDTH {8} \
        CONFIG.C_MAX_ROWS {2160} \
        CONFIG.C_TOPOLOGY {3} \
    ] $vproc

    # R,G,B -> B,G,R for both pixels of the beat. Everything downstream of here
    # -- the filter, pixel_pack, PYNQ's PIXEL_BGR -- assumes this order.
    set swap [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter:1.1 axis_channel_swap]
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
    ] $swap

    # --- the chapter's filter ----------------------------------------------
    create_bd_cell -type ip -vlnv $filter_vlnv sobel

    set pack [create_bd_cell -type ip -vlnv xilinx.com:hls:pixel_pack_2:1.0 pixel_pack]

    # S2MM writes filtered frames to DDR. MM2S is CH12's addition to AMD's
    # hierarchy: it reads frames back *out* of DDR and plays them into the
    # filter, which is what lets a notebook feed the accelerator a video file
    # or a test pattern instead of the camera.
    #
    # The MM2S stream width has to be set by hand. The S2MM side is read-only
    # and picks up 64 bits from the packer connected to it, but nothing
    # propagates backwards into a master port, so without this line the MM2S
    # stream comes out 32 bits wide and Vivado reports a width mismatch against
    # pixel_unpack rather than fixing it.
    #
    # c_mm2s_sof_enable is the important one. The filter finds the start of a
    # frame from TUSER and the end of a line from TLAST; with SOF disabled the
    # MM2S stream carries neither reliably and the filter would sit in its
    # synchronisation state forever, draining every beat and emitting nothing.
    set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma]
    set_property -dict [list \
        CONFIG.c_include_s2mm_dre {0} \
        CONFIG.c_m_axi_s2mm_data_width {128} \
        CONFIG.c_num_fstores {4} \
        CONFIG.c_s2mm_genlock_mode {2} \
        CONFIG.c_s2mm_linebuffer_depth {4096} \
        CONFIG.c_s2mm_max_burst_length {256} \
        CONFIG.c_include_mm2s {1} \
        CONFIG.c_include_mm2s_dre {0} \
        CONFIG.c_m_axi_mm2s_data_width {128} \
        CONFIG.c_m_axis_mm2s_tdata_width {64} \
        CONFIG.c_mm2s_genlock_mode {0} \
        CONFIG.c_mm2s_linebuffer_depth {4096} \
        CONFIG.c_mm2s_max_burst_length {256} \
        CONFIG.c_mm2s_sof_enable {1} \
    ] $vdma

    # The mirror of pixel_pack: 64-bit words out of DDR back into 48-bit
    # two-pixel video beats, carrying TUSER and TLAST through. PYNQ's
    # PixelPacker driver binds to it as well as to the packer, so a notebook
    # sets pixel_unpack.bits_per_pixel exactly as it sets pixel_pack's.
    create_bd_cell -type ip -vlnv xilinx.com:hls:pixel_unpack_2:1.0 pixel_unpack

    # Which of the two sources the filter sees. S00 is the camera, S01 is
    # whatever the PS has put in DDR.
    #
    # A two-into-one switch has no AXI4-Lite control interface -- the register
    # map only appears when there is more than one master to route to -- so the
    # selection is made through s_req_suppress instead, one bit per slave port.
    # Suppressing a port stops the arbiter ever granting it, which leaves
    # exactly one source connected and the other backpressured. That is the
    # behaviour wanted anyway: the unselected source stalls rather than
    # interleaving its lines into the selected one.
    set swtch [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_switch:1.1 axis_switch]
    set_property -dict [list \
        CONFIG.NUM_SI {2} \
        CONFIG.NUM_MI {1} \
        CONFIG.ROUTING_MODE {0} \
        CONFIG.TDATA_NUM_BYTES {6} \
        CONFIG.TUSER_WIDTH {1} \
        CONFIG.HAS_TLAST {1} \
        CONFIG.HAS_TKEEP {1} \
        CONFIG.HAS_TSTRB {1} \
        CONFIG.DECODER_REG {0} \
    ] $swtch

    # Bit 0 suppresses the camera, bit 1 suppresses the file player. The reset
    # default is 0b10 -- file player suppressed, camera flowing -- so an overlay
    # that is loaded and never told anything behaves exactly as it did before
    # this path existed.
    set src_sel [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 source_select]
    set_property -dict [list \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_GPIO_WIDTH {2} \
        CONFIG.C_IS_DUAL {0} \
        CONFIG.C_DOUT_DEFAULT {0x00000002} \
    ] $src_sel

    # Channel 1 is the soft reset libpcam5c.so pulses around reconfiguring the
    # video IP; channel 2 is the camera's enable pin.
    set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio_ip_reset]
    set_property -dict [list \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_ALL_OUTPUTS_2 {1} \
        CONFIG.C_DOUT_DEFAULT_2 {0x00000001} \
        CONFIG.C_GPIO2_WIDTH {1} \
        CONFIG.C_GPIO_WIDTH {1} \
        CONFIG.C_IS_DUAL {1} \
    ] $gpio

    # The camera's control bus. Linux drives it through the device-tree overlay,
    # which is why its address is pinned at 0x80140000 further down.
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_0

    # The D-PHY needs a 200 MHz reference regardless of what the video clock is.
    set clkwiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
    set_property -dict [list \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200} \
        CONFIG.USE_RESET {false} \
    ] $clkwiz

    # VDMA to the PS memory port: S2MM writing frames out, MM2S reading them in
    set icw [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect]
    set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] $icw

    # Control fan-out to the video-clock IP, the filter included
    set icc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0]
    set_property CONFIG.NUM_MI {8} $icc

    # Soft reset for the video IP, driven from gpio_ip_reset channel 1
    set soft_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset]
    set_property CONFIG.C_AUX_RESET_HIGH {0} $soft_rst

    # --- video datapath ----------------------------------------------------
    connect_bd_intf_net [get_bd_intf_pins mipi_phy_if_0]        [get_bd_intf_pins mipi_csi2_rx_subsyst/mipi_phy_if]
    connect_bd_intf_net [get_bd_intf_pins mipi_csi2_rx_subsyst/video_out] [get_bd_intf_pins axis_subset_converter/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins axis_subset_converter/M_AXIS]   [get_bd_intf_pins demosaic/s_axis_video]
    connect_bd_intf_net [get_bd_intf_pins demosaic/m_axis_video]          [get_bd_intf_pins gamma_lut/s_axis_video]
    connect_bd_intf_net [get_bd_intf_pins gamma_lut/m_axis_video]         [get_bd_intf_pins v_proc_sys/s_axis]
    connect_bd_intf_net [get_bd_intf_pins v_proc_sys/m_axis]              [get_bd_intf_pins axis_channel_swap/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins axis_channel_swap/M_AXIS]       [get_bd_intf_pins axis_switch/S00_AXIS]
    connect_bd_intf_net [get_bd_intf_pins axi_vdma/M_AXIS_MM2S]           [get_bd_intf_pins pixel_unpack/stream_in_64]
    connect_bd_intf_net [get_bd_intf_pins pixel_unpack/stream_out_48]     [get_bd_intf_pins axis_switch/S01_AXIS]
    connect_bd_intf_net [get_bd_intf_pins axis_switch/M00_AXIS]           [get_bd_intf_pins sobel/stream_in]
    connect_bd_intf_net [get_bd_intf_pins sobel/stream_out]               [get_bd_intf_pins pixel_pack/stream_in_48]
    connect_bd_intf_net [get_bd_intf_pins pixel_pack/stream_out_64]       [get_bd_intf_pins axi_vdma/S_AXIS_S2MM]
    connect_bd_intf_net [get_bd_intf_pins axi_vdma/M_AXI_S2MM]            [get_bd_intf_pins axi_interconnect/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_vdma/M_AXI_MM2S]            [get_bd_intf_pins axi_interconnect/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect/M00_AXI]       [get_bd_intf_pins M00_AXI]

    # --- control -----------------------------------------------------------
    connect_bd_intf_net [get_bd_intf_pins S_AXI_LITE]    [get_bd_intf_pins axi_vdma/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins csirxss_s_axi] [get_bd_intf_pins mipi_csi2_rx_subsyst/csirxss_s_axi]
    connect_bd_intf_net [get_bd_intf_pins S_AXI]         [get_bd_intf_pins axi_iic_0/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins IIC_0_0]       [get_bd_intf_pins axi_iic_0/IIC]
    connect_bd_intf_net [get_bd_intf_pins cam_gpio]      [get_bd_intf_pins gpio_ip_reset/GPIO2]

    connect_bd_intf_net [get_bd_intf_pins S00_AXI]                  [get_bd_intf_pins axi_interconnect_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins gamma_lut/s_axi_CTRL]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M01_AXI] [get_bd_intf_pins v_proc_sys/s_axi_ctrl]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M02_AXI] [get_bd_intf_pins gpio_ip_reset/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M03_AXI] [get_bd_intf_pins pixel_pack/s_axi_control]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M04_AXI] [get_bd_intf_pins demosaic/s_axi_CTRL]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M05_AXI] [get_bd_intf_pins sobel/s_axi_control]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M06_AXI] [get_bd_intf_pins pixel_unpack/s_axi_control]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M07_AXI] [get_bd_intf_pins source_select/S_AXI]
    connect_bd_net [get_bd_pins source_select/gpio_io_o] [get_bd_pins axis_switch/s_req_suppress]

    # --- clocks ------------------------------------------------------------
    connect_bd_net [get_bd_pins clk_100] \
        [get_bd_pins axi_vdma/s_axi_lite_aclk] \
        [get_bd_pins mipi_csi2_rx_subsyst/lite_aclk] \
        [get_bd_pins axi_iic_0/s_axi_aclk] \
        [get_bd_pins clk_wiz_0/clk_in1]

    connect_bd_net [get_bd_pins clk_video] \
        [get_bd_pins axi_interconnect/ACLK] \
        [get_bd_pins axi_interconnect/M00_ACLK] \
        [get_bd_pins axi_interconnect/S00_ACLK] \
        [get_bd_pins axi_interconnect/S01_ACLK] \
        [get_bd_pins axi_vdma/m_axi_s2mm_aclk] \
        [get_bd_pins axi_vdma/s_axis_s2mm_aclk] \
        [get_bd_pins axi_vdma/m_axi_mm2s_aclk] \
        [get_bd_pins axi_vdma/m_axis_mm2s_aclk] \
        [get_bd_pins pixel_unpack/ap_clk] \
        [get_bd_pins axis_switch/aclk] \
        [get_bd_pins source_select/s_axi_aclk] \
        [get_bd_pins axis_subset_converter/aclk] \
        [get_bd_pins demosaic/ap_clk] \
        [get_bd_pins gamma_lut/ap_clk] \
        [get_bd_pins gpio_ip_reset/s_axi_aclk] \
        [get_bd_pins mipi_csi2_rx_subsyst/video_aclk] \
        [get_bd_pins v_proc_sys/aclk] \
        [get_bd_pins axis_channel_swap/aclk] \
        [get_bd_pins sobel/ap_clk] \
        [get_bd_pins pixel_pack/ap_clk] \
        [get_bd_pins proc_sys_reset/slowest_sync_clk] \
        [get_bd_pins axi_interconnect_0/ACLK] \
        [get_bd_pins axi_interconnect_0/S00_ACLK] \
        [get_bd_pins axi_interconnect_0/M00_ACLK] \
        [get_bd_pins axi_interconnect_0/M01_ACLK] \
        [get_bd_pins axi_interconnect_0/M02_ACLK] \
        [get_bd_pins axi_interconnect_0/M03_ACLK] \
        [get_bd_pins axi_interconnect_0/M04_ACLK] \
        [get_bd_pins axi_interconnect_0/M05_ACLK] \
        [get_bd_pins axi_interconnect_0/M06_ACLK] \
        [get_bd_pins axi_interconnect_0/M07_ACLK]

    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins mipi_csi2_rx_subsyst/dphy_clk_200M]

    # --- resets ------------------------------------------------------------
    connect_bd_net [get_bd_pins rst_100n] \
        [get_bd_pins axi_vdma/axi_resetn] \
        [get_bd_pins mipi_csi2_rx_subsyst/lite_aresetn] \
        [get_bd_pins axi_iic_0/s_axi_aresetn]

    # axis_switch sits on the hard reset rather than the software one, so the
    # source a notebook has selected survives libpcam5c.so pulsing the soft
    # reset to reconfigure the camera. Its routing register is not restored by
    # anything if it is cleared, so a notebook always selects a source
    # explicitly after loading the overlay.
    connect_bd_net [get_bd_pins rst_video_n] \
        [get_bd_pins axi_interconnect/ARESETN] \
        [get_bd_pins axi_interconnect/M00_ARESETN] \
        [get_bd_pins axi_interconnect/S00_ARESETN] \
        [get_bd_pins axi_interconnect/S01_ARESETN] \
        [get_bd_pins axis_switch/aresetn] \
        [get_bd_pins source_select/s_axi_aresetn] \
        [get_bd_pins axis_subset_converter/aresetn] \
        [get_bd_pins gpio_ip_reset/s_axi_aresetn] \
        [get_bd_pins mipi_csi2_rx_subsyst/video_aresetn] \
        [get_bd_pins proc_sys_reset/ext_reset_in] \
        [get_bd_pins axi_interconnect_0/ARESETN] \
        [get_bd_pins axi_interconnect_0/S00_ARESETN] \
        [get_bd_pins axi_interconnect_0/M00_ARESETN] \
        [get_bd_pins axi_interconnect_0/M01_ARESETN] \
        [get_bd_pins axi_interconnect_0/M02_ARESETN] \
        [get_bd_pins axi_interconnect_0/M03_ARESETN] \
        [get_bd_pins axi_interconnect_0/M04_ARESETN] \
        [get_bd_pins axi_interconnect_0/M05_ARESETN] \
        [get_bd_pins axi_interconnect_0/M06_ARESETN] \
        [get_bd_pins axi_interconnect_0/M07_ARESETN]

    connect_bd_net [get_bd_pins gpio_ip_reset/gpio_io_o] [get_bd_pins proc_sys_reset/aux_reset_in]

    # The filter joins the demosaic, the gamma LUT, the CSC and the packer on
    # the software-controlled reset. libpcam5c.so pulses it whenever it changes
    # the camera's geometry, and a filter left running across that change would
    # spend a frame filtering the old resolution.
    connect_bd_net [get_bd_pins proc_sys_reset/peripheral_aresetn] \
        [get_bd_pins demosaic/ap_rst_n] \
        [get_bd_pins gamma_lut/ap_rst_n] \
        [get_bd_pins v_proc_sys/aresetn] \
        [get_bd_pins axis_channel_swap/aresetn] \
        [get_bd_pins sobel/ap_rst_n] \
        [get_bd_pins pixel_unpack/ap_rst_n] \
        [get_bd_pins pixel_pack/ap_rst_n]

    connect_bd_net [get_bd_pins axi_iic_0/iic2intc_irpt] [get_bd_pins iic2intc_irpt]

    current_bd_instance $oldCurInst
}

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]

# HPM0_LPD  32-bit  -> the AXI4-Lite control domain at 100 MHz
# HPM0_FPD  32-bit  -> the video-clock control domain at 300 MHz
# HP0       128-bit -> where the VDMA writes frames
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {1} \
    CONFIG.PSU__MAXIGP2__DATA_WIDTH {32} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__USE__IRQ1 {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__FPGA_PL1_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $lite_mhz \
    CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ $video_mhz \
    CONFIG.PSU__NUM_FABRIC_RESETS {1} \
] [get_bd_cells zynq_ultra_ps_e_0]

# Reset controller for the 100 MHz control domain
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_lite
# ...and for the 300 MHz video domain
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_video

# The three AXI4-Lite slaves that live in the 100 MHz domain
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_lite_periph
set_property CONFIG.NUM_MI {3} [get_bd_cells axi_lite_periph]

create_hier_cell_mipi [current_bd_instance .] mipi $filter_vlnv

# External ports
create_bd_intf_port -mode Slave  -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 CAM
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0      IIC_0_0
create_bd_port -dir O -from 0 -to 0 rpi_enb

connect_bd_intf_net [get_bd_intf_ports CAM]     [get_bd_intf_pins mipi/mipi_phy_if_0]
connect_bd_intf_net [get_bd_intf_ports IIC_0_0] [get_bd_intf_pins mipi/IIC_0_0]
connect_bd_net [get_bd_pins mipi/cam_gpio_tri_o] [get_bd_ports rpi_enb]

# Control paths
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins axi_lite_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_lite_periph/M00_AXI] [get_bd_intf_pins mipi/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_lite_periph/M01_AXI] [get_bd_intf_pins mipi/csirxss_s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_lite_periph/M02_AXI] [get_bd_intf_pins mipi/S_AXI]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins mipi/S00_AXI]

# Frames to DDR
connect_bd_intf_net [get_bd_intf_pins mipi/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# Clocks
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk] \
    [get_bd_pins rst_lite/slowest_sync_clk] \
    [get_bd_pins axi_lite_periph/ACLK] \
    [get_bd_pins axi_lite_periph/S00_ACLK] \
    [get_bd_pins axi_lite_periph/M00_ACLK] \
    [get_bd_pins axi_lite_periph/M01_ACLK] \
    [get_bd_pins axi_lite_periph/M02_ACLK] \
    [get_bd_pins mipi/clk_100]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk] \
    [get_bd_pins rst_video/slowest_sync_clk] \
    [get_bd_pins mipi/clk_video]

# Resets
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins rst_lite/ext_reset_in] \
    [get_bd_pins rst_video/ext_reset_in]

connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] \
    [get_bd_pins axi_lite_periph/ARESETN] \
    [get_bd_pins axi_lite_periph/S00_ARESETN] \
    [get_bd_pins axi_lite_periph/M00_ARESETN] \
    [get_bd_pins axi_lite_periph/M01_ARESETN] \
    [get_bd_pins axi_lite_periph/M02_ARESETN] \
    [get_bd_pins mipi/rst_100n]

connect_bd_net [get_bd_pins rst_video/peripheral_aresetn] [get_bd_pins mipi/rst_video_n]

# The camera's I2C interrupt has to land on pl_ps_irq1, because the device-tree
# overlay in dts/ declares interrupt 104, and 104 is what pl_ps_irq1[0] becomes
# once the GIC numbering is applied (SPI 136, minus the 32 the binding drops).
# Move it and Linux's xiic driver waits for an interrupt that never arrives.
connect_bd_net [get_bd_pins mipi/iic2intc_irpt] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq1]

# ---------------------------------------------------------------------------
# Addresses. The I2C controller is pinned: dts/ch12.dtsi names 0x80140000, and
# Linux binds the camera's I2C bus from that node. The rest only have to be
# somewhere -- PYNQ reads them out of the .hwh -- but they are kept where AMD's
# base overlay puts them so the two are easy to compare.
# ---------------------------------------------------------------------------
assign_bd_address -offset 0x80140000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/axi_iic_0/S_AXI/Reg] -force
assign_bd_address -offset 0x80150000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/axi_vdma/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0x80160000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/mipi_csi2_rx_subsyst/csirxss_s_axi/Reg] -force
assign_bd_address -offset 0xA0000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/demosaic/s_axi_CTRL/Reg] -force
assign_bd_address -offset 0xA0010000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/gamma_lut/s_axi_CTRL/Reg] -force
assign_bd_address -offset 0xA0020000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/gpio_ip_reset/S_AXI/Reg] -force
assign_bd_address -offset 0xA0030000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/pixel_pack/s_axi_control/Reg] -force
assign_bd_address -offset 0xA0040000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/v_proc_sys/s_axi_ctrl/Reg] -force
assign_bd_address -offset 0xA0050000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/sobel/s_axi_control/Reg] -force
assign_bd_address -offset 0xA0060000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/pixel_unpack/s_axi_control/Reg] -force
assign_bd_address -offset 0xA0070000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs mipi/source_select/S_AXI/Reg] -force
assign_bd_address -offset 0x00000000 -range 0x80000000 -target_address_space [get_bd_addr_spaces mipi/axi_vdma/Data_S2MM] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force
assign_bd_address -offset 0x00000000 -range 0x80000000 -target_address_space [get_bd_addr_spaces mipi/axi_vdma/Data_MM2S] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force

validate_bd_design
save_bd_design

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------
add_files -fileset constrs_1 -norecurse $script_dir/constraints/pins.xdc

make_wrapper -files [get_files $proj_dir/${proj_name}.srcs/sources_1/bd/${bd_name}/${bd_name}.bd] -top
add_files -norecurse $proj_dir/${proj_name}.gen/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set bit_src [glob -nocomplain $proj_dir/${proj_name}.runs/impl_1/*_wrapper.bit]
set hwh_src $proj_dir/${proj_name}.gen/sources_1/bd/${bd_name}/hw_handoff/${bd_name}.hwh

if {[llength $bit_src] == 0 || ![file exists $hwh_src]} {
    error "Build finished but artifacts are missing -- check impl_1 for errors"
}

file copy -force [lindex $bit_src 0] $out_dir/sobel_stream.bit
file copy -force $hwh_src            $out_dir/sobel_stream.hwh

# Timing, for the record. Setup and hold are reported separately: the worst
# path in this design is a hold path inside the CSI-2 subsystem that the router
# fixes to a few picoseconds of margin, and quoting that single number makes a
# comfortable design look like it is about to fall over.
open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "=========================================="
puts " $variant build complete"
puts "   $out_dir/sobel_stream.bit"
puts "   $out_dir/sobel_stream.hwh"
puts "   worst setup slack: $wns ns"
puts "   worst hold slack:  $whs ns"
puts ""
puts " The overlay also needs its device-tree overlay next to it on the board:"
puts "   dts/ -> sobel_stream.dtbo   (see dts/Makefile)"
puts "=========================================="
exit
