#!/usr/bin/env bash
# Simulate the CH13 DFX socket and its reconfigurable modules with Vivado xsim.
#
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   ./sim.sh --socket              the socket's AXI4-Lite control block
#   ./sim.sh --socket --negative   the same testbench against the known-bad
#                                  slave; this MUST fail, and if it passes the
#                                  testbench is worthless
#   ./sim.sh --rm <name>           one reconfigurable module against the golden
#                                  model: passthrough | sobel | blur | threshold
#   ./sim.sh --all                 every RM, then the socket and its negative
#                                  control. This is the gate before anything
#                                  reaches a build.
#
# The negative control is not a formality. Three of the CH13 spike's four board
# wedges were AXI slaves or drivers with no testbench behind them, and on
# ZynqMP a PL slave that never responds does not fault -- it stops the CPU with
# no panic and no console. See docs/ch13-plan.md §6.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

WHAT=""
NEGATIVE=0
RM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --socket)   WHAT=socket ;;
        --negative) NEGATIVE=1 ;;
        --rm)       WHAT=rm; RM="${2:-}"; shift ;;
        --all)      WHAT=all ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
if [ -z "$WHAT" ]; then echo "nothing selected -- try --socket, --rm <name> or --all" >&2; exit 1; fi

# --all re-invokes this script once per target rather than duplicating the
# logic, so there is one definition of how each target is run.
if [ "$WHAT" = all ]; then
    rc=0
    for rm in passthrough sobel blur threshold; do
        echo "######## RM $rm"
        "$0" --rm "$rm" >/dev/null 2>&1 || { echo "  FAILED"; rc=1; continue; }
        # the verdict line, not whatever happened to be at the end of the log
        grep -E "TEST PASSED|TEST FAILED" "build/sim_rm_$rm.log" || { echo "  NO VERDICT"; rc=1; }
        grep -c "PASS" "build/sim_rm_$rm.log" | sed "s/^/  cases passed: /"
    done
    echo "######## socket"
    "$0" --socket >/dev/null 2>&1 && echo "  PASS" || { echo "  FAILED"; rc=1; }
    echo "######## socket, negative control (must fail)"
    "$0" --socket --negative >/dev/null 2>&1 && echo "  correctly failed" || { echo "  DID NOT FAIL -- the testbench has no teeth"; rc=1; }
    exit $rc
fi

RM_SRC=""
if [ "$WHAT" = rm ]; then
    case "$RM" in
        passthrough) RM_DEF=RM_PASSTHROUGH; RM_SRC=hdl/rm_passthrough_core.sv ;;
        sobel)       RM_DEF=RM_SOBEL;       RM_SRC=hdl/rm_sobel_core.sv ;;
        blur)        RM_DEF=RM_BLUR;        RM_SRC=hdl/rm_blur_core.sv ;;
        threshold)   RM_DEF=RM_THRESHOLD;   RM_SRC=hdl/rm_threshold_core.sv ;;
        *) echo "unknown rm: '$RM' -- expected passthrough, sobel, blur or threshold" >&2; exit 1 ;;
    esac
fi

mkdir -p build && cd build

if [ "$WHAT" = rm ]; then
    xvlog -sv -nolog -d $RM_DEF \
        ../hdl/socket_ctrl.sv ../hdl/sync_fifo.sv \
        ../hdl/rm_axi_rd.sv ../hdl/rm_axi_wr.sv ../hdl/rm_shell.sv \
        ../$RM_SRC ../hdl/rm_$RM.sv \
        ../tb/rm_dut.sv ../tb/tb_rm.sv
    xelab -nolog -debug typical tb_rm -s tb_rm_sim
    xsim tb_rm_sim -nolog -runall | tee sim_rm_$RM.log
    if grep -q 'TEST PASSED' sim_rm_$RM.log; then echo "RESULT: PASS"; exit 0
    else echo "RESULT: FAIL"; exit 1; fi
fi

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
