#!/usr/bin/env bash
# Simulate the SystemVerilog streaming Sobel filter with Vivado xsim.
#
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   ./sim.sh          # the hand-written SystemVerilog
#   ./sim.sh --hls    # the Verilog Vitis HLS generated, same testbench
#
# --hls is what stands in for C/RTL co-simulation, which Vitis will not run on
# this design: cosim supports ap_ctrl_none only when the whole top level is a
# single II=1 pipeline. Running the generated RTL against this testbench checks
# the same thing, with the same stimulus the hand-written versions see.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

DUT=sv
for arg in "$@"; do
    case "$arg" in
        --hls) DUT=hls ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

if ! command -v xvlog >/dev/null 2>&1; then
    echo "xvlog not on PATH -- source your Vivado settings first, e.g." >&2
    echo "    source /opt/Xilinx/2025.2/Vivado/settings64.sh" >&2
    exit 1
fi

mkdir -p "build_$DUT" && cd "build_$DUT"

if [ "$DUT" = hls ]; then
    HLS_RTL=../../HLS/sobel_stream/hls/syn/verilog
    if [ ! -d "$HLS_RTL" ]; then
        echo "HLS output not found at CH12/HLS/sobel_stream/hls/syn/verilog" >&2
        echo "run CH12/HLS/build_hls.sh first" >&2
        exit 1
    fi
    xvlog -nolog "$HLS_RTL"/*.v
else
    xvlog -sv -nolog \
        ../hdl/axis_skid.sv \
        ../hdl/sobel_stream_ctrl.sv \
        ../hdl/sobel_stream_core.sv \
        ../hdl/sobel_stream.sv
fi

xvlog -sv -nolog ../tb/tb_sobel_stream.sv

# -debug typical keeps internal signals visible. An optimised-away signal takes
# the xsim kernel down rather than erroring cleanly, and the HLS RTL in
# particular is full of them.
xelab -nolog -debug typical tb_sobel_stream -s tb_sim
xsim tb_sim -nolog -runall
