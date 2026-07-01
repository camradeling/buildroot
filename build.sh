#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD_DIR="$SCRIPT_DIR/board/customized/orangepi"
JOBS=8

declare -A DEFCONFIG=(
    [orangepi]=testbot_defconfig
    [orangepi3]=testbot3_defconfig
)

declare -A DEFAULT_VARS=(
    [orangepi]="$BOARD_DIR/orangepi.vars"
    [orangepi3]="$BOARD_DIR/orangepi3.vars"
)

usage() {
    echo "Usage: $0 <target> [<target2> ...] [vars-file] [make-goal]"
    echo "Targets: ${!DEFCONFIG[*]}"
    echo "Examples:"
    echo "  $0 orangepi3"
    echo "  $0 orangepi orangepi3"
    echo "  $0 orangepi3 board/customized/orangepi/orangepi3-test.vars"
    echo "  $0 orangepi3 menuconfig"
    exit 1
}

[ $# -eq 0 ] && usage

TARGETS=()
VARS_OVERRIDE=""
MAKE_GOAL=""

for arg in "$@"; do
    if [[ -v DEFCONFIG["$arg"] ]]; then
        TARGETS+=("$arg")
    elif [ -f "$arg" ]; then
        VARS_OVERRIDE="$arg"
    else
        MAKE_GOAL="$arg"
    fi
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "Error: no valid target specified." >&2
    usage
fi

for TARGET in "${TARGETS[@]}"; do
    OUTDIR="$SCRIPT_DIR/output_${TARGET}"
    DEFCONF="${DEFCONFIG[$TARGET]}"
    VARS="${VARS_OVERRIDE:-${DEFAULT_VARS[$TARGET]}}"

    if [ ! -f "$VARS" ]; then
        echo "Error: vars file not found: $VARS" >&2
        exit 1
    fi

    BUSYUSER=$(ps aux | grep -v grep | grep -v " $$ " | grep -Fm1 "$OUTDIR" | awk '{print $1}' || true)
    if [[ -n "$BUSYUSER" && "$BUSYUSER" != "$USER" ]]; then
        echo "Skipping $TARGET: user $BUSYUSER is already building in $OUTDIR" >&2
        continue
    fi

    if [ ! -f "$OUTDIR/.config" ]; then
        echo "Initializing $TARGET ($DEFCONF)..."
        mkdir -p "$OUTDIR"
        make -C "$SCRIPT_DIR" O="$OUTDIR" "$DEFCONF"
    fi

    # shellcheck source=/dev/null
    source "$VARS"

    echo "Building $TARGET (output: output_${TARGET})..."
    if [ -n "$MAKE_GOAL" ]; then
        make -C "$SCRIPT_DIR" O="$OUTDIR" "$MAKE_GOAL"
    else
        make -C "$SCRIPT_DIR" O="$OUTDIR" -j"$JOBS"
    fi
done
