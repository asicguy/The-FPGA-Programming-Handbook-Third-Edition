#!/usr/bin/env bash
#
# Deploy the CH13 DFX socket to an AUP-ZU3 running PYNQ: the static bitstream,
# its device-tree overlay, all four partial bitstreams, the drivers and the
# demonstration notebook.
#
#   ./deploy.sh                                   # copy and verify
#   ./deploy.sh --board 192.168.3.1 --user xilinx
#   ./deploy.sh --dest /home/xilinx/ch13_dfx
#
# Nothing is started and no service is installed -- CH13 is driven from the
# notebook, not from a daemon. Nothing on the board is reprogrammed either;
# this only moves files.
#
# Prerequisites: SSH key auth to the board (ssh-copy-id), the design built
# (project_dfx_socket/build_impl.tcl) and the overlay compiled
# (make -C project_dfx_socket/dts).

set -euo pipefail

CH13="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PROJECT="$CH13/project_dfx_socket"

BOARD=192.168.3.1
USER_NAME=xilinx
DEST=/home/xilinx/ch13_dfx

usage() { sed -n '2,17p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD=$2; shift 2 ;;
        --user)  USER_NAME=$2; shift 2 ;;
        --dest)  DEST=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

# The notebook runs in notebooks/ and reaches for "../out" and "../sw", so the
# three directories below are not a matter of taste -- that layout is what lets
# ch13_dfx_socket.ipynb run on the board without editing a path.
#
# The .dtbo belongs in out/ with the bitstreams because PYNQ pairs an overlay
# to a bitstream by filename, and every partial belongs there too because
# swap_to() globs "*partial*.bit" out of the same directory.
FILES=(
    "$PROJECT/out/dfx_socket.bit|out"
    "$PROJECT/out/dfx_socket.hwh|out"
    "$PROJECT/dts/dfx_socket.dtbo|out"
    "$PROJECT/out/socket_passthrough_partial.bit|out"
    "$PROJECT/out/socket_sobel_partial.bit|out"
    "$PROJECT/out/socket_blur_partial.bit|out"
    "$PROJECT/out/socket_threshold_partial.bit|out"
    "$CH13/sw/dfx_socket.py|sw"
    "$CH13/sw/rm_ref.py|sw"
    "$CH13/sw/test_dfx_socket.py|sw"
    "$CH13/sw/test_rm_ref.py|sw"
    # The camera is in the static region, which is the whole reason it survives
    # a swap, so CH13 reuses CH12's driver unchanged. ov5647 imports the other
    # two, so all three travel together.
    "$CH13/../CH12/sw/ov5647.py|sw"
    "$CH13/../CH12/sw/ov5647_regs.py|sw"
    "$CH13/../CH12/sw/pixel_packer.py|sw"
    "$PROJECT/notebooks/ch13_dfx_socket.ipynb|notebooks"
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
    echo "  vivado -mode batch -source $PROJECT/build_impl.tcl   # bitstreams" >&2
    echo "  make -C $PROJECT/dts                                 # .dtbo" >&2
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
# Hashes are compared as a sorted multiset, which is independent of how the
# remote md5sum prints its paths.
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
    echo "  host  : $(printf '%s\n' "$local_sums"  | wc -l) files" >&2
    echo "  board : $(printf '%s\n' "$remote_sums" | wc -l) files" >&2
    diff <(printf '%s\n' "$local_sums") <(printf '%s\n' "$remote_sums") >&2 || true
    exit 1
fi
echo "    ${#FILES[@]} files, md5 OK"

# Both of these silently ruin a run rather than failing it, so they are worth
# saying out loud. Neither is touched here: stopping a service or killing an X
# session is the operator's call, not a deploy script's.
echo "==> Checking for things that fight the demonstration"
ssh "${SSH_OPTS[@]}" "$TARGET" '
    if systemctl is-active --quiet ch11-dp 2>/dev/null; then
        echo "    WARNING: ch11-dp is running. It drives CH11'"'"'s bitstream, so"
        echo "             reprogramming the PL points its register reads at"
        echo "             hardware that no longer exists."
        echo "             sudo systemctl stop ch11-dp"
    fi
    if fuser /dev/dri/card0 >/dev/null 2>&1; then
        echo "    WARNING: something holds DRM master on /dev/dri/card0, so"
        echo "             DisplayPort output will do nothing, silently."
        echo "             fuser -v /dev/dri/card0"
    fi
' 2>/dev/null || true

echo
echo "=========================================="
echo " Deployed to $TARGET:$DEST"
echo
echo " Run the notebook:"
echo "   the bitstream and overlay are in out/, the drivers in sw/,"
echo "   and ch13_dfx_socket.ipynb finds both by relative path."
echo
echo " Run the tests on the board:"
echo "   ssh $TARGET 'cd $DEST/sw && python3 -m pytest -q'"
echo "=========================================="
