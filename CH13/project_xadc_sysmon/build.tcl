# ===========================================================================
# CH13 -- the SYSMON: on-chip temperature, supply rails, and a pot on VP/VN
# ===========================================================================
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   vivado -mode batch -source project_xadc_sysmon/build.tcl
#
# Options, after -tclargs:
#   bd_only     build and validate the block design, then stop. No synthesis.
#               Use it to check the wizard's configuration in seconds rather
#               than in twenty minutes.
#
# On UltraScale+ the block the 7-series calls XADC is SYSMONE4, and it is
# reached through the System Management Wizard rather than the XADC Wizard.
# The AUP-ZU3 wires a 10K potentiometer to the dedicated analog pins VP (R13)
# and VN (T12), which is SYSMON channel 3.
#
# THE DRP WINDOW IS AT 0x1400, NOT 0x200
#
# 0x200 is the 7-SERIES XADC Wizard's DRP base. This IP's AXI window is 13 bits
# wide -- 8 KB -- and puts the DRP at 0x1400 (aliased at 0x1C00; address bit 11
# is ignored). Reads at 0x200 land on nothing and come back as zeros, which is
# indistinguishable from a SYSMON that is present, placed and not converting.
#
# It was diagnosed as exactly that, wrongly, for most of a day: the board's own
# base overlay fails the same way and Linux's xilinx-ams reports in_temp20_raw
# = 0 for the PL, so there was no shortage of corroborating evidence for the
# wrong conclusion. What settled it was hdl/sysmon_activity.sv, which counts
# the macro's own eoc pin in fabric -- a path that shares nothing with the DRP
# or with the PS AMS block. It showed ~5400 conversions a second while every
# register still read zero.
#
# When a whole register window reads zero, question the ADDRESS before
# concluding the hardware is dead, and verify any suspected map against values
# known independently. Here VCCINT had to be 0.85 V and VCCAUX 1.80 V, which
# the PS sensors had been reporting correctly the whole time.
#
# WHAT THIS DESIGN CONTAINS
#
#   the System Management Wizard, AXI4-Lite at 0x80000000
#   sysmon_activity  -- counts eoc/eos/channel in fabric, GPIO at 0x80010000
#   pot_bar          -- the pot as an 8-LED thermometer, GPIO at 0x80020000
#
# The activity counter stays in the design rather than being deleted with the
# bug it found. It is the only thing that can distinguish "the SYSMON is dead"
# from "you are reading the wrong address", and that distinction cost a day.
# ===========================================================================

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir .. common config.tcl]
source [file join $script_dir .. common ps_config.tcl]

set bd_only 0
foreach a [lrange $argv 0 end] {
    switch -- $a {
        bd_only { set bd_only 1 }
        default { error "unknown option '$a' -- expected bd_only" }
    }
}

set proj_name xadc_sysmon
set proj_dir  $script_dir/vivado
set bd_name   design_1
set out_dir   $script_dir/out

# Where the wizard's AXI4-Lite control port lives. The first valid aperture
# through M_AXI_HPM0_LPD, and clear of the addresses the other CH13 projects
# use, so both can be on the board without confusion.
set sysmon_base  0x80000000
set sysmon_range 64K

# The activity counter's GPIO. Deliberately a SEPARATE aperture from the
# sysmon's: it has to stay readable when the sysmon is not, because "the
# sysmon tells us nothing" is precisely the case it exists to report on.
set activity_base 0x80010000

# The output GPIO that carries the pot's level to the LED bar decoder.
set pot_gpio_base 0x80020000

file mkdir $out_dir
file delete -force $proj_dir

create_project $proj_name $proj_dir -part $ch13_part -force
set_property board_part_repo_paths $ch13_board_repo [current_project]
set_property board_part $ch13_board_part [current_project]

# The activity counter, and the LED pins it drives. Pin constraints live in
# constraints/pins.xdc and never in the source, per the project's rules.
add_files -norecurse [list \
    [file join $ch13_root SystemVerilog hdl sysmon_activity.sv] \
    [file join $ch13_root SystemVerilog hdl sysmon_activity_wrapper.v] \
    [file join $ch13_root SystemVerilog hdl pot_bar.sv] \
    [file join $ch13_root SystemVerilog hdl pot_bar_wrapper.v]]
add_files -fileset constrs_1 -norecurse [file join $script_dir constraints pins.xdc]
update_compile_order -fileset sources_1

create_bd_design $bd_name

# ---------------------------------------------------------------------------
# The PS
# ---------------------------------------------------------------------------
# 100 MHz on PL0 and nothing else: no PL1, no PL2, no HP slave ports. The
# SYSMON needs one clock for its AXI4-Lite port, and DCLK is derived from it.
#
# The empty hp_ports list matters -- enabling an HP slave that nothing drives
# fails validation with a message about an unconnected aclk, which is a
# confusing way to be told about an unused port. See common/ps_config.tcl.
ch13_add_ps 100 0 0 0 {}
ch13_check_ps_ports

# ---------------------------------------------------------------------------
# The SYSMON
# ---------------------------------------------------------------------------
# Every value below is set explicitly even where it matches the IP default,
# because the whole point of this project is that a SYSMON configuration
# cannot be assumed to work -- an inherited default is not a decision.
#
# SEQUENCER_MODE Continuous with TIMING_MODE Continuous is what makes the
# block free-run through its enabled channels; software then just reads the
# most recent result out of a status register. The alternative, Single
# Channel, would need software to trigger each conversion.
#
# BIPOLAR_VP_VN false is unipolar: VP is measured against VN over 0 to 1.0 V.
# That is the SYSMON's fixed external-input range and it is NOT adjustable --
# whatever the pot's divider does on the board has to land inside it, which
# is the first thing the hardware test measures.
#
# CHANNEL_AVERAGING 16 steadies the displayed bar. It averages in hardware,
# so it costs software nothing and does not slow the sequencer's rate per
# channel enough to matter here.
create_bd_cell -type ip -vlnv xilinx.com:ip:system_management_wiz sysmon
set_property -dict [list \
    CONFIG.INTERFACE_SELECTION           {Enable_AXI} \
    CONFIG.SEQUENCER_MODE                {Continuous} \
    CONFIG.TIMING_MODE                   {Continuous} \
    CONFIG.DCLK_FREQUENCY                {100} \
    CONFIG.ADC_CONVERSION_RATE           {200} \
    CONFIG.CHANNEL_AVERAGING             {16} \
    \
    CONFIG.CHANNEL_ENABLE_TEMPERATURE    {true} \
    CONFIG.CHANNEL_ENABLE_VCCINT         {true} \
    CONFIG.CHANNEL_ENABLE_VCCAUX         {true} \
    CONFIG.CHANNEL_ENABLE_VBRAM          {true} \
    CONFIG.CHANNEL_ENABLE_VCCPSINTLP     {true} \
    CONFIG.CHANNEL_ENABLE_VCCPSINTFP     {true} \
    CONFIG.CHANNEL_ENABLE_VCCPSAUX       {true} \
    CONFIG.CHANNEL_ENABLE_VP_VN          {true} \
    CONFIG.BIPOLAR_VP_VN                 {false} \
    \
    CONFIG.AVERAGE_ENABLE_TEMPERATURE    {true} \
    CONFIG.AVERAGE_ENABLE_VCCINT         {true} \
    CONFIG.AVERAGE_ENABLE_VCCAUX         {true} \
    CONFIG.AVERAGE_ENABLE_VBRAM          {true} \
    CONFIG.AVERAGE_ENABLE_VCCPSINTLP     {true} \
    CONFIG.AVERAGE_ENABLE_VCCPSINTFP     {true} \
    CONFIG.AVERAGE_ENABLE_VCCPSAUX       {true} \
    CONFIG.AVERAGE_ENABLE_VP_VN          {true} \
    \
    CONFIG.OT_ALARM                      {true} \
    CONFIG.TEMPERATURE_ALARM_OT_TRIGGER  {125.0} \
    CONFIG.TEMPERATURE_ALARM_OT_RESET    {70.0} \
] [get_bd_cells sysmon]

# VP/VN leave the design as an external differential analog port.
#
# They are DEDICATED pins -- R13 and T12 on this package, PIN_FUNC VP and VN,
# IS_GENERAL_PURPOSE 0 -- so they take NO PACKAGE_PIN or IOSTANDARD
# constraint. Vivado places them on the only sites they can occupy. The
# board's own base.xdc constrains nothing for them either, which is the
# confirmation that this is intended rather than an omission.
make_bd_intf_pins_external [get_bd_intf_pins sysmon/Vp_Vn]
set_property name Vp_Vn [get_bd_intf_ports Vp_Vn_0]

# ---------------------------------------------------------------------------
# Asking whether the macro converts, without using the DRP
# ---------------------------------------------------------------------------
# The wizard brings the SYSMONE4's own status pins out to fabric. They pass
# through neither the DRP register path nor the PS AMS block -- the two paths
# that already report nothing on this board -- so they can answer a question
# neither of those can.
#
# The counting is done in fabric because eoc_out and eos_out are single-cycle
# pulses at 100 MHz: software polling a GPIO would miss essentially all of
# them and report a dead converter either way. See hdl/sysmon_activity.sv.
# References the Verilog wrapper, not the .sv: IP Integrator rejects a
# SystemVerilog file as the top of a module reference with
#   ERROR [filemgmt 56-195] ... type is not allowed as the top file
create_bd_cell -type module -reference sysmon_activity_wrapper activity

connect_bd_net [get_bd_pins sysmon/eoc_out]     [get_bd_pins activity/eoc_in]
connect_bd_net [get_bd_pins sysmon/eos_out]     [get_bd_pins activity/eos_in]
connect_bd_net [get_bd_pins sysmon/busy_out]    [get_bd_pins activity/busy_in]
connect_bd_net [get_bd_pins sysmon/channel_out] [get_bd_pins activity/channel_in]

# Two 32-bit input-only channels: the eoc counter, and the packed status word.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio activity_gpio
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH   {32} \
    CONFIG.C_ALL_INPUTS   {1} \
    CONFIG.C_IS_DUAL      {1} \
    CONFIG.C_GPIO2_WIDTH  {32} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] [get_bd_cells activity_gpio]

connect_bd_net [get_bd_pins activity/count_word]  [get_bd_pins activity_gpio/gpio_io_i]
connect_bd_net [get_bd_pins activity/status_word] [get_bd_pins activity_gpio/gpio2_io_i]

# ---------------------------------------------------------------------------
# The potentiometer as an eight-LED thermometer bar
# ---------------------------------------------------------------------------
# The value reaches the decoder from SOFTWARE, through an output GPIO, and
# that is forced rather than chosen: INTERFACE_SELECTION Enable_AXI gives the
# wizard's bridge ownership of the SYSMONE4's single DRP port, and there is
# only one, so fabric logic cannot read conversions out of the macro itself.
# The decode stays in hardware; only the transport goes through the PS.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio pot_gpio
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {16} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {0} \
] [get_bd_cells pot_gpio]

create_bd_cell -type module -reference pot_bar_wrapper bar
connect_bd_net [get_bd_pins pot_gpio/gpio_io_o] [get_bd_pins bar/level]

create_bd_port -dir O -from 7 -to 0 PL_USER_LED
connect_bd_net [get_bd_pins bar/leds] [get_bd_ports PL_USER_LED]

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_LPD} Slave {/sysmon/S_AXI_LITE} \
    intc_ip {New AXI SmartConnect} master_apm {0}] \
    [get_bd_intf_pins sysmon/S_AXI_LITE]

# The axi4 automation brings its own proc_sys_reset and connects pl_clk0 and
# pl_resetn0 to it. Adding one by hand as well fails with
#   WARNING [BD 41-395] all ports/pins are already connected to
#                       '/zynq_ultra_ps_e_0_pl_clk0'
#   ERROR   [BD 5-4]    Error: running connect_bd_net
# which reads like a connection problem but is really "this is already done".

# The GPIO joins the SmartConnect the sysmon automation already built, rather
# than getting one of its own.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_LPD} Slave {/activity_gpio/S_AXI} \
    intc_ip {/axi_smc} master_apm {0}] \
    [get_bd_intf_pins activity_gpio/S_AXI]

# The activity counter runs in the DCLK domain -- the same pl_clk0 that clocks
# the wizard's AXI port and the SYSMONE4's DCLK -- so its inputs are
# synchronous and need no synchroniser. Its reset is the proc_sys_reset's
# ACTIVE-HIGH peripheral_reset, matching the module's synchronous active-high
# convention; wiring the active-low peripheral_aresetn here would hold every
# counter at zero and look exactly like a dead converter.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_LPD} Slave {/pot_gpio/S_AXI} \
    intc_ip {/axi_smc} master_apm {0}] \
    [get_bd_intf_pins pot_gpio/S_AXI]

set rst_cell [get_bd_cells -filter {VLNV =~ *proc_sys_reset*}]
foreach cell {activity bar} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins $cell/clk]
    connect_bd_net [get_bd_pins $rst_cell/peripheral_reset] [get_bd_pins $cell/rst]
}

assign_bd_address -offset $sysmon_base -range $sysmon_range \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs sysmon/S_AXI_LITE/Reg] -force

assign_bd_address -offset $activity_base -range 64K \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs activity_gpio/S_AXI/Reg] -force

assign_bd_address -offset $pot_gpio_base -range 64K \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs pot_gpio/S_AXI/Reg] -force

validate_bd_design
save_bd_design

# Report what the wizard actually ended up with, so a silently-rejected
# CONFIG value shows up here rather than as a zero reading on the board.
puts "\n==> SYSMON configuration as built"
set smw [get_bd_cells sysmon]
foreach p {INTERFACE_SELECTION SEQUENCER_MODE TIMING_MODE CHANNEL_AVERAGING \
           CHANNEL_ENABLE_TEMPERATURE CHANNEL_ENABLE_VCCINT \
           CHANNEL_ENABLE_VP_VN BIPOLAR_VP_VN OT_ALARM} {
    puts [format "    %-32s %s" $p [get_property CONFIG.$p $smw]]
}
puts "    address                          $sysmon_base + $sysmon_range\n"

if {$bd_only} {
    puts "==> bd_only: block design validated, stopping before synthesis."
    exit 0
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
set bd_file [get_files $bd_name.bd]
make_wrapper -files $bd_file -top -import

# Set the top EXPLICITLY, and check it.
#
# add_files brought in sysmon_activity_wrapper.v before the block design
# existed, so update_compile_order elected THAT as the top -- nothing
# instantiated it yet -- and `make_wrapper -top` did not displace it. The build
# then ran `link_design -top sysmon_activity_wrapper`, quietly implementing the
# counter on its own with no PS, no sysmon and no bitstream worth having.
#
# It is caught downstream by the SYSMONE4 count, but only after a full
# synthesis and implementation. Cheaper to be explicit here.
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

set actual_top [get_property top [current_fileset]]
if {$actual_top ne "${bd_name}_wrapper"} {
    error "top is '$actual_top', expected '${bd_name}_wrapper'"
}
puts "==> top: $actual_top"

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation did not finish -- see $proj_dir/$proj_name.runs"
}

open_run impl_1

# The SYSMONE4 has to actually be in the implemented design. The vendor's
# overlay proves that placing it is not sufficient, but failing to place it
# would be a different and much simpler bug, so rule it out here.
set n_sysmon [llength [get_cells -hier -filter {REF_NAME == SYSMONE4} -quiet]]
puts "\n==> SYSMONE4 primitives in the implemented design: $n_sysmon"
if {$n_sysmon != 1} {
    error "expected exactly 1 SYSMONE4, found $n_sysmon"
}

set wns [get_property SLACK [get_timing_paths -delay_type min_max]]
puts "==> WNS: $wns ns"
if {$wns < 0} { error "timing not met: WNS $wns ns" }

file copy -force \
    $proj_dir/$proj_name.runs/impl_1/${bd_name}_wrapper.bit $out_dir/xadc_sysmon.bit

# PYNQ pairs a .hwh to a .bit by basename, so the .hwh has to be renamed to
# match the bitstream rather than keep the block design's name.
set hwh [glob -nocomplain $proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hw_handoff/$bd_name.hwh]
if {$hwh eq ""} {
    set hwh [glob $proj_dir/$proj_name.srcs/sources_1/bd/$bd_name/hw_handoff/$bd_name.hwh]
}
file copy -force $hwh $out_dir/xadc_sysmon.hwh

puts "\n=========================================="
puts " built: $out_dir/xadc_sysmon.bit"
puts "        $out_dir/xadc_sysmon.hwh"
puts " sysmon AXI4-Lite at $sysmon_base"
puts "=========================================="
