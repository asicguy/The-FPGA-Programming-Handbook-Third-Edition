#!/usr/bin/env bash
# Compile and run the native VHDL testbench for aic3104_poll (Vivado xsim).
# Self-checking; a batch run prints PASS/FAIL and exits.
set -e
rm -rf xsim* .Xil

# glbl is needed because the design instantiates XPM (xpm_fifo_async) macros.
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v"

xvhdl --2008 \
  ../hdl/aic3104_poll.vhd \
  ../tb/tb_aic3104_poll.vhd

xelab --timescale 1ns/10ps --debug typical -L xpm tb_aic3104_poll glbl

# For waveforms, swap for: xsim -gui work.tb_aic3104_poll#work.glbl
xsim work.tb_aic3104_poll#work.glbl -runall
