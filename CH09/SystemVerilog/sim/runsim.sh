rm -rf xsim*
xvlog $XILINX_VIVADO/data/verilog/src/glbl.v
xvlog -sv ../hdl/aic3104.sv ../tb/tb_aic3104.sv ../tb/i2s_sine_gen.sv
xelab --timescale 1ns/10ps --debug all -L xpm tb_aic3104 glbl
xsim -gui work.tb_aic3104#work.glbl
