#!/usr/bin/env bash
#
# Build the video_filter HLS component with the unified Vitis flow.
#
# Vitis 2024.2 and later do not ship a `vitis_hls` executable -- the standalone
# HLS tool was folded into Vitis. The equivalents are:
#
#     vitis_hls  csim_design    ->  vitis-run --mode hls --csim
#     vitis_hls  csynth_design  ->  v++ -c --mode hls
#     vitis_hls  cosim_design   ->  vitis-run --mode hls --cosim
#     vitis_hls  export_design  ->  vitis-run --mode hls --package
#
# All four read the same video_filter/hls_config.cfg, which replaces the old
# open_project / open_solution / set_part Tcl script.
#
# Usage:
#     ./build_hls.sh              csim, synth and package (no cosim)
#     ./build_hls.sh --cosim      also run RTL/C co-simulation (slow)
#     ./build_hls.sh --no-csim    skip C simulation
#
# Output IP repository (feed this to Vivado):
#     video_filter/hls/impl/ip

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

CFG=video_filter/hls_config.cfg
WORK=video_filter

RUN_CSIM=1
RUN_COSIM=0
for arg in "$@"; do
    case "$arg" in
        --cosim)   RUN_COSIM=1 ;;
        --no-csim) RUN_CSIM=0 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

if ! command -v v++ >/dev/null 2>&1; then
    echo "v++ not on PATH -- source your Vitis settings first, e.g." >&2
    echo "    source /opt/Xilinx/2025.2/Vitis/settings64.sh" >&2
    exit 1
fi

if [ "$RUN_CSIM" = 1 ]; then
    echo "==> C simulation (expect 'TEST PASSED')"
    vitis-run --mode hls --csim --config "$CFG" --work_dir "$WORK"
fi

echo "==> C synthesis"
v++ -c --mode hls --config "$CFG" --work_dir "$WORK"

if [ "$RUN_COSIM" = 1 ]; then
    echo "==> RTL/C co-simulation (this is the slow step)"
    vitis-run --mode hls --cosim --config "$CFG" --work_dir "$WORK"
fi

echo "==> Package for the Vivado IP catalog"
vitis-run --mode hls --package --config "$CFG" --work_dir "$WORK"

echo
echo "=========================================="
echo " IP repository for Vivado:"
echo "   $(pwd)/video_filter/hls/impl/ip"
echo " Next:  cd ../project2_video_sobel && vivado -mode batch -source build_bd.tcl -tclargs hls"
echo "=========================================="
