set origin_dir "."

# Use origin directory path location variable, if specified in the tcl shell
if { [info exists ::origin_dir_loc] } {
  set origin_dir $::origin_dir_loc
}

# Set the project name
set _xil_proj_name_ "aic3104_dma"

# Use project name variable, if specified in the tcl shell
if { [info exists ::user_project_name] } {
  set _xil_proj_name_ $::user_project_name
}

variable script_file
set script_file "aic3104_dma.tcl"

# Help information for this script
proc print_help {} {
  variable script_file
  puts "\nDescription:"
  puts "Recreate a Vivado project from this script. The created project will be"
  puts "functionally equivalent to the original project for which this script was"
  puts "generated. The script contains commands for creating a project, filesets,"
  puts "runs, adding/importing sources and setting properties on various objects.\n"
  puts "Syntax:"
  puts "$script_file"
  puts "$script_file -tclargs \[--origin_dir <path>\]"
  puts "$script_file -tclargs \[--project_name <name>\]"
  puts "$script_file -tclargs \[--help\]\n"
  puts "Usage:"
  puts "Name                   Description"
  puts "-------------------------------------------------------------------------"
  puts "\[--origin_dir <path>\]  Determine source file paths wrt this path. Default"
  puts "                       origin_dir path value is \".\", otherwise, the value"
  puts "                       that was set with the \"-paths_relative_to\" switch"
  puts "                       when this script was generated.\n"
  puts "\[--project_name <name>\] Create project with the specified name. Default"
  puts "                       name is the name of the project from where this"
  puts "                       script was generated.\n"
  puts "\[--help\]               Print help information for this script"
  puts "-------------------------------------------------------------------------\n"
  exit 0
}

if { $::argc > 0 } {
  for {set i 0} {$i < $::argc} {incr i} {
    set option [string trim [lindex $::argv $i]]
    switch -regexp -- $option {
      "--origin_dir"   { incr i; set origin_dir [lindex $::argv $i] }
      "--project_name" { incr i; set _xil_proj_name_ [lindex $::argv $i] }
      "--help"         { print_help }
      default {
        if { [regexp {^-} $option] } {
          puts "ERROR: Unknown option '$option' specified, please type '$script_file -tclargs --help' for usage info.\n"
          return 1
        }
      }
    }
  }
}

# Set the directory path for the original project from where this script was exported
set orig_proj_dir "[file normalize "$origin_dir/t72_25g_oran"]"

# Check for paths and files needed for project creation
set validate_required 0
if { $validate_required } {
  if { [checkRequiredFiles $origin_dir] } {
    puts "Tcl file $script_file is valid. All files required for project creation is accesable. "
  } else {
    puts "Tcl file $script_file is not valid. Not all files required for project creation is accesable. "
    return
  }
}

# Create project
create_project ${_xil_proj_name_} ./${_xil_proj_name_} -part xczu3eg-sfvc784-2-e

# Set the directory path for the new project
set proj_dir [get_property directory [current_project]]

# Set project properties
set obj [current_project]
set_property -name "default_lib" -value "xil_defaultlib" -objects $obj
set_property -name "enable_resource_estimation" -value "0" -objects $obj
set_property -name "enable_vhdl_2008" -value "1" -objects $obj
set_property -name "ip_cache_permissions" -value "read write" -objects $obj
set_property -name "ip_output_repo" -value "$proj_dir/${_xil_proj_name_}.cache/ip" -objects $obj
set_property -name "mem.enable_memory_map_generation" -value "1" -objects $obj
set_property -name "part" -value "xczu3eg-sfvc784-2-e" -objects $obj
set_property -name "revised_directory_structure" -value "1" -objects $obj
set_property -name "sim.central_dir" -value "$proj_dir/${_xil_proj_name_}.ip_user_files" -objects $obj
set_property -name "sim.ip.auto_export_scripts" -value "1" -objects $obj
set_property -name "simulator_language" -value "Mixed" -objects $obj
set_property -name "sim_compile_state" -value "1" -objects $obj
set_property -name "target_simulator" -value "XSim" -objects $obj
set_property -name "use_inline_hdl_ip" -value "1" -objects $obj
set_property -name "webtalk.questa_launch_sim" -value "1" -objects $obj
set_property -name "xpm_libraries" -value "XPM_CDC XPM_FIFO XPM_MEMORY" -objects $obj

# Create 'sources_1' fileset (if not found)
if {[string equal [get_filesets -quiet sources_1] ""]} {
  create_fileset -srcset sources_1
}

# Set IP repository paths
set obj [get_filesets sources_1]
if { $obj != {} } {
   #set_property "ip_repo_paths" "[file normalize "$origin_dir/src/ip/ip_system"] [file normalize "$origin_dir/src/ip/ip_xilinx"]" $obj

   # Rebuild user ip_repo's index before adding any source files
   update_ip_catalog -rebuild
}

# Set 'sources_1' fileset object
set obj [get_filesets sources_1]
  set files [list \
 "[file normalize "$origin_dir/../hdl/aic3104_dma.vhd"]"\
 "[file normalize "$origin_dir/../hdl/axi_dma_reader.vhd"]"\
 "[file normalize "$origin_dir/../hdl/axi_dma_writer.vhd"]"\
 "[file normalize "$origin_dir/../hdl/aic3104_dma_top.v"]"\
 "[file normalize "$origin_dir/../xdc/constraints.xdc"]"\
  ]
add_files -norecurse -fileset $obj $files

if { $argv != "sim" } {

# Set 'constrs_1' fileset object
set obj [get_filesets constrs_1]

# Add/Import constrs file and set constrs file properties
set file "[file normalize "$origin_dir/../../../xdc/zu3.xdc"]"
set file_added [add_files -norecurse -fileset $obj [list $file]]
set file "$origin_dir/../../../xdc/zu3.xdc"
set file [file normalize $file]
set file_obj [get_files -of_objects [get_filesets constrs_1] [list "*$file"]]
set_property -name "file_type" -value "XDC" -objects $file_obj

source $origin_dir/../bd/aic3104_dma.tcl
#close_bd_design [get_bd_designs hw]
set_property GENERATE_SYNTH_CHECKPOINT 1 [get_files -all "$origin_dir/${_xil_proj_name_}/${_xil_proj_name_}.srcs/sources_1/bd/hw/hw.bd"]
#make_wrapper -files [get_files "$origin_dir/${_xil_proj_name_}/${_xil_proj_name_}.srcs/sources_1/bd/hw/hw.bd"] -top
#update_compile_order -fileset sources_1
#add_files -norecurse [get_files "$origin_dir/${_xil_proj_name_}/${_xil_proj_name_}.gen/sources_1/bd/hw/hdl/hw_wrapper.v"]
update_compile_order -fileset sources_1

# Set 'sources_1' fileset properties
set obj [get_filesets sources_1]
set_property -name "top" -value "hw_wrapper" -objects $obj

set obj [get_runs impl_1]
set_property -name "needs_refresh" -value "1" -objects $obj
set_property -name "strategy" -value "Performance_ExtraTimingOpt" -objects $obj

set_msg_config -suppress -id {IP_Flow 19-11780}
set_msg_config -suppress -id {DRC RPBF-8}

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs 8
wait_on_run -timeout 150 synth_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run -timeout 150 impl_1

#set out_file_name "$orig_proj_name"

exec cp ./aic3104_dma/aic3104_dma.gen/sources_1/bd/hw/hw_handoff/hw.hwh hw_wrapper.hwh
exec cp ./aic3104_dma/aic3104_dma.runs/impl_1/hw_wrapper.bit .

}
