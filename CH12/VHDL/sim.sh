#!/usr/bin/env bash
# Simulate the VHDL video filter with Vivado xsim.
#
# Mixed-language: the DUT is VHDL, the testbench is the same SystemVerilog one
# the other two implementations face -- referenced directly out of
# ../SystemVerilog/tb rather than copied, so the two implementations cannot
# drift apart in what they are tested against.
#
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   ./sim.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
mkdir -p build && cd build

xvhdl -nolog \
    ../hdl/sync_fifo.vhd \
    ../hdl/video_filter_ctrl.vhd \
    ../hdl/video_filter_rd.vhd \
    ../hdl/video_filter_wr.vhd \
    ../hdl/video_filter_core.vhd \
    ../hdl/video_filter.vhd

# dut_rtl.sv binds the VHDL entity too: xsim matches VHDL port names
# case-insensitively, and the lower-case names in the wrapper are the ones the
# entity declares.
xvlog -sv -nolog \
    ../../SystemVerilog/tb/dut_rtl.sv \
    ../../SystemVerilog/tb/tb_video_filter.sv

xelab -nolog -debug typical tb_video_filter -s tb_sim
xsim tb_sim -nolog -runall
