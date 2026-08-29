# ---------------------------------------------------------------------------
# Package the hand-written RTL as an IP, or point at the HLS one
# ---------------------------------------------------------------------------
# ch12_filter_vlnv sv|vhdl|hls <ip_repo_dir>
#
#   returns the VLNV to instantiate, and for sv/vhdl leaves a packaged IP in
#   <ip_repo_dir>. Projects 2 and 3 both call it, which is the only reason it
#   is a proc rather than sixty lines pasted into each of them.
#
# Two things about packaging RTL are easy to get wrong, and both break PYNQ
# rather than the hardware:
#
#   - A module reference will not take a SystemVerilog top file.
#     `create_bd_cell -type module` rejects it outright, hence the IP-XACT
#     packaging step below.
#
#   - ipx infers the AXI interfaces but NOT the register definitions, and it
#     auto-creates its own address block called "reg0". Leaving that alongside
#     an explicitly added one gives the interface *two* address blocks, and PYNQ
#     then keys the IP as "video_filter_0/s_axi_control" -- so ol.video_filter_0
#     has no register map and filt.register_map raises AttributeError. The
#     script removes every auto-created block and adds exactly one.

proc ch12_add_reg {blk name offset desc} {
    set r [ipx::add_register $name $blk]
    set_property address_offset $offset $r
    set_property size 32 $r
    set_property description $desc $r
    return $r
}

proc ch12_add_fld {reg name bitoff bitwidth desc} {
    set f [ipx::add_field $name $reg]
    set_property bit_offset $bitoff $f
    set_property bit_width $bitwidth $f
    set_property description $desc $f
    return $f
}

proc ch12_filter_vlnv {variant ip_repo} {
    global ch12_root ch12_part

    if {$variant eq "hls"} {
        set hls_ip [file join $ch12_root HLS video_filter hls impl ip]
        ch12_require_dir $hls_ip "HLS IP (run HLS/build_hls.sh first)"
        return [list aup:hls:video_filter:1.0 $hls_ip]
    }

    file delete -force $ip_repo
    file mkdir $ip_repo

    # An on-disk project rather than `create_project -in_memory`. Both work
    # today, but ipx::package_project in non-project mode raises
    #   CRITICAL WARNING [Ipptcl 7-1601] ... will be blocked in a future release
    # and a build that is one Vivado version away from failing is not a build
    # worth shipping in a book. The scratch project is deleted with the repo on
    # the next run.
    set pack_dir [file join [file dirname $ip_repo] pack_tmp_$variant]
    file delete -force $pack_dir
    create_project ch12_pack_$variant $pack_dir -part $ch12_part -force

    if {$variant eq "sv"} {
        add_files -norecurse [glob [file join $ch12_root SystemVerilog hdl *.sv]]
        set_property file_type SystemVerilog [get_files *.sv]
    } elseif {$variant eq "vhdl"} {
        # Explicit order: xvhdl and ipx both want an entity analysed before
        # anything that instantiates it.
        set d [file join $ch12_root VHDL hdl]
        add_files -norecurse [list \
            [file join $d sync_fifo.vhd] \
            [file join $d video_filter_ctrl.vhd] \
            [file join $d video_filter_rd.vhd] \
            [file join $d video_filter_wr.vhd] \
            [file join $d video_filter_core.vhd] \
            [file join $d video_filter.vhd]]
    } else {
        error "variant must be sv, vhdl or hls -- got '$variant'"
    }

    update_compile_order -fileset sources_1
    set_property top video_filter [current_fileset]
    ipx::package_project -root_dir $ip_repo -vendor aup -library rtl \
        -taxonomy /UserIP -import_files -force
    set core [ipx::current_core]
    set_property name video_filter $core
    set_property version 1.0 $core
    set_property display_name "BGRA Gray / Sobel / Invert Video Filter (RTL $variant)" $core
    ipx::infer_bus_interfaces xilinx.com:interface:aximm_rtl:1.0 $core
    ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
    ipx::associate_bus_interfaces -busif m_axi_gmem0   -clock ap_clk $core
    ipx::associate_bus_interfaces -busif m_axi_gmem1   -clock ap_clk $core

    # Tell IP-XACT that gmem0 only ever reads and gmem1 only ever writes.
    #
    # The RTL brings out the full AXI4 port set on both -- it has to, or
    # ipx::infer_bus_interfaces does not recognise them as AXI4 at all -- and
    # ties off the half it does not use. Left at the default READ_WRITE, the
    # SmartConnect on each port then builds the machinery for a direction that
    # is wired to constants: write-channel logic on a master that never writes,
    # and read-channel logic on one that never reads.
    #
    # It costs more than the accelerator saves elsewhere. Vitis HLS declares
    # these as READ_ONLY and WRITE_ONLY, which is why its *whole design* came
    # out smaller than the RTL's despite its accelerator being larger.
    foreach {busif mode} {m_axi_gmem0 READ_ONLY m_axi_gmem1 WRITE_ONLY} {
        set bi [ipx::get_bus_interfaces $busif -of_objects $core]
        set pa [ipx::get_bus_parameters READ_WRITE_MODE -of_objects $bi]
        if {$pa eq ""} { set pa [ipx::add_bus_parameter READ_WRITE_MODE $bi] }
        set_property value $mode $pa
    }

    # --- register map ------------------------------------------------------
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

    # These offsets and names are what Vitis HLS generates for the same kernel,
    # and what CH11 used. sw/filter_driver.py and the notebooks depend on them.
    set ctrl [ch12_add_reg $blk CTRL 0x0 "Control signals"]
    ch12_add_fld $ctrl AP_START     0 1 "ap_start"
    ch12_add_fld $ctrl AP_DONE      1 1 "ap_done"
    ch12_add_fld $ctrl AP_IDLE      2 1 "ap_idle"
    ch12_add_fld $ctrl AP_READY     3 1 "ap_ready"
    ch12_add_fld $ctrl AUTO_RESTART 7 1 "auto_restart"
    ch12_add_fld $ctrl INTERRUPT    9 1 "interrupt"
    ch12_add_reg $blk GIER       0x4  "Global Interrupt Enable Register"
    ch12_add_reg $blk IP_IER     0x8  "IP Interrupt Enable Register"
    ch12_add_reg $blk IP_ISR     0xC  "IP Interrupt Status Register"
    ch12_add_reg $blk src_1      0x10 "src low"
    ch12_add_reg $blk src_2      0x14 "src high"
    ch12_add_reg $blk dst_1      0x1C "dst low"
    ch12_add_reg $blk dst_2      0x20 "dst high"
    ch12_add_reg $blk img_width  0x28 "image width in pixels"
    ch12_add_reg $blk img_height 0x30 "image height in rows"
    ch12_add_reg $blk mode       0x38 "0 gray, 1 sobel, 2 invert, 3 colour"

    set_property core_revision 1 $core
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::save_core $core
    close_project
    file delete -force $pack_dir

    return [list aup:rtl:video_filter:1.0 $ip_repo]
}
