# ---------------------------------------------------------------------------
# The Zynq UltraScale+ PS, configured the same way in all three projects
# ---------------------------------------------------------------------------
# ch13_add_ps <pl0_mhz> ?<pl1_mhz>? ?<pl2_mhz>? ?<need_irq1>?
#
#   Adds zynq_ultra_ps_e_0 with the board preset applied, then overrides the
#   ports and clocks each project needs. A frequency of 0 leaves that PL clock
#   disabled.
#
# The board preset is what configures the DDR controller for the AUP-ZU3's
# memory. Everything below is on top of it, never instead of it.
#
# Why three clocks rather than one. Project 2 has a single 200 MHz domain and
# is done. Projects 1 and 3 cannot be, because two of the three numbers are not
# ours to choose:
#
#   PL0  100 MHz  AXI4-Lite control, and the input to the CSI-2 subsystem's
#                 clk_wiz, which multiplies it to the 200 MHz the D-PHY wants
#   PL1  300 MHz  video_aclk. AMD's number for the camera datapath -- the
#                 CSI-2 subsystem, demosaic, gamma LUT and CSC in the base
#                 overlay are all configured for it
#   PL2  200 MHz  the accelerator. The HLS kernel targets 5 ns and CH11
#                 measured the RTL at 229 MHz Fmax out of context, so running
#                 the filter on the 300 MHz video clock is not an option
#
# So project 3 genuinely needs three, and the accelerator sits in its own
# domain with SmartConnects doing the crossing.

# ---------------------------------------------------------------------------
# The PS-PL port widths have to match the image the board BOOTED with
# ---------------------------------------------------------------------------
# psu_init sets the PS-PL AXI master port widths once, at boot, in
# FPD_SLCR.AFI_FS (0xFD615000) and LPD_SLCR.AFI_FS (0xFF419000). Loading a
# bitstream does not revisit them -- PYNQ reprograms the fabric and the PL
# clocks and stops there. So a design whose PS block is configured for a
# different width than the booting image comes up with a PL driving one width
# into a port expecting another, and every transaction on that port dies.
#
# On ZynqMP there is no bus timeout, so "dies" means the issuing master hangs
# forever. The CPU stops with no panic and no console output; the board looks
# powered and is unrecoverable without pulling the plug. It cost four crashed
# boards to find once, which is three more than it should ever cost again.
#
# These are the values a stock PYNQ image for this board boots with, taken from
# base.hwh in the AUP-ZU3 checkout. Compare, do not assume: if AMD change the
# base overlay, this check is what tells you.
set ch13_boot_port_widths {
    PSU__MAXIGP0__DATA_WIDTH 128
    PSU__MAXIGP1__DATA_WIDTH 128
    PSU__MAXIGP2__DATA_WIDTH 32
}

proc ch13_check_ps_ports {} {
    global ch13_boot_port_widths
    set ps [get_bd_cells zynq_ultra_ps_e_0]
    set bad 0
    foreach {prop want} $ch13_boot_port_widths {
        # Only the ports this design actually drives can break anything.
        set gp [string range $prop 11 11]
        if {[get_property CONFIG.PSU__USE__M_AXI_GP$gp $ps] ne "1"} { continue }
        set got [get_property CONFIG.$prop $ps]
        if {$got ne $want} {
            puts "ERROR: $prop is $got, but the board boots with $want."
            incr bad
        }
    }
    if {$bad} {
        error "PS-PL master port width does not match the booting image.\
               psu_init runs once at boot and a bitstream load does not\
               revisit it, so this design would hang the first time anything\
               touched that port's aperture -- with no panic and no console\
               output. See the note above ch13_boot_port_widths."
    }
    puts " PS-PL master port widths match the booting image"
}

proc ch13_add_ps {pl0_mhz {pl1_mhz 0} {pl2_mhz 0} {need_irq1 0} {hp_ports {0 1}}} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]

    # HPM0_LPD carries AXI4-Lite control traffic. The HP slave ports carry the
    # DDR traffic, and which ones exist is per project -- enabling one that
    # nothing connects to fails validation with
    #   ERROR [BD 41-758] clock pins are not connected to a valid clock source
    # naming its aclk, which is a confusing way to be told about an unused
    # port. 128-bit because that is what the interconnect presents to DDR; the
    # accelerator itself is 32-bit and the width conversion happens on the way.
    #
    # HP0..HP3 are SAXIGP2..SAXIGP5 in the PS configuration's names.
    set cfg [list \
        CONFIG.PSU__USE__M_AXI_GP0 {0} \
        CONFIG.PSU__USE__M_AXI_GP1 {0} \
        CONFIG.PSU__USE__M_AXI_GP2 {1} \
        CONFIG.PSU__MAXIGP2__DATA_WIDTH {32} \
        CONFIG.PSU__FPGA_PL0_ENABLE {1} \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $pl0_mhz \
    ]

    foreach hp $hp_ports {
        set gp [expr {$hp + 2}]
        lappend cfg CONFIG.PSU__USE__S_AXI_GP$gp {1}
        lappend cfg CONFIG.PSU__SAXIGP${gp}__DATA_WIDTH {128}
    }

    if {$pl1_mhz > 0} {
        lappend cfg CONFIG.PSU__FPGA_PL1_ENABLE {1}
        lappend cfg CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ $pl1_mhz
        if {$pl2_mhz == 0} {
            # Asking for 300 MHz is not the same as getting it. The PL clocks
            # are integer divisions of one of the PS PLLs, and which PLL the
            # configurator picks depends on what else is being asked for:
            #
            #   PL0+PL1 only      PL1 -> RPLL at 1050 / 4  = 262.5 MHz
            #   PL0+PL1+PL2       PL1 -> RPLL at 1500 / 5  = 300.0 MHz
            #   PL1 pinned IOPLL  PL1 -> IOPLL 1500 / 5    = 300.0 MHz
            #
            # 262.5 MHz would very likely still work -- the camera datapath
            # needs about 44 MHz to keep up with the OV5647's 2-lane
            # 437.5 Mbps link -- but
            # it is 12.5% below what AMD configured the CSI-2 subsystem, the
            # demosaic and the CSC for, and shipping that by accident is not
            # the same as choosing it. Pinning the source makes 300 MHz
            # deterministic.
            #
            # Only when PL2 is unused: with PL2 in play, pinning PL1 to IOPLL
            # pushes PL2 down to 175 MHz, and leaving both on RPLL gives
            # 300 MHz and 187.5 MHz, which is the better pair.
            lappend cfg CONFIG.PSU__CRL_APB__PL1_REF_CTRL__SRCSEL {IOPLL}
        }
    }
    if {$pl2_mhz > 0} {
        lappend cfg CONFIG.PSU__FPGA_PL2_ENABLE {1}
        lappend cfg CONFIG.PSU__CRL_APB__PL2_REF_CTRL__FREQMHZ $pl2_mhz
    }
    if {$need_irq1} {
        # The camera's I2C controller interrupts the PS on pl_ps_irq1[0].
        # That is SPI 136, which the device-tree overlay declares as <0 104 4>
        # -- the GIC binding counts SPIs from 32. Wire it anywhere else and
        # Linux's xiic driver waits for an interrupt that never arrives.
        lappend cfg CONFIG.PSU__USE__IRQ1 {1}
    }

    set_property -dict $cfg [get_bd_cells zynq_ultra_ps_e_0]

    # Report what we actually got, and refuse a large miss. A PL clock that
    # comes out 12.5% low does not fail anything downstream -- it just quietly
    # makes every frequency in the chapter wrong -- so it has to be checked
    # here or not at all.
    set ps [get_bd_cells zynq_ultra_ps_e_0]
    foreach {n want} [list 0 $pl0_mhz 1 $pl1_mhz 2 $pl2_mhz] {
        if {$want <= 0} { continue }
        set act [get_property CONFIG.PSU__CRL_APB__PL${n}_REF_CTRL__ACT_FREQMHZ $ps]
        set src [get_property CONFIG.PSU__CRL_APB__PL${n}_REF_CTRL__SRCSEL $ps]
        puts [format "  PL%d: requested %s MHz, got %.3f MHz from %s" \
              $n $want $act $src]
        if {abs($act - $want) / double($want) > 0.10} {
            error "PL$n came out at $act MHz against a request of $want MHz.\
                   More than 10% off -- see the PLL note in common/ps_config.tcl."
        }
    }
}

# ---------------------------------------------------------------------------
# ch13_connect_filter <cell>
#
#   Control on HPM0_LPD, gmem0 on HP0, gmem1 on HP1 -- one SmartConnect each,
#   which is what CH11 used and what the HLS build produces on its own.
# ---------------------------------------------------------------------------
proc ch13_connect_filter {cell} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
        Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_LPD} Slave "/$cell/s_axi_control" \
        intc_ip {New AXI SmartConnect} master_apm {0}] \
        [get_bd_intf_pins $cell/s_axi_control]

    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
        Master "/$cell/m_axi_gmem0" Slave {/zynq_ultra_ps_e_0/S_AXI_HP0_FPD} \
        intc_ip {New AXI SmartConnect} master_apm {0}] \
        [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
        Master "/$cell/m_axi_gmem1" Slave {/zynq_ultra_ps_e_0/S_AXI_HP1_FPD} \
        intc_ip {New AXI SmartConnect} master_apm {0}] \
        [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP1_FPD]
}

# ---------------------------------------------------------------------------
# ch13_finish <proj_dir> <proj_name> <bd_name> <out_dir> <basename> <jobs>
#
#   Wrapper, implementation, and the two files PYNQ actually needs.
# ---------------------------------------------------------------------------
proc ch13_finish {proj_dir proj_name bd_name out_dir basename jobs} {
    # Before anything expensive: a design whose PS-PL port widths disagree with
    # the booting image builds, routes and closes timing perfectly and then
    # hangs the board. Fail here instead, where it costs seconds.
    ch13_check_ps_ports
    assign_bd_address
    validate_bd_design
    save_bd_design

    make_wrapper -files [get_files \
        $proj_dir/${proj_name}.srcs/sources_1/bd/${bd_name}/${bd_name}.bd] -top
    add_files -norecurse \
        $proj_dir/${proj_name}.gen/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v
    set_property top ${bd_name}_wrapper [current_fileset]
    update_compile_order -fileset sources_1

    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1

    set bit_src [glob -nocomplain $proj_dir/${proj_name}.runs/impl_1/*_wrapper.bit]
    set hwh_src $proj_dir/${proj_name}.gen/sources_1/bd/${bd_name}/hw_handoff/${bd_name}.hwh

    if {[llength $bit_src] == 0 || ![file exists $hwh_src]} {
        error "Build finished but artifacts are missing -- check impl_1"
    }

    file mkdir $out_dir
    file copy -force [lindex $bit_src 0] $out_dir/${basename}.bit
    file copy -force $hwh_src            $out_dir/${basename}.hwh

    # PYNQ matches a device-tree overlay to a bitstream by basename, and the
    # .hwh has to sit beside the .bit for register_map to exist at all.
    puts "=========================================="
    puts " artifacts:"
    puts "   $out_dir/${basename}.bit"
    puts "   $out_dir/${basename}.hwh"
    puts "=========================================="
}
