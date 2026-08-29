# Out-of-context synthesis of the accelerator alone, all three implementations.
#
#   vivado -mode batch -source common/synth_ooc.tcl
#
# The point is a comparison that is actually comparable. Reading resource
# numbers off the three full block designs would not be: those include the PS
# interface logic, the SmartConnects and (in project 3) an entire camera
# pipeline, and the differences between the accelerators would be lost in it.
#
# For HLS that means synthesising the Verilog it generated, from
# HLS/video_filter/hls/syn/verilog/ -- not its own estimate, which is made
# before place and route and reports a different thing.
#
# 5 ns (200 MHz), accelerator alone, same flow for all three. Writes a table to
# stdout and leaves the reports in common/ooc/.

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir config.tcl]

# Pull one "| Site Type | Used | ..." row out of a report_utilization file.
proc ch12_util_row {text name} {
    foreach line [split $text \n] {
        if {[regexp "^\\|\\s*[string map {* {\\*}} $name]\\s*\\*?\\s*\\|\\s*(\[0-9.\]+)\\s*\\|" $line -> v]} {
            return $v
        }
    }
    return 0
}

set out_dir $script_dir/ooc
file mkdir $out_dir

set period 5.0

proc synth_one {variant out_dir period} {
    global ch12_root ch12_part

    create_project -in_memory -part $ch12_part
    switch $variant {
        sv {
            read_verilog -sv [glob [file join $ch12_root SystemVerilog hdl *.sv]]
        }
        vhdl {
            set d [file join $ch12_root VHDL hdl]
            read_vhdl [list \
                [file join $d sync_fifo.vhd] \
                [file join $d video_filter_ctrl.vhd] \
                [file join $d video_filter_rd.vhd] \
                [file join $d video_filter_wr.vhd] \
                [file join $d video_filter_core.vhd] \
                [file join $d video_filter.vhd]]
        }
        hls {
            set d [file join $ch12_root HLS video_filter hls syn verilog]
            if {![file isdirectory $d]} {
                error "HLS RTL not found at $d -- run HLS/build_hls.sh first"
            }
            read_verilog [glob [file join $d *.v]]
        }
    }

    synth_design -top video_filter -part $ch12_part -mode out_of_context

    create_clock -period $period -name ap_clk [get_ports ap_clk]
    report_timing_summary -file $out_dir/timing_$variant.rpt -quiet
    report_utilization    -file $out_dir/util_$variant.rpt   -quiet

    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

    # Read the numbers back out of report_utilization rather than counting
    # cells with property filters. Counting looks tidier and is a good way to
    # be confidently wrong: PRIMITIVE_GROUP == ARITHMETIC picks up carry
    # chains, not DSPs, and FLOP_LATCH matched nothing at all here. The report
    # is what Vivado itself considers the answer.
    set util $out_dir/util_$variant.rpt
    set fh [open $util r]
    set text [read $fh]
    close $fh

    close_project
    return [list $wns \
        [ch12_util_row $text "CLB LUTs"] \
        [ch12_util_row $text "LUT as Logic"] \
        [ch12_util_row $text "LUT as Memory"] \
        [ch12_util_row $text "CLB Registers"] \
        [ch12_util_row $text "Block RAM Tile"] \
        [ch12_util_row $text "DSPs"]]
}

set results {}
foreach variant {sv vhdl hls} {
    puts "=== synthesising $variant out of context ==="
    if {[catch {synth_one $variant $out_dir $period} r]} {
        puts "  FAILED: $r"
        lappend results [list $variant - - - - - - -]
    } else {
        lappend results [concat [list $variant] $r]
    }
}

puts ""
puts "Out-of-context synthesis, xczu3eg-sfvc784-2-e at [format %.1f $period] ns (200 MHz)"
puts "accelerator alone -- no PS, no interconnect, no camera"
puts ""
puts [format "%-8s %10s %10s %8s %10s %10s %8s %8s %8s" \
      impl "WNS (ns)" "Fmax MHz" LUTs "LUT logic" "LUT mem" FFs BRAM DSPs]
foreach r $results {
    lassign $r variant wns luts lut_logic lut_mem ff bram dsp
    if {$wns eq "-"} {
        puts [format "%-8s %10s %10s %8s %10s %10s %8s %8s %8s" \
              $variant - - - - - - - -]
    } else {
        set fmax [expr {1000.0 / ($period - $wns)}]
        # %s, not %d, for the resource columns: report_utilization prints
        # fractional BRAM tiles (5.5 is half a RAMB36) and %d refuses them.
        puts [format "%-8s %10.3f %10.1f %8s %10s %10s %8s %8s %8s" \
              $variant $wns $fmax $luts $lut_logic $lut_mem $ff $bram $dsp]
    }
}
puts ""
puts "reports in $out_dir"
exit
