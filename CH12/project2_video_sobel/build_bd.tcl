# Vivado block design for CH12 project 2: video through the Sobel filter.
#
#   vivado -mode batch -source build_bd.tcl -tclargs sv     -> out_sv/
#   vivado -mode batch -source build_bd.tcl -tclargs vhdl   -> out_vhdl/
#   vivado -mode batch -source build_bd.tcl -tclargs hls    -> out_hls/
#
# There is no camera in this design. The PS decodes a video file, hands each
# frame to the accelerator in DDR and puts the result on the DisplayPort, so
# the whole project builds and runs with nothing plugged into the MIPI header.
# That is deliberate: it isolates every question about the *filter* from every
# question about the camera, which project 1 deals with separately.
#
#   PS  --HPM0_LPD-->  video_filter.s_axi_control
#   PS  <--HP0------   video_filter.m_axi_gmem0     (source frame)
#   PS  <--HP1------   video_filter.m_axi_gmem1     (destination frame)
#
# This is CH11's block design with a different accelerator in it. The three
# variants differ only in which IP is instantiated -- same ports, same register
# map, same addresses -- so one notebook drives whichever is loaded.
#
# Produces out_<variant>/video_sobel.bit and .hwh, the two files PYNQ needs.

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir .. common config.tcl]
source [file join $script_dir .. common package_filter.tcl]
source [file join $script_dir .. common ps_config.tcl]

set variant "sv"
if {[llength $argv] > 0} { set variant [lindex $argv 0] }
if {[lsearch -exact {sv vhdl hls} $variant] < 0} {
    error "variant must be sv, vhdl or hls -- got '$variant'"
}

set proj_name video_sobel_$variant
set proj_dir  $script_dir/vivado_$variant
set bd_name   design_1
set out_dir   $script_dir/out_$variant
set ip_repo   $script_dir/ip_repo_$variant

ch12_require_dir $ch12_board_repo "AUP-ZU3 board files"

# --- Phase 1: get the filter into the IP catalog ----------------------------
set filter [ch12_filter_vlnv $variant $ip_repo]
set filter_vlnv [lindex $filter 0]
set filter_repo [lindex $filter 1]

# --- Phase 2: the block design ----------------------------------------------
create_project $proj_name $proj_dir -part $ch12_part -force
set_property ip_repo_paths [list $filter_repo] [current_project]
update_ip_catalog -rebuild

# board_part_repo_paths has to be set before board_part, or the preset is not
# in the catalog yet when we ask for it.
set_property board_part_repo_paths [list $ch12_board_repo] [current_project]
set_property board_part $ch12_board_part [current_project]

create_bd_design $bd_name

ch12_add_ps $ch12_accel_mhz

create_bd_cell -type ip -vlnv $filter_vlnv video_filter_0
ch12_connect_filter video_filter_0

ch12_finish $proj_dir $proj_name $bd_name $out_dir video_sobel 12

puts " variant: $variant   ($filter_vlnv)"
exit
