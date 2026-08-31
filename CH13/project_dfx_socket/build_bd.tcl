# ===========================================================================
# CH13 -- one socket, many accelerators, no reboot
# ===========================================================================
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   vivado -mode batch -source project_dfx_socket/build_bd.tcl
#
# Options, after -tclargs:
#   stage1      build the static design with ONE fixed RM and stop. No
#               partition, no partials -- an ordinary overlay. This is the
#               staged bring-up the plan asks for: prove the socket answers
#               before enabling reconfiguration.
#
# Builds:
#   the static design, with the camera pipeline, the PS, the shutdown managers
#   and the status GPIO, and one Block Design Container for the socket
#   one partial bitstream per reconfigurable module
#
# The static region is CH12 project 3's design. That is not laziness: the
# camera's MIPI lanes and I2C are physical pins, so the camera cannot be in the
# reconfigurable partition, and what CH12 shipped as four projects and nine
# bitstreams becomes ONE design whose accelerator is chosen at run time.

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir .. common config.tcl]
source [file join $script_dir .. common package_rm.tcl]
source [file join $script_dir .. common ps_config.tcl]
source [file join $script_dir .. common mipi_hier.tcl]
source [file join $script_dir .. common dfx_socket.tcl]
source [file join $script_dir .. common dfx_static.tcl]

set stage1 0
foreach a [lrange $argv 0 end] {
    switch -- $a {
        stage1  { set stage1 1 }
        default { error "unknown option '$a' -- expected stage1" }
    }
}

set proj_name dfx_socket
set proj_dir  $script_dir/vivado
set bd_name   design_1
set out_dir   $script_dir/out
if {$stage1} {
    set proj_name dfx_socket_stage1
    set proj_dir  $script_dir/vivado_stage1
    set out_dir   $script_dir/out_stage1
}

# The RM that is in the socket when the full bitstream is loaded. Passthrough,
# deliberately: it is the RM that proves the socket itself independently of any
# filter, so if the board comes up wrong the question is not "which kernel".
set boot_rm passthrough

ch13_require_dir $ch13_board_repo "AUP-ZU3 board files"
ch13_require_dir $ch13_aup_zu3    "AUP-ZU3 PYNQ repo"

# Fail before anything is built if the kernel ids have drifted apart. The id is
# what proves a swap actually happened, so a driver whose copy no longer matches
# the hardware's compares two stale constants and accepts whatever is in the
# socket -- the one safeguard against loading the wrong partial stops working,
# and nothing looks wrong. See common/check_ids.py.
set check_ids [file join $script_dir .. common check_ids.py]
if {[catch {exec python3 $check_ids} out]} {
    puts $out
    error "kernel ids disagree across the RTL, the Tcl and the Python -- see above"
}
puts $out

# ---------------------------------------------------------------------------
# Package every RM as IP, one repo each -- ch13_rm_vlnv wipes what it is given.
# ---------------------------------------------------------------------------
set rm_repos {}
set rm_vlnvs {}
foreach name [ch13_rm_names] {
    set repo $script_dir/ip_repo_$name
    lassign [ch13_rm_vlnv $name $repo] vlnv r
    dict set rm_vlnvs $name $vlnv
    lappend rm_repos $r
    puts " packaged rm_$name -> $vlnv"
}

# ---------------------------------------------------------------------------
# The project
# ---------------------------------------------------------------------------
create_project $proj_name $proj_dir -part $ch13_part -force
set_property ip_repo_paths [concat $ch13_pynq_ip $rm_repos] [current_project]
update_ip_catalog -rebuild
set_property board_part_repo_paths [list $ch13_board_repo] [current_project]
set_property board_part $ch13_board_part [current_project]

# PR_FLOW must be on BEFORE the partition is defined. Turning it on afterwards
# leaves a project that looks configured and builds a flat design.
if {!$stage1} {
    set_property PR_FLOW 1 [current_project]
}

# ---------------------------------------------------------------------------
# The socket's child block designs -- one per RM, identical boundaries
# ---------------------------------------------------------------------------
foreach name [ch13_rm_names] {
    ch13_create_socket_bd $name [dict get $rm_vlnvs $name]
    puts " socket BD: socket_$name"
}

# ---------------------------------------------------------------------------
# The static design
# ---------------------------------------------------------------------------
create_bd_design $bd_name
current_bd_design [get_bd_designs $bd_name]

# Three clocks, none of them a free choice -- see ch13_add_ps.
# HP0 for the camera VDMA, HP1 and HP2 for the socket's two ports.
ch13_add_ps 100 $ch13_video_mhz $ch13_socket_mhz 1 {0 1 2}

# HPM0_FPD carries the video IP control path at 300 MHz.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
] [get_bd_cells zynq_ultra_ps_e_0]

# A DEDICATED master for the socket's control path, clocked from the same PL
# clock the partition runs on. This is settled, by measurement, in CH12: an
# AXI4-Lite clock crossing on this path lost about one CTRL read in a thousand,
# and because AP_DONE is clear-on-read the lost read DESTROYED the completion
# rather than delaying it. A dedicated master at the partition's own clock took
# it to 0 in 8000 at full speed. See docs/ch13-plan.md 2.3.
#
# 128 bits because that is what the board boots with -- see the paragraph
# below, which applies to this port exactly as much.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP1 {1} \
    CONFIG.PSU__MAXIGP1__DATA_WIDTH {128} \
] [get_bd_cells zynq_ultra_ps_e_0]

# 128, and not the 32 the slaves behind it actually want. The PS-PL master port
# width is not part of the bitstream: it lives in FPD_SLCR.AFI_FS, which
# psu_init writes ONCE at boot from whatever design the board booted with. A
# design built with 32 here comes up driving a 32-bit interface into a PS port
# still configured for 128, every access to 0xA0000000 never completes, and
# because there is no bus timeout on ZynqMP the CPU wedges with no panic and no
# console. ch13_check_ps_ports fails the build if this drifts.

ch13_create_mipi_hier / mipi

# --- the socket ------------------------------------------------------------
# A Block Design Container, not a module reference. `create_partition_def` does
# not apply to a cell created as a plain module reference -- IPI's mechanism IS
# the BDC, and the partition definitions do not exist until generate_target has
# run, which during the spike looked like a silent failure.
create_bd_cell -type container -reference socket_$boot_rm socket
if {!$stage1} {
    # The active source has to be FIRST in the list, and it has to still be in
    # the list at all -- setting LIST_SYNTH_BD to something that omits the
    # container's current active source is rejected with a message about
    # removing it, which reads like a bug in the tool rather than in the list.
    set synth_list [list socket_$boot_rm]
    foreach n [ch13_rm_names] {
        if {$n ne $boot_rm} { lappend synth_list socket_$n }
    }
    set_property CONFIG.ENABLE_DFX {true} [get_bd_cells socket]
    puts " LIST_SYNTH_BD before: '[get_property CONFIG.LIST_SYNTH_BD [get_bd_cells socket]]'"
    # The property holds FILE names, not design names: the error when it does
    # not is about being unable to remove the active source, which reads like a
    # tool bug rather than a missing extension.
    set synth_files {}
    foreach n $synth_list { lappend synth_files $n.bd }
    puts " LIST_SYNTH_BD: [join $synth_files :]"
    set_property CONFIG.LIST_SYNTH_BD [join $synth_files :] [get_bd_cells socket]
    puts " LIST_SYNTH_BD after:  '[get_property CONFIG.LIST_SYNTH_BD [get_bd_cells socket]]'"
}

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

# The socket's whole datapath -- both DDR ports, the PS slave ports they land
# on, the shutdown managers and the SmartConnects -- runs at one clock, and so
# does its AXI4-Lite control path via the dedicated master. NOTHING on the
# socket's path crosses a clock domain. That is the CH12 result made
# structural: see docs/ch13-plan.md 2.3.
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] \
    [get_bd_pins rst_accel/slowest_sync_clk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp1_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp2_fpd_aclk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins mipi/aux_reset_in] \
    [get_bd_pins rst_lite/ext_reset_in] \
    [get_bd_pins rst_accel/ext_reset_in]

connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins mipi/lite_aresetn]

# The partition gets its OWN reset controller, and that is not tidiness.
#
# Software must be able to hold the partition in reset across a swap:
# RESET_AFTER_RECONFIG releases it on its own, but the sequence needs the
# partition quiet from before the partial lands until after it is checked. The
# obvious way -- AND the GPIO's bit with rst_accel and call it ap_rst_n -- is
# wrong twice over:
#
#   * it crosses pl_clk0 to pl_clk2 with no synchroniser, on a net that fans
#     out to every flip-flop in the partition. That was 1369 failing endpoints
#     against a 0.336 ns requirement.
#   * holding the partition in reset that way would also have to leave
#     rst_accel alone, or the shutdown managers isolating the partition would
#     themselves be reset -- and they are the only thing keeping the rest of the
#     system safe while the partition is gone.
#
# proc_sys_reset takes the software bit on aux_reset_in and produces a reset
# SYNCHRONOUS to pl_clk2, asserted asynchronously and released synchronously,
# which is what a reset crossing domains is supposed to look like. rst_accel
# keeps running the shutdown managers and the SmartConnects throughout.
ch13_add_dfx_gpio dfx_ctrl
ch13_add_slice slice_shutdown 2 0 0
ch13_add_slice slice_rm_resetn 2 1 1
connect_bd_net [get_bd_pins dfx_ctrl/gpio_io_o] [get_bd_pins slice_shutdown/Din]
connect_bd_net [get_bd_pins dfx_ctrl/gpio_io_o] [get_bd_pins slice_rm_resetn/Din]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_socket
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2]  [get_bd_pins rst_socket/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_socket/ext_reset_in]
connect_bd_net [get_bd_pins slice_rm_resetn/Dout]       [get_bd_pins rst_socket/aux_reset_in]
connect_bd_net [get_bd_pins rst_socket/peripheral_aresetn] [get_bd_pins socket/ap_rst_n]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2]  [get_bd_pins socket/ap_clk]

# request_shutdown goes the other way across the same boundary. One bit, but it
# gates three shutdown managers, so it gets a real synchroniser rather than a
# hopeful one.
ch13_add_cdc cdc_shutdown 1 10000 5333
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins cdc_shutdown/src_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] [get_bd_pins cdc_shutdown/dest_clk]
connect_bd_net [get_bd_pins slice_shutdown/Dout]       [get_bd_pins cdc_shutdown/src_in]

# --- shutdown managers on every interface crossing the boundary -------------
ch13_add_shutdown sdm_ctrl  false AXI4LITE 32 32
ch13_add_shutdown sdm_gmem0 true  AXI4MM   64 32
ch13_add_shutdown sdm_gmem1 true  AXI4MM   64 32
foreach sdm {sdm_ctrl sdm_gmem0 sdm_gmem1} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2]    [get_bd_pins $sdm/clk]
    connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins $sdm/resetn]
    connect_bd_net [get_bd_pins cdc_shutdown/dest_out]        [get_bd_pins $sdm/request_shutdown]
}

# --- interrupts -------------------------------------------------------------
# The socket's interrupt is gated by the partition's reset. While the partition
# is held in reset its interrupt line means nothing, and an ungated one during
# a swap is a spurious interrupt into an enabled controller.
# Gated by the SYNCHRONISED reset, in the partition's own clock domain, rather
# than by the raw GPIO bit from the other domain.
ch13_add_and2 irq_gate
connect_bd_net [get_bd_pins socket/interrupt]              [get_bd_pins irq_gate/Op1]
connect_bd_net [get_bd_pins rst_socket/peripheral_aresetn] [get_bd_pins irq_gate/Op2]

connect_bd_net [get_bd_pins mipi/iic2intc_irpt] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property CONFIG.NUM_PORTS {3} [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins mipi/csirxss_csi_irq] [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins mipi/s2mm_introut]    [get_bd_pins xlconcat_0/In1]
# The socket's interrupt is wired but unused: the driver polls AP_DONE, because
# a frame takes single-digit milliseconds and an interrupt round trip through
# the kernel costs more than it saves. Connected so a reader who wants to try
# the other way does not have to rebuild.
connect_bd_net [get_bd_pins irq_gate/Res]         [get_bd_pins xlconcat_0/In2]

# PYNQ needs the interrupt controller even though nothing here uses interrupts.
# It attributes an interrupt to an IP by tracing it to an AXI Interrupt
# Controller and reading which input the signal lands on; with a bare concat
# there is nothing to trace to, `axi_vdma` gets no `interrupts` entry, and
# AxiVDMA.__init__ dies on an unconditional self.s2mm_introut.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0
set_property -dict [list \
    CONFIG.C_IRQ_CONNECTION {1} \
    CONFIG.C_HAS_FAST {0} \
    CONFIG.C_KIND_OF_INTR {0xFFFFFFF8} \
] [get_bd_cells axi_intc_0]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins axi_intc_0/intr]
connect_bd_net [get_bd_pins axi_intc_0/irq]  [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# --- the status inputs ------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 status_concat
set_property CONFIG.NUM_PORTS {4} [get_bd_cells status_concat]
connect_bd_net [get_bd_pins socket/heartbeat]    [get_bd_pins status_concat/In0]
connect_bd_net [get_bd_pins sdm_ctrl/in_shutdown]  [get_bd_pins status_concat/In1]
connect_bd_net [get_bd_pins sdm_gmem0/in_shutdown] [get_bd_pins status_concat/In2]
connect_bd_net [get_bd_pins sdm_gmem1/in_shutdown] [get_bd_pins status_concat/In3]
# And back the other way. All four status bits originate at pl_clk2 and are
# read by a GPIO at pl_clk0, so they cross too. The heartbeat especially: its
# whole job is to be sampled from the other domain.
ch13_add_cdc cdc_status 4 5333 10000
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] [get_bd_pins cdc_status/src_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins cdc_status/dest_clk]
connect_bd_net [get_bd_pins status_concat/dout]        [get_bd_pins cdc_status/src_in]
connect_bd_net [get_bd_pins cdc_status/dest_out]       [get_bd_pins dfx_ctrl/gpio2_io_i]

# --- AXI4-Lite control path -------------------------------------------------
# Every port of this interconnect runs at 100 MHz, and the socket is NOT on it.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 lite_periph
set_property -dict [list CONFIG.NUM_MI {5} CONFIG.NUM_SI {1}] [get_bd_cells lite_periph]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] [get_bd_intf_pins lite_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M00_AXI] [get_bd_intf_pins mipi/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M01_AXI] [get_bd_intf_pins mipi/csirxss_s_axi]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M02_AXI] [get_bd_intf_pins mipi/S_AXI]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M03_AXI] [get_bd_intf_pins axi_intc_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins lite_periph/M04_AXI] [get_bd_intf_pins dfx_ctrl/S_AXI]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_intc_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins axi_intc_0/s_axi_aresetn]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins dfx_ctrl/s_axi_aclk]
connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins dfx_ctrl/s_axi_aresetn]
foreach p {ACLK S00_ACLK M00_ACLK M01_ACLK M02_ACLK M03_ACLK M04_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins lite_periph/$p]
}
foreach p {ARESETN S00_ARESETN M00_ARESETN M01_ARESETN M02_ARESETN M03_ARESETN M04_ARESETN} {
    connect_bd_net [get_bd_pins rst_lite/peripheral_aresetn] [get_bd_pins lite_periph/$p]
}

# The socket's own control path: dedicated master -> SmartConnect -> shutdown
# manager -> the partition. One clock throughout, so nothing crosses.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ctrl
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells sc_ctrl]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM1_FPD] [get_bd_intf_pins sc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctrl/M00_AXI]  [get_bd_intf_pins sdm_ctrl/S_AXI]
connect_bd_intf_net [get_bd_intf_pins sdm_ctrl/M_AXI]   [get_bd_intf_pins socket/s_axi_control]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] \
    [get_bd_pins sc_ctrl/aclk] [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]
connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins sc_ctrl/aresetn]

# --- DDR paths ---------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins mipi/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins mipi/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# One SmartConnect per socket port, single-clock. Separate rather than shared
# so a read burst and a write burst never arbitrate against each other -- the
# RMs issue both continuously and are DDR-bound.
foreach {sc sdm port slave} {
    sc_gmem0 sdm_gmem0 m_axi_gmem0 S_AXI_HP1_FPD
    sc_gmem1 sdm_gmem1 m_axi_gmem1 S_AXI_HP2_FPD
} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 $sc
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells $sc]
    connect_bd_intf_net [get_bd_intf_pins socket/$port] [get_bd_intf_pins $sdm/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins $sdm/M_AXI]   [get_bd_intf_pins $sc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI]  [get_bd_intf_pins zynq_ultra_ps_e_0/$slave]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] [get_bd_pins $sc/aclk]
    connect_bd_net [get_bd_pins rst_accel/peripheral_aresetn] [get_bd_pins $sc/aresetn]
}

# --- addresses ---------------------------------------------------------------
# AMD's addresses for the camera, and the IIC one is load bearing: the device
# tree declares the I2C controller at 0x80140000 and PYNQ's camera driver finds
# the camera's bus through the label on that node.

# The socket's two DDR masters, assigned EXPLICITLY and FIRST.
#
# Left to the automatic pass they are excluded outright:
#   CRITICAL WARNING [BD 41-2933] Excluding slave segment
#   '/zynq_ultra_ps_e_0/SAXIGP3/HP1_DDR_LOW' ... The proposed address
#   '0x44A0_0000 [ 950M ]' is misaligned.
# and an excluded segment is not a warning about tidiness -- it is a master
# with no path to DDR at all, which builds cleanly and then reads zeroes on
# hardware. CH12's design assigns the same two segments at 0x00000000 over 2G,
# so that is what these get.
foreach {space slave} {
    /socket/rm_inst/m_axi_gmem0 zynq_ultra_ps_e_0/SAXIGP3/HP1_DDR_LOW
    /socket/rm_inst/m_axi_gmem1 zynq_ultra_ps_e_0/SAXIGP4/HP2_DDR_LOW
} {
    set sg [get_bd_addr_segs -quiet $slave]
    if {$sg eq ""} { error "no such slave segment: $slave" }
    assign_bd_address -target_address_space $space $sg -offset 0x00000000 -range 2G -force
    puts " $space -> $slave at 0x00000000 [ 2G ]"
}

# Now everything else. The two masters above are already assigned, so the
# automatic pass leaves them alone rather than proposing a misaligned range and
# excluding them.
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
set_property offset $ch13_dfx_ctrl_base [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_dfx_ctrl_Reg}]


# --- the socket's aperture --------------------------------------------------
# Declared, not inferred, and declared AFTER the static addresses are settled.
# The DFX addressing pass assigns anything still unassigned, so running it
# first lets it take 0x80000000 for the camera's CSI-2 subsystem and then the
# explicit offsets below collide with it.
#
# See ch13_socket_base in common/config.tcl for why DFX requires an aperture at
# all: the static region's decode is routed once, so every RM has to decode the
# same range, and Vivado will not infer that from the RMs.
# SEG_rm_inst_Reg, not SEG_socket_Reg: the segment is named after the instance
# INSIDE the child block design, not after the container. That is the concrete
# reason ch13_create_socket_bd names every RM's instance `rm_inst` -- if the
# name varied per RM, this lookup, and anything else that walks the address
# map, would change under a swap.
set seg [get_bd_addr_segs -quiet {zynq_ultra_ps_e_0/Data/SEG_rm_inst_Reg}]
if {$seg eq ""} {
    puts "address segments actually present:"
    foreach a [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/Data/*] { puts "  [get_property NAME $a]" }
    error "the socket has no address segment -- did the container get an s_axi_control?"
}
set_property offset $ch13_socket_base $seg
puts " socket control port at $ch13_socket_base ([get_property NAME $seg])"

set_property APERTURES [list [list $ch13_socket_base $ch13_socket_range]] \
    [get_bd_intf_pins socket/s_axi_control]
if {!$stage1} {
    validate_bd_design -assign_dfx_addressing
}

# Re-assign the socket's DDR masters, and then CHECK.
#
# validate_bd_design -assign_dfx_addressing re-derives the master address
# spaces and excludes these two again, even though they were explicitly
# assigned before it ran:
#
#   CRITICAL WARNING [BD 41-2933] Excluding slave segment
#   '/zynq_ultra_ps_e_0/SAXIGP3/HP1_DDR_LOW' ... '0x44A0_0000 [ 950M ]' is
#   misaligned
#
# so the assignment has to come after it as well as before -- before, so the
# automatic pass does not propose the misaligned range in the first place;
# after, because the DFX pass undoes it regardless.
#
# The check reads the OFFSET rather than asking whether a segment is listed. An
# EXCLUDED segment is still listed against the address space -- it simply has
# no address -- so a presence test passes on a design whose accelerator cannot
# reach memory at all. That design builds cleanly, programs cleanly, and reads
# zeroes.
foreach {space slave} {
    /socket/rm_inst/m_axi_gmem0 zynq_ultra_ps_e_0/SAXIGP3/HP1_DDR_LOW
    /socket/rm_inst/m_axi_gmem1 zynq_ultra_ps_e_0/SAXIGP4/HP2_DDR_LOW
} {
    set sg [get_bd_addr_segs -quiet $slave]
    assign_bd_address -target_address_space $space $sg -offset 0x00000000 -range 2G -force
}
foreach {space slave} {
    /socket/rm_inst/m_axi_gmem0 HP1_DDR_LOW
    /socket/rm_inst/m_axi_gmem1 HP2_DDR_LOW
} {
    set seg ""
    foreach g [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $space]] {
        if {[string match *$slave* [get_property NAME $g]]} { set seg $g }
    }
    if {$seg eq ""} { error "$space has no $slave segment at all" }
    set off [get_property -quiet OFFSET $seg]
    set rng [get_property -quiet RANGE $seg]
    if {$off eq "" || $rng eq ""} {
        error "$space cannot reach $slave -- the segment is EXCLUDED (no offset)"
    }
    puts [format " %s -> %s at %s range %s" $space $slave $off $rng]
}

ch13_check_ps_ports

validate_bd_design
save_bd_design

make_wrapper -files [get_files $proj_dir/$proj_name.srcs/sources_1/bd/$bd_name/$bd_name.bd] -top
add_files -norecurse $proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v
set_property top ${bd_name}_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse $script_dir/constraints/pins.xdc

# generate_target BEFORE anything asks about partitions. Until this has run,
# get_partition_defs returns empty and it looks like the container was ignored.
generate_target all [get_files $proj_dir/$proj_name.srcs/sources_1/bd/$bd_name/$bd_name.bd]

puts ""
puts "=== partition definitions ==="
foreach pd [get_partition_defs -quiet] {
    puts "  [get_property NAME $pd]"
    foreach rm [get_reconfig_modules -quiet -of_objects $pd] {
        puts "    RM: [get_property NAME $rm]"
    }
}
puts ""

update_compile_order -fileset sources_1
puts "BUILD_BD_DONE"
