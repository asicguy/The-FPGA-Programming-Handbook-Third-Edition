# ---------------------------------------------------------------------------
# CH13 SYSMON project -- pin constraints
# ---------------------------------------------------------------------------
# The eight white PL LEDs, showing bits of the end-of-conversion counter. If
# the SYSMONE4 is converting they run as a binary counter; if it is not they
# stay dark. That is the whole diagnostic, visible without a browser.
#
# Values are the board's, taken from the repository's xdc/zu3.xdc.
#
# THERE IS DELIBERATELY NOTHING HERE FOR VP/VN.
#
# They are dedicated analog pins -- R13 and T12 on this package, PIN_FUNC VP
# and VN, IS_GENERAL_PURPOSE 0 -- so Vivado places them on the only sites they
# can occupy. A PACKAGE_PIN or IOSTANDARD line for them is not merely
# redundant, it is wrong. The board's own base.xdc constrains nothing for them
# either, which is the confirmation that this is intended and not an omission.

set_property PACKAGE_PIN AF5 [get_ports {PL_USER_LED[0]}]
set_property PACKAGE_PIN AE7 [get_ports {PL_USER_LED[1]}]
set_property PACKAGE_PIN AH2 [get_ports {PL_USER_LED[2]}]
set_property PACKAGE_PIN AE5 [get_ports {PL_USER_LED[3]}]
set_property PACKAGE_PIN AH1 [get_ports {PL_USER_LED[4]}]
set_property PACKAGE_PIN AE4 [get_ports {PL_USER_LED[5]}]
set_property PACKAGE_PIN AG1 [get_ports {PL_USER_LED[6]}]
set_property PACKAGE_PIN AF2 [get_ports {PL_USER_LED[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports {PL_USER_LED[*]}]
