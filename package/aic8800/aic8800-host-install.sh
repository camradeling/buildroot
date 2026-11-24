#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/output_orangepi3/build"
SRC_DIR=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "host-aic8800-*" | head -1)

if [ -z "$SRC_DIR" ]; then
    echo "ERROR: host-aic8800 build directory not found. Run 'make O=output_orangepi3 host-aic8800-rebuild' first."
    exit 1
fi

KVER=$(uname -r)
MOD_DIR="/lib/modules/$KVER/kernel/drivers/net/wireless/aic8800"
FW_DIR="/lib/firmware/aic8800_fw/USB"

echo "Installing aic8800 modules for kernel $KVER"

mkdir -p "$MOD_DIR"
install -m 0644 "$SRC_DIR/src/USB/driver_fw/drivers/aic8800/aic_load_fw/aic_load_fw.ko" "$MOD_DIR/"
install -m 0644 "$SRC_DIR/src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko" "$MOD_DIR/"

echo "Installing firmware to /lib/firmware"
cp -a "$SRC_DIR/src/USB/driver_fw/fw/"* /lib/firmware/

echo "Running depmod..."
depmod -a "$KVER"

echo "Done. Load with:"
echo "  modprobe aic_load_fw"
echo "  modprobe aic8800_fdrv"
