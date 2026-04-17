#!/bin/bash
set -e
UPDIR=${1}
TARGET_PART=${2}
TARGET_BOOTDIR=${3}

if [[ -z "${UPDIR}" || -z "${TARGET_PART}" || -z "${TARGET_BOOTDIR}" ]]; then
    echo "Usage: reflashfs.sh <update_dir> <target_partition> <boot_slot_dir>"
    exit 1
fi

if [ ! -f "${UPDIR}/rootfs.ext2" ]; then
    echo "ERROR: rootfs.ext2 not found in ${UPDIR}"
    exit 1
fi

# Verify checksum if provided
if [ -f "${UPDIR}/rootfs.sha256" ]; then
    echo "Verifying rootfs checksum..."
    sha256sum -c "${UPDIR}/rootfs.sha256" || { echo "ERROR: rootfs checksum mismatch"; exit 1; }
fi

# Copy kernel files to target boot slot (staged as .new until dd completes)
cp "${UPDIR}/zImage"      /media/boot/${TARGET_BOOTDIR}/zImage.new
cp "${UPDIR}"/*.dtb       /media/boot/${TARGET_BOOTDIR}/
cp "${UPDIR}/version.txt" /media/boot/${TARGET_BOOTDIR}/version.txt
sync

# Flash rootfs — active marker is NOT flipped until this returns successfully
echo "Flashing rootfs to ${TARGET_PART}..."
dd if="${UPDIR}/rootfs.ext2" of="${TARGET_PART}" bs=1M conv=fsync
echo "Rootfs flashed."

# Finalize kernel file (atomic rename from staged .new)
mv /media/boot/${TARGET_BOOTDIR}/zImage.new /media/boot/${TARGET_BOOTDIR}/zImage
sync

# Remove update source
rm -r "${UPDIR}"
