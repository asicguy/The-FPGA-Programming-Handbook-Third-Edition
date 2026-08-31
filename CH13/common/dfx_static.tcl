# ---------------------------------------------------------------------------
# The static region's DFX furniture: shutdown managers, reset gating, status
# ---------------------------------------------------------------------------
# Everything here lives OUTSIDE the partition and is routed once. It is what
# makes a swap survivable, and every piece of it is here because something went
# wrong without it.

# One AXI shutdown manager on an interface crossing the partition boundary.
#
# `rp_is_master` says which side the RM is on: true for the RM's two gmem
# masters, false for its AXI4-Lite slave. Either way the manager's S_AXI faces
# the initiator and its M_AXI faces the target, and when `request_shutdown` is
# asserted it completes what is outstanding and then answers new transactions
# itself.
#
# That last part is the whole point, and it is why this is preferred over a
# plain dfx_decoupler on the AXI paths. A decoupler ISOLATES: it stops driving,
# and anything already in flight is stranded. On ZynqMP a stranded transaction
# on a PL port is not an error -- there is no bus timeout, so the master waits
# forever and the CPU stops with no panic and no console. During the CH13 spike
# a partial reconfiguration with nothing in the path at all took the
# interconnect's bus fault straight to the kernel:
#
#     Kernel panic - not syncing: Asynchronous SError Interrupt
#
# so this is mandatory rather than a refinement.
proc ch13_add_shutdown {name rp_is_master protocol {addr_width 32} {data_width 32}} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_axi_shutdown_manager:1.0 $name
    set_property -dict [list \
        CONFIG.RP_IS_MASTER      $rp_is_master \
        CONFIG.DP_PROTOCOL       $protocol \
        CONFIG.DP_AXI_ADDR_WIDTH $addr_width \
        CONFIG.DP_AXI_DATA_WIDTH $data_width \
        CONFIG.RESET_ACTIVE_LEVEL 0 \
    ] [get_bd_cells $name]
    return $name
}

# A 1-bit AND. Used twice, for two things that must be gated by the partition's
# state rather than left free-running across a swap.
proc ch13_add_and2 {name} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 $name
    set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] \
        [get_bd_cells $name]
    return $name
}

# The status and control GPIO, and why it is in the STATIC region.
#
# Software must be able to ask "is the partition clocked and out of reset?"
# BEFORE it asks the partition anything. It cannot ask the partition that
# question, because a read of a socket held in reset never returns and takes
# the CPU with it -- and "held in reset" and "logic is broken" look identical
# from outside. Static logic always answers; the partition may not.
#
#   channel 1, OUTPUT, 2 bits    bit0 request_shutdown, bit1 rm_resetn
#   channel 2, INPUT,  4 bits    bit0 heartbeat
#                                bit1 sdm_ctrl  in_shutdown
#                                bit2 sdm_gmem0 in_shutdown
#                                bit3 sdm_gmem1 in_shutdown
#
# The three in_shutdown bits are readback, not decoration: asserting
# request_shutdown is a REQUEST, and the manager takes as long as its
# outstanding transactions take. Reconfiguring before all three report shutdown
# is reconfiguring underneath live traffic, which is the panic above.
proc ch13_add_dfx_gpio {name} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 $name
    set_property -dict [list \
        CONFIG.C_IS_DUAL          {1} \
        CONFIG.C_GPIO_WIDTH       {2} \
        CONFIG.C_ALL_OUTPUTS      {1} \
        CONFIG.C_GPIO2_WIDTH      {4} \
        CONFIG.C_ALL_INPUTS_2     {1} \
        CONFIG.C_DOUT_DEFAULT     {0x00000000} \
    ] [get_bd_cells $name]
    return $name
}

proc ch13_add_slice {name width from to} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 $name
    set_property -dict [list CONFIG.DIN_WIDTH $width CONFIG.DIN_FROM $from \
        CONFIG.DIN_TO $to CONFIG.DOUT_WIDTH [expr {$from - $to + 1}]] \
        [get_bd_cells $name]
    return $name
}

# A clock-domain crossing, done properly.
#
# The status GPIO lives on the 100 MHz AXI4-Lite interconnect, so everything it
# drives leaves the pl_clk0 domain, and everything it reads arrives from
# pl_clk2. Wiring those straight across is what the first version of this
# design did, and it fails timing catastrophically rather than subtly:
#
#   clk_pl_0 -> clk_pl_2   WNS -1.324   1369 of 1369 endpoints failing
#   Requirement: 0.336ns
#
# 0.336 ns because the two clocks are NOT asynchronous -- they are integer
# divisions of the same 1500 MHz PLL, so Vivado times them SYNCHRONOUSLY and
# the tightest edge relationship between a 10 ns clock and a 5.333 ns one is
# what the logic gets. No amount of placement effort closes that.
#
# The same PLL relationship is what made CH12's AP_DONE fault so confusing: the
# crossing looked asynchronous and was constrained as if it were, when the
# clocks were related all along.
proc ch13_add_cdc {name width src_period_ps dest_period_ps} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xpm_cdc_gen:1.0 $name
    set_property -dict [list \
        CONFIG.CDC_TYPE       {xpm_cdc_array_single} \
        CONFIG.WIDTH          $width \
        CONFIG.DEST_SYNC_FF   {4} \
        CONFIG.SRC_INPUT_REG  {true} \
        CONFIG.INIT_SYNC_FF   {false} \
        CONFIG.SIM_ASSERT_CHK {false} \
        CONFIG.SRC_CLK_PERIOD  $src_period_ps \
        CONFIG.DEST_CLK_PERIOD $dest_period_ps \
    ] [get_bd_cells $name]
    return $name
}
