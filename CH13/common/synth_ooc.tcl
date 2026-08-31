# Out-of-context synthesis of every reconfigurable module, alone.
#
#   vivado -mode batch -source common/synth_ooc.tcl
#
# This is what sizes the partition. A DFX pblock has to hold the LARGEST RM,
# and it has to be decided before the static design is built, because the
# static region is routed around it once and every partial has to fit what was
# routed. Guessing generously wastes fabric the static region needs; guessing
# tightly fails place-and-route on the one RM that did not fit, after the
# static design is already frozen.
#
# Out of context, and alone, so the comparison is actually comparable: numbers
# read off a full block design would include the PS interface logic, the
# SmartConnects and an entire camera pipeline, and the differences between the
# RMs -- which are the whole point -- would be lost in it.
#
# Writes a table to stdout and leaves the reports in common/ooc/.

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir config.tcl]

# Pull one "| Site Type | Used | ..." row out of a report_utilization file.
# Read the numbers back out of the report rather than counting cells with
# property filters: counting looks tidier and is a good way to be confidently
# wrong -- PRIMITIVE_GROUP == ARITHMETIC picks up carry chains, not DSPs.
proc ch13_util_row {text name} {
    foreach line [split $text \n] {
        if {[regexp "^\\|\\s*[string map {* {\\*}} $name]\\s*\\*?\\s*\\|\\s*(\[0-9.\]+)\\s*\\|" $line -> v]} {
            return $v
        }
    }
    return 0
}

set out_dir $script_dir/ooc
file mkdir $out_dir

set period [expr {1000.0 / $ch13_socket_mhz}]

proc synth_one {name out_dir period} {
    global ch13_part

    create_project -in_memory -part $ch13_part
    read_verilog -sv [ch13_rm_sources $name]
    synth_design -top rm_$name -part $ch13_part -mode out_of_context

    create_clock -period $period -name ap_clk [get_ports ap_clk]
    report_timing_summary -file $out_dir/timing_$name.rpt -quiet
    report_utilization    -file $out_dir/util_$name.rpt   -quiet

    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

    set fh [open $out_dir/util_$name.rpt r]
    set text [read $fh]
    close $fh

    close_project
    return [list $wns \
        [ch13_util_row $text "CLB LUTs"] \
        [ch13_util_row $text "CLB Registers"] \
        [ch13_util_row $text "Block RAM Tile"] \
        [ch13_util_row $text "DSPs"]]
}

set results {}
foreach name [ch13_rm_names] {
    puts "=== synthesising rm_$name out of context ==="
    if {[catch {synth_one $name $out_dir $period} r]} {
        puts "  FAILED: $r"
        lappend results [list $name - - - - -]
    } else {
        lappend results [concat [list $name] $r]
    }
}

puts ""
puts "CH13 reconfigurable modules, out of context at [format %.3f $period] ns"
puts ""
puts [format "%-14s %9s %8s %8s %7s %6s" RM WNS LUTs FFs BRAM DSP]
foreach r $results {
    lassign $r name wns luts ffs bram dsp
    if {$wns eq "-"} {
        puts [format "%-14s %9s %8s %8s %7s %6s" $name - - - - -]
    } else {
        puts [format "%-14s %9.3f %8s %8s %7s %6s" $name $wns $luts $ffs $bram $dsp]
    }
}
puts ""
puts "The pblock must hold the largest of these with margin -- see"
puts "docs/ch13-plan.md 5. Reports are in common/ooc/."
