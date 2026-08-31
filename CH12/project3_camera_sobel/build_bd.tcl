# Vivado block design for CH12 project 3: the camera feeding the filter.
#
#   vivado -mode batch -source build_bd.tcl -tclargs sv     -> out_sv/
#   vivado -mode batch -source build_bd.tcl -tclargs vhdl   -> out_vhdl/
#   vivado -mode batch -source build_bd.tcl -tclargs hls    -> out_hls/
#
# Project 1's camera and project 2's accelerator in one design:
#
#   OV5647 -> [ mipi hierarchy ] -> VDMA S2MM -> DDR
#                                                  |
#                              video_filter <------+   (PS calls it per frame)
#                                     |
#                                     +-------> DDR -> DPDMA -> DisplayPort
#
# Note where the filter is NOT. It is not in the video path: the camera writes
# frames to DDR and software calls the accelerator on each one, exactly as
# project 2 does with frames from a file. That is the whole point of a
# memory-mapped accelerator -- the filter cannot tell a sensor from a video
# file, so the two projects share an implementation, a driver and a notebook
# cell. The cost is a DDR round trip per frame, which is what the chapter
# measures.
#
# Produces out_<variant>/camera_sobel.bit and .hwh.

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir .. common config.tcl]
source [file join $script_dir .. common package_filter.tcl]
source [file join $script_dir .. common ps_config.tcl]
source [file join $script_dir .. common mipi_hier.tcl]

set variant "sv"
if {[llength $argv] > 0} { set variant [lindex $argv 0] }
if {[lsearch -exact {sv vhdl hls} $variant] < 0} {
    error "variant must be sv, vhdl or hls -- got '$variant'"
}

# Options after the variant, in any order:
#
#   ila       System ILA on the accelerator's control port and write master
#   xclk      the OLD control path: AXI4-Lite crossing 100 -> 187.5 MHz
#   oneclk    everything on pl_clk0, no crossing and no dedicated master
#
# The DEFAULT is a dedicated PS master (HPM1_FPD) clocked with the
# accelerator, so the control path never crosses a clock domain.
#
# That default exists because the crossing loses read data. About one frame in
# a thousand, a CTRL read carrying AP_DONE was acknowledged at the accelerator
# -- clearing the bit, since AP_DONE is clear-on-read -- and never delivered to
# the PS. Software then waited forever on a frame that had finished, and the
# frame it failed to arm next is the one that appeared to time out.
#
# Measured, all with the software workaround disabled:
#
#   crossing inside axi_interconnect          ~0.5% of frames
#   crossing via explicit axi_clock_converter ~0.5%   (ACLK_ASYNC=1, constrained,
#                                                      timing met -- and still lost)
#   no crossing, accelerator at 100 MHz       0 in 8000   (oneclk)
#   no crossing, accelerator at 187.5 MHz     0 in 8000   (this default)
#
# The last two together are what make it the crossing rather than the clock
# rate: oneclk changed both at once, this changes only the crossing.
#
# `xclk` rebuilds the faulty architecture, because a fault you cannot
# reproduce is a story rather than a result.
set want_ila 0
set one_clock 0
set fast_ctrl 1
foreach a [lrange $argv 1 end] {
    switch -- $a {
        ila    { set want_ila 1 }
        oneclk { set one_clock 1 ; set fast_ctrl 0 }
        xclk   { set fast_ctrl 0 }
        default { error "unknown option '$a' -- expected ila, xclk or oneclk" }
    }
}
set accel_clk [expr {$one_clock ? "pl_clk0" : "pl_clk2"}]

# One suffix, built once, so the project, the run directory and the artifacts
# can never disagree about which configuration they are.
set tag ""
if {$want_ila}                  { append tag "_ila" }
if {$one_clock}                 { append tag "_oneclk" }
if {!$fast_ctrl && !$one_clock} { append tag "_xclk" }

set proj_name camera_sobel_${variant}${tag}
set proj_dir  $script_dir/vivado_${variant}${tag}
set bd_name   design_1
set out_dir   $script_dir/out_${variant}${tag}
set ip_repo   $script_dir/ip_repo_$variant
# A separate repo: ch12_filter_vlnv and ch12_pixel_pack_vlnv each wipe the
# directory they are handed before packaging into it.
set pack_repo $script_dir/ip_repo_pack_$variant

ch12_require_dir $ch12_board_repo "AUP-ZU3 board files"
ch12_require_dir [lindex $ch12_pynq_ip 0] "PYNQ's prebuilt pixel_pack_2 IP"

set filter [ch12_filter_vlnv $variant $ip_repo]
set filter_vlnv [lindex $filter 0]
set filter_repo [lindex $filter 1]

# The camera's pixel packer follows the variant too. This is the only project
# that does it: 0 and 1 exist to bring the camera up and are left on PYNQ's
# prebuilt HLS packer, so the design the camera was debugged against does not
# move underneath them.
set packer [ch12_pixel_pack_vlnv $variant $pack_repo]
set packer_vlnv [lindex $packer 0]
set packer_repo [lindex $packer 1]

create_project $proj_name $proj_dir -part $ch12_part -force
set_property ip_repo_paths \
    [concat $ch12_pynq_ip [list $filter_repo] [list $packer_repo]] \
    [current_project]
update_ip_catalog -rebuild

set_property board_part_repo_paths [list $ch12_board_repo] [current_project]
set_property board_part $ch12_board_part [current_project]

create_bd_design $bd_name

# Three clocks, and none of the numbers is a free choice -- see ch12_add_ps.
# HP0 for the camera VDMA, HP1 and HP2 for the accelerator's two ports.
ch12_add_ps 100 $ch12_video_mhz $ch12_accel_mhz 1 {0 1 2}

# HPM0_FPD carries the video IP control path at 300 MHz.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
] [get_bd_cells zynq_ultra_ps_e_0]

# A dedicated master for the accelerator's control path, clocked with the
# accelerator itself. 128 bits because that is what the board boots with --
# see the paragraph below, which applies to this port exactly as much.
if {$fast_ctrl} {
    set_property -dict [list \
        CONFIG.PSU__USE__M_AXI_GP1 {1} \
        CONFIG.PSU__MAXIGP1__DATA_WIDTH {128} \
    ] [get_bd_cells zynq_ultra_ps_e_0]
}

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

ch12_create_mipi_hier / mipi $packer_vlnv
create_bd_cell -type ip -vlnv $filter_vlnv video_filter_0

# --- external ports ---------------------------------------------------------
create_bd_intf_port -mode Slave  -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 CAM
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 IIC_0_0
create_bd_port -dir O -from 0 -to 0 rpi_enb

connect_bd_intf_net [get_bd_intf_ports CAM]     [get_bd_intf_pins mipi/mipi_phy_if_0]
connect_bd_intf_net [get_bd_intf_ports IIC_0_0] [get_bd_intf_pins mipi/IIC_0_0]
connect_bd_net      [get_bd_ports rpi_enb]      [get_bd_pins mipi/cam_gpio_tri_o]

# --- clocks and resets ------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_lite
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_accel

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins mipi/lite_aclk] \
    [get_bd_pins rst_lite/slowest_sync_clk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] \
    [get_bd_pins mipi/video_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

# The accelerator's whole datapath -- both DDR ports and the PS slave ports
# they land on -- runs at 200 MHz, so nothing on it has to cross a clock
# domain. Only the AXI4-Lite control path crosses, from 100 MHz, and the
# interconnect below does that conversion.
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/$accel_clk] \
    [get_bd_pins video_filter_0/ap_clk] \
    [get_bd_pins rst_accel/slowest_sync_clk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp1_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp2_fpd_aclk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins mipi/aux_reset_in] \
    [get_bd_pins rst_lite/ext_reset_in] \
    [get_bd_pins rst_accel/ext_reset_in]

connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn]  [get_bd_pins mipi/lite_aresetn]
connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins video_filter_0/ap_rst_n]

# --- interrupts -------------------------------------------------------------
connect_bd_net [get_bd_pins mipi/iic2intc_irpt] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property CONFIG.NUM_PORTS {3} [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins mipi/csirxss_csi_irq]   [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins mipi/s2mm_introut]      [get_bd_pins xlconcat_0/In1]
# The accelerator's interrupt is wired but unused: the notebook polls AP_DONE,
# because a frame takes single-digit milliseconds and an interrupt round trip
# through the kernel costs more than it saves. It is connected so that a reader
# who wants to try the other way does not have to rebuild the design.
connect_bd_net [get_bd_pins video_filter_0/interrupt] [get_bd_pins xlconcat_0/In2]

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
    CONFIG.C_KIND_OF_INTR {0xFFFFFFF8} \
] [get_bd_cells axi_intc_0]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins axi_intc_0/intr]
connect_bd_net [get_bd_pins axi_intc_0/irq]  [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# --- AXI4-Lite control path -------------------------------------------------
# Every port of this interconnect runs at 100 MHz. The crossing to the
# accelerator's 187.5 MHz is done by an explicit axi_clock_converter, NOT by
# letting M03_ACLK differ from the rest.
#
# That is not a stylistic preference. With M03 clocked at 187.5 the
# interconnect performed the crossing itself, and it lost read data: an ILA on
# both sides of this interconnect, capturing the same event, showed the
# accelerator presenting 0x0000000E on CTRL -- ap_done | ap_idle | ap_ready --
# while the PS side went straight from 0x1 to 0x4 with no 0xE at all. Across
# one 4096-read window the IP presented five completions and the PS received
# three. The PS also received 0x00000000 ten times, a value the accelerator
# never presents and not a legal CTRL state.
#
# AP_DONE is clear-on-read, so a read whose data dies in transit destroys the
# completion: the bit is cleared at the IP and the value never arrives.
# Software then polls forever on a frame that finished, and the frame it fails
# to arm next is the one that appears to time out. That is the AP_DONE fault,
# and it cost five wrong theories before an ILA on both sides of one
# interconnect showed it.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 lite_periph
# One fewer master when the accelerator has its own path: an unconnected
# master port fails validation rather than being ignored.
set lite_mi [expr {$fast_ctrl ? 4 : 5}]
set_property -dict [list CONFIG.NUM_MI $lite_mi CONFIG.NUM_SI {1}] [get_bd_cells lite_periph]
set intc_port [expr {$fast_ctrl ? "M03_AXI" : "M04_AXI"}]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins lite_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M00_AXI] [get_bd_intf_pins mipi/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M01_AXI] [get_bd_intf_pins mipi/csirxss_s_axi]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M02_AXI] [get_bd_intf_pins mipi/S_AXI]
# M03 -> clock converter -> the accelerator. With one_clock there is nothing
# to convert, so the converter is left out entirely rather than degenerated.
if {$fast_ctrl} {
    # Straight off the dedicated master, single clock, width-converted only.
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ctrl
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] \
        [get_bd_cells sc_ctrl]
    connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM1_FPD] \
        [get_bd_intf_pins sc_ctrl/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins sc_ctrl/M00_AXI] \
        [get_bd_intf_pins video_filter_0/s_axi_control]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] \
        [get_bd_pins sc_ctrl/aclk] \
        [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]
    connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins sc_ctrl/aresetn]
    # lite_periph no longer serves the accelerator: M03 becomes the intc.
} elseif {$one_clock} {
    connect_bd_intf_net [get_bd_intf_pins lite_periph/M03_AXI] \
        [get_bd_intf_pins video_filter_0/s_axi_control]
} else {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter ctrl_cdc
    connect_bd_intf_net [get_bd_intf_pins lite_periph/M03_AXI] [get_bd_intf_pins ctrl_cdc/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins ctrl_cdc/M_AXI] [get_bd_intf_pins video_filter_0/s_axi_control]
}
connect_bd_intf_net [get_bd_intf_pins lite_periph/$intc_port] [get_bd_intf_pins axi_intc_0/s_axi]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_intc_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins axi_intc_0/s_axi_aresetn]
set lite_clk_pins {ACLK S00_ACLK M00_ACLK M01_ACLK M02_ACLK M03_ACLK}
if {!$fast_ctrl} { lappend lite_clk_pins M04_ACLK }
foreach p $lite_clk_pins {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins lite_periph/$p]
}
set lite_rst_pins {ARESETN S00_ARESETN M00_ARESETN M01_ARESETN M02_ARESETN M03_ARESETN}
if {!$fast_ctrl} { lappend lite_rst_pins M04_ARESETN }
foreach p $lite_rst_pins {
    connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins lite_periph/$p]
}

# The converter straddles the two domains: 100 MHz in, 187.5 MHz out.
# ctrl_cdc exists only on the default path: oneclk needs no converter, and
# fastctrl replaced it with a dedicated master.
if {!$one_clock && !$fast_ctrl} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]    [get_bd_pins ctrl_cdc/s_axi_aclk]
    connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn]  [get_bd_pins ctrl_cdc/s_axi_aresetn]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2]    [get_bd_pins ctrl_cdc/m_axi_aclk]
    connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins ctrl_cdc/m_axi_aresetn]
}

# --- DDR paths ---------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins mipi/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins mipi/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# One SmartConnect per accelerator port, single-clock at 200 MHz. Separate
# rather than shared so a read burst and a write burst never arbitrate against
# each other -- the filter issues both continuously and is DDR-bound.
foreach {sc port slave} {sc_gmem0 m_axi_gmem0 S_AXI_HP1_FPD sc_gmem1 m_axi_gmem1 S_AXI_HP2_FPD} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 $sc
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells $sc]
    connect_bd_intf_net [get_bd_intf_pins video_filter_0/$port] [get_bd_intf_pins $sc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/$slave]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/$accel_clk] [get_bd_pins $sc/aclk]
    connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins $sc/aresetn]
}

# --- addresses ---------------------------------------------------------------
# AMD's addresses for the camera, and at least the IIC one is load bearing:
# dts/camera_sobel.dtsi declares the I2C controller at 0x80140000 and PYNQ's
# camera driver finds the camera's bus through the label on that node.
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

# --- the ILA --------------------------------------------------------------
if {$want_ila} {
    # Two probes, on OPPOSITE SIDES of the same interconnect:
    #
    #   the IP side   (video_filter_0/s_axi_control, 187.5 MHz)
    #   the PS side   (lite_periph/S00_AXI, 100 MHz)
    #
    # The IP side already showed the accelerator returning 0x0000000E -- the
    # completion -- exactly once, followed by software never re-arming. The
    # question that leaves is whether that value reaches the PS. Comparing the
    # two ports across the same fault answers it; a single side cannot.
    #
    # Both are armed while the system is idle and triggered on their own first
    # CTRL read of 0x4, so both capture the SAME fault onset. Triggering the PS
    # side on 0xE would be useless -- it reads 0xE on every healthy frame.
    set debug_specs {
        {video_filter_0/s_axi_control zynq_ultra_ps_e_0/pl_clk2}
        {lite_periph/S00_AXI          zynq_ultra_ps_e_0/pl_clk0}
    }
    set marked {}
    set autodict {}
    foreach spec $debug_specs {
        lassign $spec pinpath clkpath
        set net [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $pinpath]]
        if {$net eq ""} { error "ILA: nothing connected to $pinpath" }
        set_property HDL_ATTRIBUTE.DEBUG true $net
        lappend marked $net
        # Each side is sampled on ITS OWN clock: the interconnect crosses
        # 100 MHz to 187.5, and probing one side on the other's clock would
        # produce a capture that looks fine and means nothing.
        lappend autodict $net [list AXI_R_ADDRESS "Data and Trigger" \
                                    AXI_R_DATA "Data and Trigger" \
                                    AXI_W_ADDRESS "Data and Trigger" \
                                    AXI_W_DATA "Data and Trigger" \
                                    AXI_W_RESPONSE "Data and Trigger" \
                                    CLK_SRC "/$clkpath" \
                                    SYSTEM_ILA "Auto" APC_EN "0"]
        puts " ILA probe: $pinpath on $clkpath -> $net"
    }
    apply_bd_automation -rule xilinx.com:bd_rule:debug -dict $autodict

    # The automation inserts the System ILAs but does not honour CLK_SRC here,
    # leaving /system_ila_*/clk floating. Connect each to the clock of the
    # interface it is watching.
    set idx 0
    foreach ila [lsort [get_bd_cells -quiet -filter {NAME =~ "system_ila*"}]] {
        lassign [lindex $debug_specs $idx] pinpath clkpath
        set cp [get_bd_pins -quiet $ila/clk]
        if {$cp ne "" && [get_bd_nets -quiet -of_objects $cp] eq ""} {
            connect_bd_net [get_bd_pins $clkpath] $cp
            puts " ILA: [get_property NAME $ila]/clk -> $clkpath"
        }
        set rp [get_bd_pins -quiet $ila/resetn]
        if {$rp ne "" && [get_bd_nets -quiet -of_objects $rp] eq ""} {
            connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] $rp
        }
        set_property -dict [list CONFIG.C_DATA_DEPTH {4096} \
                                 CONFIG.C_EN_STRG_QUAL {1}] $ila
        incr idx
    }
    puts " ILA: [llength $marked] AXI interfaces instrumented"
}

add_files -fileset constrs_1 -norecurse $script_dir/constraints/pins.xdc

ch12_finish $proj_dir $proj_name $bd_name $out_dir camera_sobel 12

puts " variant: $variant   ($filter_vlnv)"
puts " packer:  $packer_vlnv"
exit
