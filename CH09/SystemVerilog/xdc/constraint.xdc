set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets AIC_mclk_o_IBUF_inst/O]
set_false_path -from [get_pins {hw_i/audio/aic3104_poll_wrapper_0/inst/aic3104_poll/rx_ctrl_reg[0]/C}] -to [get_pins {hw_i/audio/aic3104_poll_wrapper_0/inst/aic3104_poll/rx_ctrl_sync_reg[0]/D}]
set_max_delay -from [get_pins {hw_i/audio/aic3104_*_wrapper_0/inst/aic3104_*/rx_dly_reg[?]/C}] -to [get_pins {hw_i/audio/aic3104_*_wrapper_0/inst/aic3104_*/rx_dly_meta_reg[?]/D}] 5.0
set_max_delay -from [get_pins {hw_i/rst_ps8_0_96M/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N/C}] -to [get_pins {hw_i/audio/aic3104_*_wrapper_0/inst/aic3104_poll/rst_sync_reg[0]/D}] 5.0
set_max_delay -from [get_pins {hw_i/rst_ps8_0_96M/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N/C}] -to [get_pins {hw_i/audio/aic3104_dma_wrapper_0/inst/aic3104_dma/rst_sync_reg[0]/D}] 5.0
set_max_delay -from [get_pins hw_i/audio/aic3104_dma_wrapper_0/inst/aic3104_dma/axi_dma_writer/sts_busy_reg/C] -to [get_pins {hw_i/audio/aic3104_dma_wrapper_0/inst/aic3104_dma/rx_en_reg[0]/D}] 5.0
