# ---------------------------------------------------------------------------
# CH12 build configuration -- EDIT THIS FILE FOR YOUR SETUP
# ---------------------------------------------------------------------------
# Sourced by all three projects' build_bd.tcl. Everything that depends on where
# things live on your machine is here and nowhere else.

# The device on the AUP-ZU3.
set ch12_part {xczu3eg-sfvc784-2-e}

# The board preset configures the PS DDR controller. Without it the PS is left
# at defaults, which will not match the board's memory. The AUP-ZU3 comes in
# 4GB and 8GB variants; pick the one matching your board.
#   realdigital.org:aup-zu3-8gb:part0:1.0
#   realdigital.org:aup-zu3-4gb:part0:1.0
set ch12_board_part {realdigital.org:aup-zu3-8gb:part0:1.0}

# CH12/ -- every path below is relative to it.
set ch12_root [file normalize [file join [file dirname [file normalize [info script]]] ..]]

# Board files are not installed into Vivado, so point at the repo checkout.
set ch12_board_repo [file normalize [file join $ch12_root .. .. aup-zu3-board-files]]

# AMD's AUP-ZU3 PYNQ repo. Projects 1 and 3 need two things from it: the MIPI
# camera hierarchy (reproduced in common/mipi_hier.tcl from its
# base/run_create_mipi.tcl) and PYNQ's prebuilt pixel_pack_2 HLS IP, which has
# no source in this repo.
set ch12_aup_zu3 [file normalize [file join $ch12_root .. .. AUP-ZU3]]
set ch12_pynq_ip [list \
    [file join $ch12_aup_zu3 pynq boards ip hls pixel_pack_2 pixel_pack_2_zu3_solution impl ip]]

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
# 200 MHz requested for the accelerator, matching CH11 and the HLS clock
# target. The PS actually delivers 187.5 MHz: the PL clocks are integer
# divisions of a 1500 MHz PLL and 1500/200 is 7.5. That is fine -- the design
# is synthesised against 5 ns and run at 5.333, so it has more margin than it
# was built for -- but it does mean the chapter's throughput numbers are
# against 187.5 Mpixel/s, not 200. ch12_add_ps prints what it got.
#
# There is nothing to buy by asking for more: the filter is DDR-bound at one
# pixel per beat, and CH11 measured all three of its implementations at ~92%
# of the theoretical rate.
set ch12_accel_mhz 200

# 300 MHz for the MIPI datapath in projects 1 and 3. This is AMD's number for
# the camera pipeline, not a choice: the CSI-2 subsystem, demosaic, gamma LUT
# and CSC in the base overlay are all configured for it.
set ch12_video_mhz 300

# ---------------------------------------------------------------------------
# Sanity checks, so a missing dependency fails here rather than a hundred lines
# into IP Integrator with a message about a VLNV nobody recognises.
# ---------------------------------------------------------------------------
proc ch12_require_dir {path what} {
    if {![file isdirectory $path]} {
        error "$what not found at $path -- edit common/config.tcl"
    }
}
