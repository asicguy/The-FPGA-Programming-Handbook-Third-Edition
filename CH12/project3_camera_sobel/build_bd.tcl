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

# Optional: -tclargs <variant> ila puts a System ILA on the accelerator's
# AXI4-Lite control port and its write master.
#
# This exists for the AP_DONE fault. About one frame in a thousand the
# accelerator finishes -- the destination's last word is written, and IP_ISR
# latches ap_done -- and yet AP_DONE never appears in CTRL across 400,000
# polls. Five theories have been measured away, and software has run out of
# visibility: the completion path between the write engine and the CTRL bit is
# not memory-mapped, so no address shows what happens on it.
#
# The trigger to set is a CTRL read returning exactly 0x4 -- ap_idle set,
# ap_done clear, ap_start clear. In normal operation that combination is never
# read: the poll sees 0x6 (idle|done) and stops, and the first poll of a new
# frame sees 0x5 (idle|start). 0x4 is the fault and nothing else.
set want_ila 0
if {[llength $argv] > 1 && [lindex $argv 1] eq "ila"} { set want_ila 1 }

set proj_name camera_sobel_$variant
if {$want_ila} { set proj_name camera_sobel_${variant}_ila }
set proj_dir  $script_dir/vivado_$variant
if {$want_ila} { set proj_dir $script_dir/vivado_${variant}_ila }
set bd_name   design_1
set out_dir   $script_dir/out_$variant
if {$want_ila} { set out_dir $script_dir/out_${variant}_ila }
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
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] \
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
# Four slaves. M03 runs at 200 MHz while the rest of the interconnect runs at
# 100, which is where the control-path clock crossing happens.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 lite_periph
set_property -dict [list CONFIG.NUM_MI {5} CONFIG.NUM_SI {1}] [get_bd_cells lite_periph]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins lite_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M00_AXI] [get_bd_intf_pins mipi/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M01_AXI] [get_bd_intf_pins mipi/csirxss_s_axi]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M02_AXI] [get_bd_intf_pins mipi/S_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M03_AXI] [get_bd_intf_pins video_filter_0/s_axi_control]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M04_AXI] [get_bd_intf_pins axi_intc_0/s_axi]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_intc_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins axi_intc_0/s_axi_aresetn]
foreach p {ACLK S00_ACLK M00_ACLK M01_ACLK M02_ACLK M04_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins lite_periph/$p]
}
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] [get_bd_pins lite_periph/M03_ACLK]
foreach p {ARESETN S00_ARESETN M00_ARESETN M01_ARESETN M02_ARESETN M04_ARESETN} {
    connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins lite_periph/$p]
}
connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins lite_periph/M03_ARESETN]

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
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] [get_bd_pins $sc/aclk]
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
    # Find the nets from the PINS, not by name: Vivado auto-names interface
    # nets after whichever end it feels like, and a name that drifts would
    # instrument nothing while still building.
    set debug_intf {s_axi_control m_axi_gmem1}
    set marked {}
    foreach n $debug_intf {
        set net [get_bd_intf_nets -quiet \
                     -of_objects [get_bd_intf_pins video_filter_0/$n]]
        if {$net eq ""} {
            error "ILA: nothing connected to video_filter_0/$n"
        }
        set_property HDL_ATTRIBUTE.DEBUG true $net
        lappend marked $net
        puts " ILA probe: video_filter_0/$n -> $net"
    }
    # Whatever clocks the accelerator is what the ILA must sample on.
    set ila_clk [get_bd_pins -quiet \
        -of_objects [get_bd_nets -of_objects [get_bd_pins video_filter_0/ap_clk]] \
        -filter {DIR == O}]
    if {$ila_clk eq ""} { error "ILA: cannot find the clock driving video_filter_0/ap_clk" }
    puts " ILA clock: $ila_clk"

    set autodict {}
    foreach net $marked {
        lappend autodict $net {AXI_R_ADDRESS "Data and Trigger" \
                               AXI_R_DATA "Data and Trigger" \
                               AXI_W_ADDRESS "Data and Trigger" \
                               AXI_W_DATA "Data and Trigger" \
                               AXI_W_RESPONSE "Data and Trigger" \
                               CLK_SRC $ila_clk \
                               SYSTEM_ILA "Auto" APC_EN "0"}
    }
    apply_bd_automation -rule xilinx.com:bd_rule:debug -dict $autodict

    # The automation inserts the System ILAs but does not honour CLK_SRC here,
    # leaving /system_ila_*/clk floating. That surfaces at validation as
    # "clock pins are not connected to a valid clock source" naming a cell this
    # script never created, which reads like a fault in the design rather than
    # in automation that half-finished. Connect them explicitly.
    foreach ila [get_bd_cells -quiet -filter {NAME =~ "system_ila*"}] {
        set cp [get_bd_pins -quiet $ila/clk]
        if {$cp ne "" && [get_bd_nets -quiet -of_objects $cp] eq ""} {
            connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] $cp
            puts " ILA: connected [get_property NAME $ila]/clk"
        }
        set rp [get_bd_pins -quiet $ila/resetn]
        if {$rp ne "" && [get_bd_nets -quiet -of_objects $rp] eq ""} {
            connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] $rp
            puts " ILA: connected [get_property NAME $ila]/resetn"
        }
    }
    # Depth and storage qualification are BUILD-time options on a System ILA:
    # CONTROL.CAPTURE_MODE and CONTROL.DATA_DEPTH are read-only at run time.
    # The defaults give 1024 samples with no qualification, which at 187.5 MHz
    # is 5.5 us and captured exactly one read transfer -- useless against a
    # fault whose history spans milliseconds. Storing only completed read
    # transfers turns the buffer into 1024+ reads instead of 1024 cycles.
    foreach ila [get_bd_cells -quiet -filter {NAME =~ "system_ila*"}] {
        set_property -dict [list CONFIG.C_DATA_DEPTH {4096} \
                                 CONFIG.C_EN_STRG_QUAL {1} \
                                 CONFIG.C_ADV_TRIGGER {true}] $ila
        puts " ILA: [get_property NAME $ila] depth=4096 storage-qualified"
    }
    puts " ILA: [llength $marked] AXI interfaces instrumented"
}

add_files -fileset constrs_1 -norecurse $script_dir/constraints/pins.xdc

ch12_finish $proj_dir $proj_name $bd_name $out_dir camera_sobel 12

puts " variant: $variant   ($filter_vlnv)"
puts " packer:  $packer_vlnv"
exit
