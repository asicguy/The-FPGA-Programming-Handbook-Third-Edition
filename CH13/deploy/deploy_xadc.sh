#!/usr/bin/env bash
#
# Deploy the CH13 SYSMON project to an AUP-ZU3 running PYNQ.
#
#   ./deploy_xadc.sh                    # both destinations (see below)
#   ./deploy_xadc.sh --jupyter-only     # just the notebook tree
#   ./deploy_xadc.sh --harness-only     # just the test harness
#   ./deploy_xadc.sh --board 192.168.3.1 --user xilinx
#
# TWO DESTINATIONS, BECAUSE THEY ARE NOT INTERCHANGEABLE
#
#   ~/jupyter_notebooks/handbook/CH13   what Jupyter actually serves. A
#                                       notebook anywhere else is invisible in
#                                       the browser, however correct it is.
#                                       Layout mirrors the repository, with the
#                                       chapter's shared sw/ one level above
#                                       project_xadc_sysmon/.
#
#   ~/ch13_xadc                         a flat harness for running pytest over
#                                       ssh. Nothing serves it and nothing
#                                       should; it exists so the tests run
#                                       against the interpreter and numpy
#                                       version the notebooks use.
#
# The notebook resolves sw/ and the bitstream by SEARCHING candidate relative
# paths, which is what lets one file work from both layouts. Do not "simplify"
# that back to a fixed path.
#
# Nothing is started and nothing is reprogrammed; this only moves files. The
# notebook loads the bitstream itself.
#
# Prerequisites: SSH key auth to the board (ssh-copy-id) and the design built
# (project_xadc_sysmon/build.tcl).

set -euo pipefail

CH13="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PROJECT="$CH13/project_xadc_sysmon"

BOARD=192.168.3.1
USER_NAME=xilinx
JUPYTER_DEST=/home/xilinx/jupyter_notebooks/handbook/CH13
HARNESS_DEST=/home/xilinx/ch13_xadc
DO_JUPYTER=1
DO_HARNESS=1

usage() { sed -n '2,32p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --board)        BOARD=$2; shift 2 ;;
        --user)         USER_NAME=$2; shift 2 ;;
        --jupyter-dest) JUPYTER_DEST=$2; shift 2 ;;
        --harness-dest) HARNESS_DEST=$2; shift 2 ;;
        --jupyter-only) DO_HARNESS=0; shift ;;
        --harness-only) DO_JUPYTER=0; shift ;;
        -h|--help)      usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

# src | subdirectory under the harness | subdirectory under the Jupyter tree
#
# "-" means the file does not belong in that destination. The test suite and
# the diagnostic scripts go to the harness only: Jupyter needs what the
# notebook imports, and nothing else. sysmon.py lands in the CH13/sw that the
# DFX project already shares, alongside dfx_socket.py rather than replacing it.
FILES=(
    "$PROJECT/out/xadc_sysmon.bit|out|project_xadc_sysmon/out"
    "$PROJECT/out/xadc_sysmon.hwh|out|project_xadc_sysmon/out"
    "$PROJECT/notebooks/ch13_xadc_sysmon.ipynb|notebooks|project_xadc_sysmon/notebooks"
    "$CH13/sw/sysmon.py|sw|sw"
    "$CH13/sw/test_sysmon.py|sw|-"
    "$CH13/sw/check_activity.py|sw|-"
    "$CH13/sw/verify_map.py|sw|-"
    "$CH13/sw/scan_window.py|sw|-"
    "$CH13/sw/pot_sweep.py|sw|-"
    "$CH13/sw/check_notebook.py|sw|-"
)

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

echo "==> Checking the build is complete"
missing=0
for entry in "${FILES[@]}"; do
    src="$(field "$entry" 1)"
    if [ ! -f "$src" ]; then
        echo "missing $src" >&2
        missing=1
    fi
done
if [ "$missing" = 1 ]; then
    echo >&2
    echo "build what is missing first:" >&2
    echo "  vivado -mode batch -source $PROJECT/build.tcl" >&2
    exit 1
fi

SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
TARGET="$USER_NAME@$BOARD"

echo "==> Checking $TARGET is reachable"
ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" true 2>/dev/null || {
    echo "cannot reach $TARGET with key auth." >&2
    echo "  is the board powered up?   ping $BOARD" >&2
    echo "  set up a key:              ssh-copy-id $TARGET" >&2
    exit 1
}

# deploy_to <root> <field index for the subdirectory>
deploy_to() {
    local root="$1" col="$2"
    local subdirs=() entry sub src

    for entry in "${FILES[@]}"; do
        sub="$(field "$entry" "$col")"
        [ "$sub" = "-" ] && continue
        case " ${subdirs[*]-} " in *" $sub "*) ;; *) subdirs+=("$sub") ;; esac
    done

    echo "==> Copying to $TARGET:$root"
    local mkdirs=""
    for sub in "${subdirs[@]}"; do
        mkdirs+="mkdir -p '$root/$sub'; "
    done
    ssh "${SSH_OPTS[@]}" "$TARGET" "$mkdirs"

    local group=()
    for sub in "${subdirs[@]}"; do
        group=()
        for entry in "${FILES[@]}"; do
            [ "$(field "$entry" "$col")" = "$sub" ] && group+=("$(field "$entry" 1)")
        done
        scp -q "${SSH_OPTS[@]}" "${group[@]}" "$TARGET:$root/$sub/"
        echo "    $sub/  ${#group[@]} files"
    done

    # The board has no RTC -- its clock is not even monotonic across reboots --
    # so file timestamps are meaningless here. Checksums are the only honest
    # check. Compared as a sorted multiset, independent of how the remote
    # md5sum prints its paths.
    echo "==> Verifying $root"
    local local_paths=() remote_paths=()
    for entry in "${FILES[@]}"; do
        sub="$(field "$entry" "$col")"
        [ "$sub" = "-" ] && continue
        src="$(field "$entry" 1)"
        local_paths+=("$src")
        remote_paths+=("$root/$sub/$(basename "$src")")
    done

    local local_sums remote_sums
    local_sums="$(md5sum "${local_paths[@]}" | awk '{print $1}' | sort)"
    remote_sums="$(ssh "${SSH_OPTS[@]}" "$TARGET" "md5sum ${remote_paths[*]}" \
                       | awk '{print $1}' | sort)"

    if [ "$local_sums" != "$remote_sums" ]; then
        echo "checksum mismatch under $root -- do not run it" >&2
        diff <(printf '%s\n' "$local_sums") <(printf '%s\n' "$remote_sums") >&2 || true
        exit 1
    fi
    echo "    ${#local_paths[@]} files, md5 OK"
}

[ "$DO_JUPYTER" = 1 ] && deploy_to "$JUPYTER_DEST" 3
[ "$DO_HARNESS" = 1 ] && deploy_to "$HARNESS_DEST" 2

echo
echo "=========================================="
if [ "$DO_JUPYTER" = 1 ]; then
    echo " Notebook (this is what Jupyter serves):"
    echo "   handbook/CH13/project_xadc_sysmon/notebooks/ch13_xadc_sysmon.ipynb"
    echo
fi
if [ "$DO_HARNESS" = 1 ]; then
    echo " Tests:"
    echo "   ssh $TARGET 'cd $HARNESS_DEST/sw && \\"
    echo "     /usr/local/share/pynq-venv/bin/python3 -m pytest . -q'"
    echo
fi
echo "=========================================="
