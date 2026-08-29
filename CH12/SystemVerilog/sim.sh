#!/usr/bin/env bash
# Simulate the CH12 video filter with Vivado xsim.
#
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   ./sim.sh            the hand-written SystemVerilog
#   ./sim.sh --hls      the Verilog Vitis HLS generated
#
# Both bind the same testbench, tb/tb_video_filter.sv, through a per-DUT
# wrapper -- see tb/dut_rtl.sv for why a wrapper is needed at all.
#
# --hls stands in for C/RTL co-simulation. Cosim is worth running too
# (../HLS/build_hls.sh --cosim), but it proves a different thing: it checks HLS
# against its own C testbench, whereas this checks the generated RTL against
# the same stimulus and the same golden model the other two implementations
# face.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

USE_HLS=0
for arg in "$@"; do
    case "$arg" in
        --hls) USE_HLS=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# resolved before the cd into build/, so it is not relative to the wrong place
HLS_RTL="$PWD/../HLS/video_filter/hls/syn/verilog"

mkdir -p build && cd build

if [ "$USE_HLS" = 1 ]; then
    if [ ! -d "$HLS_RTL" ]; then
        echo "HLS RTL not found at $HLS_RTL" >&2
        echo "run ../HLS/build_hls.sh first" >&2
        exit 1
    fi
    xvlog -nolog "$HLS_RTL"/*.v
    xvlog -sv -nolog ../tb/dut_hls.sv ../tb/tb_video_filter.sv
else
    xvlog -sv -nolog \
        ../hdl/sync_fifo.sv \
        ../hdl/video_filter_ctrl.sv \
        ../hdl/video_filter_rd.sv \
        ../hdl/video_filter_wr.sv \
        ../hdl/video_filter_core.sv \
        ../hdl/video_filter.sv \
        ../tb/dut_rtl.sv \
        ../tb/tb_video_filter.sv
fi

# -debug typical keeps internal signals visible; an optimised-away signal takes
# the xsim kernel down rather than erroring cleanly.
xelab -nolog -debug typical tb_video_filter -s tb_sim
xsim tb_sim -nolog -runall
