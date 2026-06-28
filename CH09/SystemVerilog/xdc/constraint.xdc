set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets AIC_mclk_o_IBUF_inst/O]
set_false_path -from [get_pins {hw_i/audio/aic3104_poll_wrapper_0/inst/aic3104_poll/rx_ctrl_reg[0]/C}] -to [get_pins {hw_i/audio/aic3104_poll_wrapper_0/inst/aic3104_poll/rx_ctrl_sync_reg[0]/D}]
