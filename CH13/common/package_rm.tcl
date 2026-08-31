# ---------------------------------------------------------------------------
# Package one reconfigurable module as an IP
# ---------------------------------------------------------------------------
# ch13_rm_vlnv <name> <ip_repo_dir>  ->  {vlnv repo}
#
# Wipes <ip_repo_dir> and packages rm_<name> into it. Every RM is packaged the
# same way and presents the same IP-XACT interfaces, because that is what makes
# them interchangeable in the socket -- IP-XACT is where the socket contract
# stops being a comment and starts being something Vivado checks.
#
# Three things about packaging RTL are easy to get wrong, and all three break
# PYNQ rather than the hardware:
#
#   - A module reference will not take a SystemVerilog top file.
#     `create_bd_cell -type module` rejects it outright, hence IP-XACT.
#
#   - ipx infers the AXI interfaces but NOT the register definitions, and it
#     auto-creates its own address block called "reg0". Left alongside an
#     explicitly added one, the interface has TWO address blocks and PYNQ keys
#     the IP as "<cell>/s_axi_control" -- so the driver finds no register map
#     at all. Every auto-created block is removed and exactly one is added.
#
#   - gmem0 only reads and gmem1 only writes, and IP-XACT has to be told.
#     The RTL brings out the full AXI4 port set on both (it must, or
#     infer_bus_interfaces does not recognise them as AXI4) and ties off the
#     unused half. Left at READ_WRITE, each SmartConnect builds machinery for a
#     direction wired to constants. CH12 measured that costing more than the
#     accelerator saves elsewhere.

proc ch13_add_reg {blk name offset desc} {
    set r [ipx::add_register $name $blk]
    set_property address_offset $offset $r
    set_property size 32 $r
    set_property description $desc $r
    return $r
}

proc ch13_add_fld {reg name bitoff bitwidth desc} {
    set f [ipx::add_field $name $reg]
    set_property bit_offset $bitoff $f
    set_property bit_width $bitwidth $f
    set_property description $desc $f
    return $f
}

proc ch13_rm_vlnv {name ip_repo} {
    global ch13_root ch13_part

    file delete -force $ip_repo
    file mkdir $ip_repo

    # An on-disk project rather than `create_project -in_memory`: ipx's
    # package_project in non-project mode raises
    #   CRITICAL WARNING [Ipptcl 7-1601] ... will be blocked in a future release
    # and a build one Vivado version from failing is not one to ship in a book.
    set pack_dir [file join [file dirname $ip_repo] pack_tmp_$name]
    file delete -force $pack_dir
    create_project ch13_pack_$name $pack_dir -part $ch13_part -force

    add_files -norecurse [ch13_rm_sources $name]
    set_property file_type SystemVerilog [get_files *.sv]
    update_compile_order -fileset sources_1
    set_property top rm_$name [current_fileset]

    ipx::package_project -root_dir $ip_repo -vendor aup -library rtl \
        -taxonomy /UserIP -import_files -force
    set core [ipx::current_core]
    set_property name rm_$name $core
    set_property version 1.0 $core
    set_property display_name "CH13 reconfigurable module: $name" $core
    ipx::infer_bus_interfaces xilinx.com:interface:aximm_rtl:1.0 $core
    ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
    ipx::associate_bus_interfaces -busif m_axi_gmem0   -clock ap_clk $core
    ipx::associate_bus_interfaces -busif m_axi_gmem1   -clock ap_clk $core

    foreach {busif mode} {m_axi_gmem0 READ_ONLY m_axi_gmem1 WRITE_ONLY} {
        set bi [ipx::get_bus_interfaces $busif -of_objects $core]
        set pa [ipx::get_bus_parameters READ_WRITE_MODE -of_objects $bi]
        if {$pa eq ""} { set pa [ipx::add_bus_parameter READ_WRITE_MODE $bi] }
        set_property value $mode $pa
    }

    # --- register map ------------------------------------------------------
    # The first eleven entries are byte-for-byte what Vitis HLS generates for
    # an ap_ctrl_hs kernel, so CH12's sw/filter_driver.py and notebooks drive
    # this socket unchanged. kernel_id at 0x3C is CH13's addition.
    set mm [ipx::get_memory_maps s_axi_control -of_objects $core]
    if {$mm eq ""} {
        set mm [ipx::add_memory_map s_axi_control $core]
        set_property slave_memory_map_ref s_axi_control \
            [ipx::get_bus_interfaces s_axi_control -of_objects $core]
    }
    foreach ab [ipx::get_address_blocks -of_objects $mm] {
        ipx::remove_address_block [get_property name $ab] $mm
    }
    set blk [ipx::add_address_block Reg $mm]
    set_property base_address  0          $blk
    set_property range         65536      $blk
    set_property width         32         $blk
    set_property usage         register   $blk
    set_property access        read-write $blk

    set ctrl [ch13_add_reg $blk CTRL 0x0 "Control signals"]
    ch13_add_fld $ctrl AP_START     0 1 "ap_start"
    ch13_add_fld $ctrl AP_DONE      1 1 "ap_done"
    ch13_add_fld $ctrl AP_IDLE      2 1 "ap_idle"
    ch13_add_fld $ctrl AP_READY     3 1 "ap_ready"
    ch13_add_fld $ctrl AUTO_RESTART 7 1 "auto_restart"
    ch13_add_fld $ctrl INTERRUPT    9 1 "interrupt"
    ch13_add_reg $blk GIER       0x4  "Global Interrupt Enable Register"
    ch13_add_reg $blk IP_IER     0x8  "IP Interrupt Enable Register"
    ch13_add_reg $blk IP_ISR     0xC  "IP Interrupt Status Register"
    ch13_add_reg $blk src_1      0x10 "src low"
    ch13_add_reg $blk src_2      0x14 "src high"
    ch13_add_reg $blk dst_1      0x1C "dst low"
    ch13_add_reg $blk dst_2      0x20 "dst high"
    ch13_add_reg $blk img_width  0x28 "image width in pixels"
    ch13_add_reg $blk img_height 0x30 "image height in rows"
    # What `mode` means depends on which RM is in the socket. That is the
    # chapter's point, and the description says so rather than pretending
    # otherwise.
    ch13_add_reg $blk mode       0x38 "sobel: 0 gray 1 sobel 2 invert 3 colour; threshold: level 0-255; blur/passthrough: unused"
    ch13_add_reg $blk kernel_id  0x3C "READ-ONLY identity of the RM in the socket"

    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::check_integrity $core
    ipx::save_core $core
    close_project

    file delete -force $pack_dir
    return [list aup:rtl:rm_$name:1.0 $ip_repo]
}
