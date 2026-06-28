#!/usr/bin/env bash
# Compile and run the native VHDL testbench for aic3104_dma (Vivado xsim).
# The testbench is self-checking; a batch run prints PASS/FAIL and exits.
set -e
rm -rf xsim* .Xil

# glbl is needed because the design instantiates XPM (xpm_fifo_async) macros.
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v"

# VHDL-2008. Order: submodules -> top -> TB support models -> testbench.
xvhdl --2008 \
  ../hdl/axi_dma_writer.vhd \
  ../hdl/axi_dma_reader.vhd \
  ../hdl/aic3104_dma.vhd \
  ../tb/i2s_sine_gen.vhd \
  ../tb/axi_ram.vhd \
  ../tb/tb_aic3104.vhd

# -L xpm links the Xilinx XPM library; glbl supplies the Verilog globals XPM needs.
xelab --timescale 1ns/10ps --debug typical -L xpm tb_aic3104 glbl

# Batch run (TB calls std.env.finish at the end). For waveforms, swap for:
#   xsim -gui work.tb_aic3104#work.glbl
xsim work.tb_aic3104#work.glbl -runall
