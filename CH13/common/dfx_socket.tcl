# ---------------------------------------------------------------------------
# The socket's child block design -- one per reconfigurable module
# ---------------------------------------------------------------------------
# ch13_create_socket_bd <name> <vlnv>
#
# Creates a block design named socket_<name> holding exactly one RM, with the
# socket contract as its external boundary. These child designs are what the
# Block Design Container swaps between.
#
# EVERY ONE OF THESE MUST HAVE AN IDENTICAL BOUNDARY -- the same external
# interfaces, with the same names, widths and protocols. The container's
# boundary is fixed when the static design is implemented, and a partial that
# does not match it does not fit the socket. Vivado checks this when
# LIST_SYNTH_BD is set, and the error it gives is about interface mismatch
# rather than about DFX, which is easy to misread.
#
# That is why this is a proc taking a VLNV rather than four hand-written block
# designs: the boundary is written once.
#
# Why a Block Design Container at all, rather than marking a cell as a
# partition? Because `create_partition_def` does not apply to a BD cell created
# as a plain module reference -- IPI's mechanism IS the BDC. During the spike
# that cost an afternoon: `get_partition_defs` returned empty and looked like a
# silent failure, when in fact the partition definitions do not exist until
# `generate_target` has run on the container.

proc ch13_create_socket_bd {name vlnv} {
    create_bd_design socket_$name
    current_bd_design [get_bd_designs socket_$name]

    # The instance name is the same in every RM. It does not have to be, but
    # keeping it constant means the address segment paths, the ILA probe names
    # and anything else that walks the hierarchy do not change when the socket
    # is reconfigured.
    create_bd_cell -type ip -vlnv $vlnv rm_inst

    # --- the socket contract, as this design's boundary ---------------------
    # Interfaces first. The names here are what the static side connects to.
    foreach {pin ext} {
        s_axi_control s_axi_control
        m_axi_gmem0   m_axi_gmem0
        m_axi_gmem1   m_axi_gmem1
    } {
        set p [get_bd_intf_pins rm_inst/$pin]
        if {$p eq ""} { error "RM $name has no interface pin $pin" }
        make_bd_intf_pins_external -name $ext $p
    }

    # Then the scalars. ap_clk and ap_rst_n are the partition's clock and
    # reset: the clock is part of the socket contract, not an RM's choice, so
    # that no RM can reintroduce the AXI4-Lite clock crossing that cost CH12
    # about one completion in a thousand. See docs/ch13-plan.md 2.3.
    foreach {pin ext} {
        ap_clk    ap_clk
        ap_rst_n  ap_rst_n
        interrupt interrupt
        heartbeat heartbeat
    } {
        set p [get_bd_pins rm_inst/$pin]
        if {$p eq ""} { error "RM $name has no pin $pin" }
        make_bd_pins_external -name $ext $p
    }

    # Declare the clock and reset as such, and tie the reset's polarity down.
    # Without this the container's boundary carries an undeclared clock, and
    # the parent's validation complains about a clock pin with no valid source
    # -- which is a confusing way to be told the child did not say what its
    # clock was.
    set_property CONFIG.FREQ_HZ         [expr {int(1.0e6 * $::ch13_socket_mhz)}] [get_bd_ports ap_clk]
    set_property CONFIG.ASSOCIATED_BUSIF {s_axi_control:m_axi_gmem0:m_axi_gmem1} [get_bd_ports ap_clk]
    set_property CONFIG.ASSOCIATED_RESET {ap_rst_n}                              [get_bd_ports ap_clk]
    set_property CONFIG.POLARITY         ACTIVE_LOW                              [get_bd_ports ap_rst_n]

    assign_bd_address -quiet
    validate_bd_design -quiet
    save_bd_design
    close_bd_design [get_bd_designs socket_$name]
}
