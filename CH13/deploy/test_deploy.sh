#!/usr/bin/env bash
#
# Unit tests for deploy.sh. No board is needed: ssh and scp are replaced by
# stubs on PATH, and a directory stands in for the board's filesystem, so the
# copy, the layout and the checksum check are all exercised for real.
#
#   ./test_deploy.sh            run every test
#   ./test_deploy.sh corrupt    run only tests whose name matches "corrupt"

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEPLOY_SRC="$HERE/deploy.sh"
FILTER="${1:-}"

pass=0
fail=0

# ---------------------------------------------------------------- sandbox ---

# Build a throwaway tree that looks like the repo, with the board's filesystem
# as a plain directory. Every artifact gets distinct content so that a file
# landing in the wrong place cannot pass a checksum comparison by accident.
setup() {
    TMP="$(mktemp -d)"
    FAKE_BOARD="$TMP/board"
    CALL_LOG="$TMP/calls"
    CH13="$TMP/repo/CH13"
    CH12="$TMP/repo/CH12"

    mkdir -p "$FAKE_BOARD" "$TMP/bin" "$CH13/deploy" \
             "$CH13/project_dfx_socket/out" \
             "$CH13/project_dfx_socket/dts" \
             "$CH13/project_dfx_socket/notebooks" \
             "$CH13/sw" "$CH12/sw"
    : > "$CALL_LOG"

    cp "$DEPLOY_SRC" "$CH13/deploy/deploy.sh"

    local f
    for f in dfx_socket.bit dfx_socket.hwh \
             socket_passthrough_partial.bit socket_sobel_partial.bit \
             socket_blur_partial.bit socket_threshold_partial.bit; do
        printf 'artifact %s\n' "$f" > "$CH13/project_dfx_socket/out/$f"
    done
    printf 'artifact dtbo\n' > "$CH13/project_dfx_socket/dts/dfx_socket.dtbo"
    printf 'artifact ipynb\n' \
        > "$CH13/project_dfx_socket/notebooks/ch13_dfx_socket.ipynb"
    for f in dfx_socket.py rm_ref.py test_dfx_socket.py test_rm_ref.py; do
        printf 'artifact %s\n' "$f" > "$CH13/sw/$f"
    done
    for f in ov5647.py ov5647_regs.py pixel_packer.py; do
        printf 'artifact %s\n' "$f" > "$CH12/sw/$f"
    done

    # ssh stub: log the call, then run the remote command against $FAKE_BOARD, with
    # absolute destination paths rewritten into the stand-in filesystem.
    cat > "$TMP/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$CALL_LOG"
[ "${FAKE_UNREACHABLE:-0}" = 1 ] && exit 255
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -t|-q) shift ;;
        -*) shift ;;
        *)  args+=("$1"); shift ;;
    esac
done
cmd="${args[*]:1}"
exec bash -c "${cmd//$FAKE_DEST/$FAKE_BOARD$FAKE_DEST}"
SSH_EOF

    # scp stub: log the call, copy into the stand-in filesystem. Setting
    # FAKE_CORRUPT to a basename damages that file in transit.
    cat > "$TMP/bin/scp" <<'SCP_EOF'
#!/usr/bin/env bash
echo "scp $*" >> "$CALL_LOG"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -q|-r|-p) shift ;;
        *)  args+=("$1"); shift ;;
    esac
done
n=${#args[@]}
remote="${args[n-1]#*:}"
mkdir -p "$FAKE_BOARD$remote"
for ((i = 0; i < n - 1; i++)); do
    cp "${args[i]}" "$FAKE_BOARD$remote/" || exit 1
done
if [ -n "${FAKE_CORRUPT:-}" ] && [ -e "$FAKE_BOARD$remote/$FAKE_CORRUPT" ]; then
    printf 'bit rot\n' >> "$FAKE_BOARD$remote/$FAKE_CORRUPT"
fi
exit 0
SCP_EOF

    chmod +x "$TMP/bin/ssh" "$TMP/bin/scp"

    DEST=/home/xilinx/ch13_dfx
    export CALL_LOG FAKE_BOARD FAKE_DEST="$DEST"
    export PATH="$TMP/bin:$PATH"
}

teardown() {
    unset FAKE_UNREACHABLE FAKE_CORRUPT
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Run deploy.sh in the sandbox. Output lands in $OUTPUT, status in $STATUS.
run_deploy() {
    OUTPUT="$("$CH13/deploy/deploy.sh" --dest "$DEST" "$@" 2>&1)"
    STATUS=$?
}

# ------------------------------------------------------------- assertions ---

it() {
    local name=$1
    if [ -n "$FILTER" ] && [[ $name != *"$FILTER"* ]]; then
        return 1
    fi
    CURRENT="$name"
    setup
    return 0
}

ok() {
    if [ "$1" = 0 ]; then
        pass=$((pass + 1))
        printf '  ok    %s\n' "$CURRENT"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n' "$CURRENT"
        printf '        %s\n' "$2"
        printf '        --- deploy.sh said ---\n'
        printf '%s\n' "${OUTPUT:-<no output>}" | sed 's/^/        /'
    fi
    teardown
}

# ------------------------------------------------------------------ tests ---

if it copies_every_artifact_to_the_board; then
    run_deploy
    missing=""
    for f in out/dfx_socket.bit \
             out/dfx_socket.hwh \
             out/dfx_socket.dtbo \
             out/socket_passthrough_partial.bit \
             out/socket_sobel_partial.bit \
             out/socket_blur_partial.bit \
             out/socket_threshold_partial.bit \
             sw/dfx_socket.py \
             sw/rm_ref.py \
             sw/test_dfx_socket.py \
             sw/test_rm_ref.py \
             sw/ov5647.py \
             sw/ov5647_regs.py \
             sw/pixel_packer.py \
             notebooks/ch13_dfx_socket.ipynb; do
        [ -f "$FAKE_BOARD$DEST/$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ]
    ok $? "did not arrive:$missing (exit $STATUS)"
fi

if it places_the_overlay_beside_its_bitstream; then
    # PYNQ matches an overlay to a bitstream by filename, so the .dtbo is only
    # found if it shares a directory and a basename with the .bit.
    run_deploy
    [ -f "$FAKE_BOARD$DEST/out/dfx_socket.dtbo" ] &&
        [ -f "$FAKE_BOARD$DEST/out/dfx_socket.bit" ]
    ok $? "the overlay is not in out/ next to dfx_socket.bit"
fi

if it places_sw_where_the_notebook_searches_for_it; then
    # The notebook runs in notebooks/ and searches ../sw for dfx_socket.py.
    run_deploy
    [ -f "$FAKE_BOARD$DEST/notebooks/../sw/dfx_socket.py" ]
    ok $? "notebooks/../sw/dfx_socket.py does not resolve"
fi

if it copies_the_camera_driver_from_ch12; then
    # The camera lives in the static region and survives a swap, so CH13's
    # notebook imports CH12's driver unchanged.
    run_deploy
    diff -q "$CH12/sw/ov5647.py" "$FAKE_BOARD$DEST/sw/ov5647.py" >/dev/null
    ok $? "ov5647.py was not copied from CH12/sw"
fi

if it aborts_when_the_static_bitstream_is_missing; then
    rm "$CH13/project_dfx_socket/out/dfx_socket.bit"
    run_deploy
    [ "$STATUS" -ne 0 ] && [[ $OUTPUT == *dfx_socket.bit* ]]
    ok $? "expected a non-zero exit naming dfx_socket.bit, got $STATUS"
fi

if it aborts_when_a_partial_bitstream_is_missing; then
    rm "$CH13/project_dfx_socket/out/socket_blur_partial.bit"
    run_deploy
    [ "$STATUS" -ne 0 ] && [[ $OUTPUT == *socket_blur_partial.bit* ]]
    ok $? "expected a non-zero exit naming the missing partial, got $STATUS"
fi

if it aborts_when_the_device_tree_overlay_is_missing; then
    # It is gitignored and built by make in dts/, so this is the common case
    # on a fresh clone and the message has to say how to fix it.
    rm "$CH13/project_dfx_socket/dts/dfx_socket.dtbo"
    run_deploy
    [ "$STATUS" -ne 0 ] && [[ $OUTPUT == *make* ]]
    ok $? "expected a non-zero exit telling the user to run make, got $STATUS"
fi

if it aborts_when_the_camera_driver_is_missing; then
    rm "$CH12/sw/ov5647.py"
    run_deploy
    [ "$STATUS" -ne 0 ] && [[ $OUTPUT == *ov5647.py* ]]
    ok $? "expected a non-zero exit naming ov5647.py, got $STATUS"
fi

if it aborts_before_copying_when_the_board_is_unreachable; then
    export FAKE_UNREACHABLE=1
    run_deploy
    # The probe must have been attempted and nothing copied after it: a run
    # that never reached ssh at all is a different failure, not this one.
    [ "$STATUS" -ne 0 ] && grep -q '^ssh ' "$CALL_LOG" &&
        ! grep -q '^scp ' "$CALL_LOG"
    ok $? "expected one ssh probe and no scp, log holds: $(cat "$CALL_LOG")"
fi

if it fails_when_a_bitstream_arrives_corrupted; then
    export FAKE_CORRUPT=dfx_socket.bit
    run_deploy
    [ "$STATUS" -ne 0 ] && [[ $OUTPUT == *checksum* ]]
    ok $? "expected a checksum failure, got exit $STATUS"
fi

if it honours_the_board_user_and_dest_overrides; then
    OUTPUT="$("$CH13/deploy/deploy.sh" --board 10.0.0.9 --user pynq \
                                       --dest "$DEST" 2>&1)"
    STATUS=$?
    grep -q 'pynq@10\.0\.0\.9' "$CALL_LOG"
    ok $? "the overrides never reached ssh/scp (exit $STATUS)"
fi

if it rejects_an_unknown_option; then
    run_deploy --wat
    [ "$STATUS" -ne 0 ] && [[ $OUTPUT == *--wat* ]]
    ok $? "expected a non-zero exit naming the bad option, got $STATUS"
fi

# ---------------------------------------------------------------- summary ---

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
