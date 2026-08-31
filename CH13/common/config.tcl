# ---------------------------------------------------------------------------
# CH13 build configuration -- EDIT THIS FILE FOR YOUR SETUP
# ---------------------------------------------------------------------------
# Sourced by everything under CH13. Anything that depends on where things live
# on your machine is here and nowhere else.

# The device on the AUP-ZU3.
set ch13_part {xczu3eg-sfvc784-2-e}

# The board preset configures the PS DDR controller. Without it the PS is left
# at defaults, which will not match the board's memory. The AUP-ZU3 comes in
# 4GB and 8GB variants; pick the one matching your board.
#   realdigital.org:aup-zu3-8gb:part0:1.0
#   realdigital.org:aup-zu3-4gb:part0:1.0
set ch13_board_part {realdigital.org:aup-zu3-8gb:part0:1.0}

# CH13/ -- every path below is relative to it.
set ch13_root [file normalize [file join [file dirname [file normalize [info script]]] ..]]

# Board files are not installed into Vivado, so point at the repo checkout.
set ch13_board_repo [file normalize [file join $ch13_root .. .. aup-zu3-board-files]]

# AMD's AUP-ZU3 PYNQ repo, for the MIPI camera hierarchy and PYNQ's prebuilt
# pixel_pack_2. CH13's static region is CH12 project 3's camera pipeline, so it
# needs the same two things.
set ch13_aup_zu3 [file normalize [file join $ch13_root .. .. AUP-ZU3]]
set ch13_pynq_ip [list \
    [file join $ch13_aup_zu3 pynq boards ip hls pixel_pack_2 pixel_pack_2_zu3_solution impl ip]]

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
# 200 MHz requested for the socket; the PS delivers 187.5, because the PL
# clocks are integer divisions of a 1500 MHz PLL and 1500/200 is 7.5. The
# design is synthesised against 5 ns and runs at 5.333, so it has more margin
# than it was built for.
#
# THE PARTITION'S CLOCK IS PART OF THE SOCKET CONTRACT, not an RM's choice.
# Every RM runs at this frequency, and the socket's AXI4-Lite control path is
# driven from a dedicated PS master clocked from the same net -- so no RM can
# reintroduce the clock crossing that cost CH12 about one completion in a
# thousand. See docs/ch13-plan.md 2.3 and CH12/README.md.
set ch13_socket_mhz 200

# Where the socket's AXI4-Lite control port lives.
#
# This is an APERTURE, not just an address, and DFX makes the difference matter.
# The static region's address decode is routed once and cannot change when a
# partial lands, so every RM must decode the SAME range -- Vivado enforces that
# by requiring the aperture to be declared on the container's boundary rather
# than inferred per RM. Left to inference it fails with
#   CRITICAL WARNING [BD 41-3089] Cannot infer aperture ... on interface
#   </socket/s_axi_control>
# which lists the valid apertures through the master that reaches it.
#
# 0xB0000000 because that is the first valid aperture through M_AXI_HPM1_FPD,
# the dedicated master the socket's control path uses. It is also well clear of
# the camera's 0xA0000000 video IPs and the 0x80000000 AXI4-Lite peripherals.
set ch13_socket_base 0xB0000000
set ch13_socket_range 64K

# The clock region the reconfigurable partition occupies.
#
# One WHOLE clock region, because RESET_AFTER_RECONFIG requires the pblock to
# be clock-region aligned, and RESET_AFTER_RECONFIG is what puts the new RM in
# a known state instead of whatever the fabric happened to power up as.
#
# It is also far more room than any RM needs -- the largest is 1831 LUTs and
# the smallest region here holds about 9600 -- and that is worth being honest
# about rather than hiding, because the partial bitstream's size is set by the
# PARTITION, not by what is in it. A partition sized for convenience makes
# every swap proportionally slower. See docs/ch13-plan.md 6.1.
#
# X1Y2 keeps the partition away from the PS at the bottom of the die and out of
# the larger X0Y* columns, which the camera pipeline and the interconnects
# want.
set ch13_pblock_region {CLOCKREGION_X1Y2:CLOCKREGION_X1Y2}

# The DFX status and control GPIO, in the STATIC region. Software reads this
# BEFORE it touches the socket -- see docs/ch13-plan.md 2.2.
set ch13_dfx_ctrl_base 0x80170000

# 300 MHz for the MIPI datapath. AMD's number for the camera pipeline, not a
# choice: the CSI-2 subsystem, demosaic, gamma LUT and CSC are configured for
# it.
set ch13_video_mhz 300

# ---------------------------------------------------------------------------
# The reconfigurable modules, in one place.
#
# KERNEL_ID must agree with the localparam in hdl/rm_<name>.sv and with
# sw/rm_ref.py. Three copies of a constant is two too many, but the RTL cannot
# read Python and the Tcl should not parse SystemVerilog, so instead
# common/check_ids.py asserts all three agree and the build calls it.
# ---------------------------------------------------------------------------
set ch13_rms {
    {passthrough 0xA5A50000 {rm_passthrough_core.sv}}
    {sobel       0xA5A50001 {rm_sobel_core.sv}}
    {blur        0xA5A50002 {rm_blur_core.sv}}
    {threshold   0xA5A50003 {rm_threshold_core.sv}}
}

# Files every RM contains -- the socket contract's implementation.
set ch13_shell_srcs {
    socket_ctrl.sv
    sync_fifo.sv
    rm_axi_rd.sv
    rm_axi_wr.sv
    rm_shell.sv
}

# ---------------------------------------------------------------------------
# Sanity checks, so a missing dependency fails here rather than a hundred lines
# into IP Integrator with a message about a VLNV nobody recognises.
# ---------------------------------------------------------------------------
proc ch13_require_dir {path what} {
    if {![file isdirectory $path]} {
        error "$what not found at $path -- edit common/config.tcl"
    }
}

proc ch13_rm_names {} {
    global ch13_rms
    set names {}
    foreach rm $ch13_rms { lappend names [lindex $rm 0] }
    return $names
}

proc ch13_rm_sources {name} {
    global ch13_rms ch13_shell_srcs ch13_root
    set d [file join $ch13_root SystemVerilog hdl]
    foreach rm $ch13_rms {
        if {[lindex $rm 0] eq $name} {
            set srcs {}
            foreach f $ch13_shell_srcs { lappend srcs [file join $d $f] }
            foreach f [lindex $rm 2]   { lappend srcs [file join $d $f] }
            lappend srcs [file join $d rm_$name.sv]
            return $srcs
        }
    }
    error "unknown RM '$name' -- expected one of [ch13_rm_names]"
}
