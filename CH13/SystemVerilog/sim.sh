#!/usr/bin/env bash
# Simulate the CH13 DFX socket and its reconfigurable modules with Vivado xsim.
#
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   ./sim.sh --socket              the socket's AXI4-Lite control block
#   ./sim.sh --socket --negative   the same testbench against the known-bad
#                                  slave; this MUST fail, and if it passes the
#                                  testbench is worthless
#
# The negative control is not a formality. Three of the CH13 spike's four board
# wedges were AXI slaves or drivers with no testbench behind them, and on
# ZynqMP a PL slave that never responds does not fault -- it stops the CPU with
# no panic and no console. See docs/ch13-plan.md §6.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

WHAT=""
NEGATIVE=0
for arg in "$@"; do
    case "$arg" in
        --socket)   WHAT=socket ;;
        --negative) NEGATIVE=1 ;;
        -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done
if [ -z "$WHAT" ]; then echo "nothing selected -- try --socket" >&2; exit 1; fi

mkdir -p build && cd build

if [ "$WHAT" = socket ]; then
    if [ "$NEGATIVE" = 1 ]; then
        xvlog -sv -nolog -d NEGATIVE_CONTROL \
            ../tb/socket_ctrl_broken.sv ../tb/tb_socket_ctrl.sv
    else
        xvlog -sv -nolog ../hdl/socket_ctrl.sv ../tb/tb_socket_ctrl.sv
    fi
    xelab -nolog -debug typical tb_socket_ctrl -s tb_socket
    # The testbench decides pass or fail and says so; the exit status of xsim
    # does not, so grep for the verdict rather than trusting $?.
    xsim tb_socket -nolog -runall | tee sim_socket.log
    if grep -q '^PASS' sim_socket.log && ! grep -q '^FAIL' sim_socket.log; then
        echo "RESULT: PASS"
        [ "$NEGATIVE" = 1 ] && { echo "  but this was the NEGATIVE control -- the testbench has no teeth"; exit 1; }
        exit 0
    else
        echo "RESULT: FAIL"
        [ "$NEGATIVE" = 1 ] && { echo "  which is correct: the negative control is meant to fail"; exit 0; }
        exit 1
    fi
fi
