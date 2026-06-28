#!/usr/bin/env bash
# ============================================================================
#  build.sh  --  build the AIC3104 DMA HLS components with Vitis
#
#  Drives the unified-flow Tcl script run_hls.tcl to produce two IP-catalog
#  packages from src/:
#     dma_s2mm  (capture : AXI4-Stream -> DDR)   <- replaces axi_dma_writer.sv
#     dma_mm2s  (playback: DDR -> AXI4-Stream)   <- replaces axi_dma_reader.sv
#
#  Each component is generated under  src/<component>/  (as in the book's other
#  HLS chapters); the packaged IP zip lands at
#     src/<component>/hls/impl/ip/xilinx_com_hls_<component>_1_0.zip
#
#  Usage:
#     ./build.sh                 # csim + synth + package both components
#     ./build.sh --cosim         # also run C/RTL co-simulation
#     ./build.sh --no-csim       # synth + package only (skip C simulation)
#     ./build.sh s2mm            # build only dma_s2mm   (or: mm2s)
#     ./build.sh --clean         # remove generated component dirs
#
#  Environment overrides:
#     VITIS_SETTINGS  full path to a Vitis settings64.sh to source
#     VITIS_VERSION   version under /opt/Xilinx to use (e.g. 2025.2)
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"

# ---- options ---------------------------------------------------------------
RUN_CSIM=1
RUN_COSIM=0
COMPONENTS=""
for arg in "$@"; do
    case "$arg" in
        --cosim)    RUN_COSIM=1 ;;
        --no-csim)  RUN_CSIM=0 ;;
        --clean)    rm -rf "$SRC"/dma_s2mm "$SRC"/dma_mm2s "$HERE"/build
                    echo "Removed generated component directories"; exit 0 ;;
        s2mm|dma_s2mm) COMPONENTS="$COMPONENTS dma_s2mm" ;;
        mm2s|dma_mm2s) COMPONENTS="$COMPONENTS dma_mm2s" ;;
        -h|--help)  sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
COMPONENTS="${COMPONENTS:-dma_s2mm dma_mm2s}"

# ---- locate and source the Vitis environment -------------------------------
if ! command -v vitis-run >/dev/null 2>&1; then
    if [ -n "${VITIS_SETTINGS:-}" ]; then
        SETTINGS="$VITIS_SETTINGS"
    elif [ -n "${VITIS_VERSION:-}" ]; then
        SETTINGS="/opt/Xilinx/${VITIS_VERSION}/Vitis/settings64.sh"
    else
        SETTINGS="$(ls -d /opt/Xilinx/*/Vitis/settings64.sh 2>/dev/null | sort -V | tail -1 || true)"
    fi
    if [ -z "${SETTINGS:-}" ] || [ ! -f "$SETTINGS" ]; then
        echo "ERROR: could not find Vitis. Set VITIS_SETTINGS or VITIS_VERSION." >&2
        exit 1
    fi
    echo "Sourcing $SETTINGS"
    # shellcheck disable=SC1090
    source "$SETTINGS"
fi
echo "Using: $(command -v vitis-run)"
echo "Components: $COMPONENTS   (csim=$RUN_CSIM cosim=$RUN_COSIM)"

# ---- run the Tcl flow (relative source paths require cwd = src/) ------------
cd "$SRC"
export RUN_CSIM RUN_COSIM COMPONENTS
vitis-run --mode hls --tcl run_hls.tcl

echo
echo "Done. Packaged IP:"
for comp in $COMPONENTS; do
    zip="$SRC/$comp/hls/impl/ip/xilinx_com_hls_${comp}_1_0.zip"
    [ -f "$zip" ] && echo "  $zip"
done
