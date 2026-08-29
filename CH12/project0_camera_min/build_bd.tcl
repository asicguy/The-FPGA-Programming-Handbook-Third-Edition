# CH12 project 0: the smallest thing that gets a camera onto a screen.
#
#   vivado -mode batch -source build_bd.tcl   -> out/camera_min.{bit,hwh}
#
#   OV5647 --CSI-2--> [ mipi ] --> VDMA S2MM --> DDR --> DPDMA --> DisplayPort
#
# WHY THIS EXISTS
# ---------------
# The camera would not work, and project 1 has too many moving parts to find
# out why in. This is the same pipeline with everything removable removed: one
# clock domain, one reset, one AXI aperture, no accelerator, a plain script
# instead of a notebook. Run this first on a new board.
#
# A NOTE ON THE ADDRESS MAP, BECAUSE THE FIRST EXPLANATION HERE WAS WRONG
# ----------------------------------------------------------------------
# This design puts every register on M_AXI_HPM0_LPD at 0x80000000, where AMD's
# base overlay and project 1 put five of them behind M_AXI_HPM0_FPD at
# 0xA0000000. For a while this comment claimed the FPD aperture "did not
# respond on this board". That was a wrong diagnosis, and the ILA disproved it:
# those IPs were held in reset by gpio_ip_reset channel 1, which powers up at 0
# and drives an active-low reset. In reset they do not complete an AXI4-Lite
# transaction, and ZynqMP has no bus timeout on the PL ports, so the access
# hangs the master permanently -- which looked exactly like a dead aperture.
# Release the GPIO first and 0xA0000000 works fine; project 3 does precisely
# that, at those addresses.
#
# So the LPD choice is a simplification, not a workaround, and it is kept for
# the reason everything else here is kept: fewer variables. It costs nothing:
#
# ONE CLOCK DOMAIN
# ----------------
# Project 1 ran the video datapath at 300 MHz because that is what AMD's base
# overlay does. The arithmetic says it does not need to. The pipeline carries
# two pixels per clock, and 1280x720 at 60 fps is 55.3 Mpixel/s, so it needs
# 27.6 MHz. The CSI-2 link's own peak -- 437.5 Mbps on two lanes, RAW10 -- is
# 87.5 Mpixel/s, or 43.75 MHz at two pixels per clock. 100 MHz has better than
# a factor of two in hand over the worst case and a factor of 3.6 over the
# average.
#
# Running the whole hierarchy on pl_clk0 therefore costs nothing real and
# removes, in one step: the FPD master, a clock domain crossing on the control
# path, a second reset domain, and the 300 MHz timing closure problem. The
# D-PHY keeps its own 200 MHz reference, which is generated inside the
# hierarchy by clk_wiz_0 and is not negotiable.
#
# What is deliberately NOT here: no accelerator, no interrupts anyone reads, no
# second video mode. If this does not produce a picture, the fault is in the
# camera, the sensor driver, or the display -- and nowhere else.

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir .. common config.tcl]
source [file join $script_dir .. common ps_config.tcl]
source [file join $script_dir .. common mipi_hier.tcl]

# Optional: -tclargs ila adds a System ILA on every AXI4-Stream hop between the
# CSI-2 receiver and the VDMA. Built into a separate project and output
# directory so the working bitstream is never clobbered by a debug build.
set want_ila 0
if {[llength $argv] > 0 && [lindex $argv 0] eq "ila"} { set want_ila 1 }

if {$want_ila} {
    set proj_name camera_min_ila
    set proj_dir  $script_dir/vivado_ila
    set out_dir   $script_dir/out_ila
} else {
    set proj_name camera_min
    set proj_dir  $script_dir/vivado
    set out_dir   $script_dir/out
}
set bd_name   design_1

ch12_require_dir $ch12_board_repo "AUP-ZU3 board files"
ch12_require_dir [lindex $ch12_pynq_ip 0] "PYNQ's prebuilt pixel_pack_2 IP"

create_project $proj_name $proj_dir -part $ch12_part -force
set_property ip_repo_paths $ch12_pynq_ip [current_project]
update_ip_catalog -rebuild
set_property board_part_repo_paths [list $ch12_board_repo] [current_project]
set_property board_part $ch12_board_part [current_project]

create_bd_design $bd_name

# --- PS ---------------------------------------------------------------------
# PL0 at 100 MHz and nothing else. No PL1, no PL2, no FPD master. IRQ1 is for
# the camera's I2C controller; HP0 takes the VDMA's writes to DDR.
ch12_add_ps 100 0 0 1 {0}

ch12_create_mipi_hier / mipi

# --- external ports ---------------------------------------------------------
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 CAM
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 IIC_0_0
# 1-bit vector, not a scalar: constraints/pins.xdc constrains rpi_enb[0],
# and a scalar port leaves it unconstrained -- which fails write_bitstream
# on DRC NSTD-1/UCIO-1 after implementation has already run.
create_bd_port -dir O -from 0 -to 0 rpi_enb

connect_bd_intf_net [get_bd_intf_ports CAM]     [get_bd_intf_pins mipi/mipi_phy_if_0]
connect_bd_intf_net [get_bd_intf_ports IIC_0_0] [get_bd_intf_pins mipi/IIC_0_0]
connect_bd_net      [get_bd_ports rpi_enb]      [get_bd_pins mipi/cam_gpio_tri_o]

# --- clocks and resets ------------------------------------------------------
# One clock, one reset, everywhere. `lite_aclk` and `video_aclk` are separate
# pins on the hierarchy because AMD's design drives them from separate PS
# clocks; tying them together is what collapses the two domains.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins mipi/lite_aclk] \
    [get_bd_pins mipi/video_aclk] \
    [get_bd_pins rst_ps/slowest_sync_clk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins mipi/aux_reset_in] \
    [get_bd_pins rst_ps/ext_reset_in]

connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn] [get_bd_pins mipi/lite_aresetn]

# --- interrupts -------------------------------------------------------------
# The I2C controller goes to pl_ps_irq1[0], which is SPI 136 -- dts/*.dtsi says
# <0 104 4> because the GIC binding counts SPIs from 32. Anywhere else and
# Linux's xiic driver waits for an interrupt that never arrives.
connect_bd_net [get_bd_pins mipi/iic2intc_irpt] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property CONFIG.NUM_PORTS {2} [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins mipi/csirxss_csi_irq] [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins mipi/s2mm_introut]    [get_bd_pins xlconcat_0/In1]

# Nothing in this project reads an interrupt, and the controller is still
# required: PYNQ attributes an interrupt to an IP by tracing it to an AXI
# Interrupt Controller, and without one `AxiVDMA.__init__` dies on
# `self.s2mm_introut`. Pure metadata, refused-to-start-without metadata.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0
set_property -dict [list \
    CONFIG.C_IRQ_CONNECTION {1} \
    CONFIG.C_HAS_FAST {0} \
    CONFIG.C_KIND_OF_INTR {0xFFFFFFFC} \
] [get_bd_cells axi_intc_0]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins axi_intc_0/intr]
connect_bd_net [get_bd_pins axi_intc_0/irq]  [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# --- AXI --------------------------------------------------------------------
# Five AXI4-Lite slaves, one interconnect, one clock, one reset, one aperture.
# M04 is the one that matters: it carries the video IP control path, which in
# project 1 came from M_AXI_HPM0_FPD and did not work.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 lite_periph
set_property -dict [list CONFIG.NUM_MI {5} CONFIG.NUM_SI {1}] [get_bd_cells lite_periph]

connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins lite_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M00_AXI] [get_bd_intf_pins mipi/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M01_AXI] [get_bd_intf_pins mipi/csirxss_s_axi]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M02_AXI] [get_bd_intf_pins mipi/S_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M03_AXI] [get_bd_intf_pins axi_intc_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M04_AXI] [get_bd_intf_pins mipi/S00_AXI]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_intc_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn]  [get_bd_pins axi_intc_0/s_axi_aresetn]

foreach p {ACLK S00_ACLK M00_ACLK M01_ACLK M02_ACLK M03_ACLK M04_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins lite_periph/$p]
}
foreach p {ARESETN S00_ARESETN M00_ARESETN M01_ARESETN M02_ARESETN M03_ARESETN M04_ARESETN} {
    connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn] [get_bd_pins lite_periph/$p]
}

# The VDMA's writes to DDR.
connect_bd_intf_net [get_bd_intf_pins mipi/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# --- addresses --------------------------------------------------------------
# Every slave in the 0x80000000 aperture, which is the whole point. The IIC
# address is load bearing: dts/camera_min.dtsi declares it at 0x80140000 and
# the camera driver finds its bus by the label on that node.
assign_bd_address
set_property offset 0x80000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_intc_0_Reg}]
set_property offset 0x80140000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_iic_0_Reg}]
set_property offset 0x80150000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_vdma_Reg}]
set_property offset 0x80160000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_mipi_csi2_rx_subsyst_Reg}]
set_property offset 0x80200000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_demosaic_Reg}]
set_property offset 0x80210000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_gamma_lut_Reg}]
set_property offset 0x80220000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_gpio_ip_reset_Reg}]
set_property offset 0x80230000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_pixel_pack_Reg}]
set_property offset 0x80240000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_v_proc_sys_Reg}]

# --- the ILA ----------------------------------------------------------------
# Every register in this pipeline reads back correct, every block is out of
# reset and running, the sensor transmits valid RAW10 with zero link errors,
# and nothing reaches the VDMA. Software has no more visibility: AXI4-Stream
# handshakes are not memory-mapped, so TVALID/TREADY cannot be read from
# /dev/mem at any address.
#
# These are the seven hops between the receiver and DDR, in order. Whichever
# one shows TVALID never asserting is where the video stops, and that turns a
# five-way guess into one named signal.
#
# Net names come from common/mipi_hier.tcl and are AMD's, so they are also the
# names in the base overlay if this ever needs repeating there.
if {$want_ila} {
    set debug_nets {
        mipi_csi2_rx_subsyst_0_video_out
        axis_subset_converter_0_M_AXIS
        dm0_m_axis_video
        gammalut_m_axis
        v_proc_sys_0_m_axis
        axis_channel_swap_m_axis
        pixel_pack_m_axis
    }
    set marked {}
    foreach n $debug_nets {
        set net [get_bd_intf_nets -quiet /mipi/$n]
        if {$net eq ""} {
            error "ILA: no interface net /mipi/$n -- the hierarchy changed;\
                   check the connect_bd_intf_net names in common/mipi_hier.tcl"
        }
        set_property HDL_ATTRIBUTE.DEBUG true $net
        lappend marked $net
        puts " ILA probe: /mipi/$n"
    }

    set autodict {}
    foreach net $marked {
        lappend autodict $net {AXIS_SIGNALS "Data and Trigger" \
                                CLK_SRC "/zynq_ultra_ps_e_0/pl_clk0" \
                                SYSTEM_ILA "Auto" APC_EN "0"}
    }
    apply_bd_automation -rule xilinx.com:bd_rule:debug -dict $autodict
    puts " ILA: [llength $marked] AXI4-Stream interfaces instrumented"
}

add_files -fileset constrs_1 -norecurse $script_dir/constraints/pins.xdc

ch12_finish $proj_dir $proj_name $bd_name $out_dir camera_min 12
exit
