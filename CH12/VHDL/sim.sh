#!/usr/bin/env bash
# Simulate the VHDL streaming Sobel filter with Vivado xsim.
#
# Mixed-language: the DUT is VHDL and the testbench is the SystemVerilog one
# from ../SystemVerilog/tb, used unmodified. Not copied -- referenced, so the
# two implementations cannot drift apart in what they are tested against.
# Identical stimulus and identical golden model, so a pass here means the VHDL
# agrees with the SystemVerilog, with the HLS RTL and with the C simulation.
#
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   ./sim.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

if ! command -v xvhdl >/dev/null 2>&1; then
    echo "xvhdl not on PATH -- source your Vivado settings first, e.g." >&2
    echo "    source /opt/Xilinx/2025.2/Vivado/settings64.sh" >&2
    exit 1
fi

mkdir -p build && cd build

xvhdl -nolog \
    ../hdl/axis_skid.vhd \
    ../hdl/sobel_stream_ctrl.vhd \
    ../hdl/sobel_stream_core.vhd \
    ../hdl/sobel_stream.vhd

xvlog -sv -nolog ../../SystemVerilog/tb/tb_sobel_stream.sv

xelab -nolog -debug typical tb_sobel_stream -s tb_sim
xsim tb_sim -nolog -runall
