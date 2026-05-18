create_clock -name PL_USER_PB -period 99.99 [get_ports PL_USER_PB]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets PL_USER_PB_IBUF]
