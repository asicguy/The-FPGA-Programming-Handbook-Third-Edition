#!/usr/bin/env bash
#
# Deploy the CH13 SYSMON project to an AUP-ZU3 running PYNQ: the bitstream,
# its .hwh, the driver and the demonstration notebook.
#
#   ./deploy_xadc.sh                                  # copy and verify
#   ./deploy_xadc.sh --board 192.168.3.1 --user xilinx
#   ./deploy_xadc.sh --dest /home/xilinx/ch13_xadc
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
DEST=/home/xilinx/ch13_xadc

usage() { sed -n '2,15p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD=$2; shift 2 ;;
        --user)  USER_NAME=$2; shift 2 ;;
        --dest)  DEST=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

# The notebook runs in notebooks/ and reaches for "../out" and "../sw", so this
# layout is not a matter of taste -- it is what lets the notebook run on the
# board without editing a path. PYNQ also pairs a .hwh to a .bit by basename,
# so those two must keep matching names.
FILES=(
    "$PROJECT/out/xadc_sysmon.bit|out"
    "$PROJECT/out/xadc_sysmon.hwh|out"
    "$CH13/sw/sysmon.py|sw"
    "$CH13/sw/test_sysmon.py|sw"
    "$CH13/sw/check_activity.py|sw"
    "$CH13/sw/verify_map.py|sw"
    "$CH13/sw/scan_window.py|sw"
    "$PROJECT/notebooks/ch13_xadc_sysmon.ipynb|notebooks"
)

echo "==> Checking the build is complete"
missing=0
for entry in "${FILES[@]}"; do
    src="${entry%%|*}"
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

echo "==> Copying to $TARGET:$DEST"
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p $DEST/out $DEST/sw $DEST/notebooks"
for subdir in out sw notebooks; do
    group=()
    for entry in "${FILES[@]}"; do
        [ "${entry##*|}" = "$subdir" ] && group+=("${entry%%|*}")
    done
    scp -q "${SSH_OPTS[@]}" "${group[@]}" "$TARGET:$DEST/$subdir/"
    echo "    $subdir/  ${#group[@]} files"
done

echo "==> Verifying every file arrived intact"
# The board has no RTC -- its clock is not even monotonic across reboots -- so
# file timestamps are meaningless here. Checksums are the only honest check.
remote_paths=()
local_paths=()
for entry in "${FILES[@]}"; do
    src="${entry%%|*}"
    local_paths+=("$src")
    remote_paths+=("$DEST/${entry##*|}/$(basename "$src")")
done

local_sums="$(md5sum "${local_paths[@]}" | awk '{print $1}' | sort)"
remote_sums="$(ssh "${SSH_OPTS[@]}" "$TARGET" "md5sum ${remote_paths[*]}" \
                   | awk '{print $1}' | sort)"

if [ "$local_sums" != "$remote_sums" ]; then
    echo "checksum mismatch -- the copy is not trustworthy, do not run it" >&2
    diff <(printf '%s\n' "$local_sums") <(printf '%s\n' "$remote_sums") >&2 || true
    exit 1
fi
echo "    ${#FILES[@]} files, md5 OK"

echo
echo "=========================================="
echo " Deployed to $TARGET:$DEST"
echo
echo " Run the notebook:  notebooks/ch13_xadc_sysmon.ipynb"
echo " Run the tests:     ssh $TARGET 'cd $DEST/sw && \\"
echo "                      /usr/local/share/pynq-venv/bin/python3 -m pytest . -q'"
echo "=========================================="
