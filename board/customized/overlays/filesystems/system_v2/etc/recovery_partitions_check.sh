#!/bin/bash
CURRENT_SLOT=$(/root/get_active.sh)

if [[ "${CURRENT_SLOT}" == "1" ]]; then
    INACTIVE_SLOT=2
    INACTIVE_PART=/dev/mmcblk${mmcdev}p3
    INACTIVE_BOOTDIR=slot2
else
    INACTIVE_SLOT=1
    INACTIVE_PART=/dev/mmcblk${mmcdev}p2
    INACTIVE_BOOTDIR=slot1
fi

if [ ! -f /media/boot/needupdate ]; then
    exit 0
fi

# Safety: verify we are not about to flash our own lower mount
ROOTPART=$(lsblk -o NAME,MOUNTPOINT | grep lower | awk '{print $1}')
ROOTPART=/dev/${ROOTPART:2:$((${#ROOTPART}-2))}
if [[ "${ROOTPART}" == "${INACTIVE_PART}" ]]; then
    echo "ERROR: inactive slot ${INACTIVE_PART} appears to be our running lower mount. Aborting."
    exit 1
fi

# Detect mmcdev from current root partition
PARTRE="\/mmcblk([0-9]*)p.*"
if [[ ${ROOTPART} =~ ${PARTRE} ]]; then
    mmcdev=${BASH_REMATCH[1]}
else
    mmcdev=0
fi

# Re-compute inactive partition with correct mmcdev
if [[ "${CURRENT_SLOT}" == "1" ]]; then
    INACTIVE_PART=/dev/mmcblk${mmcdev}p3
else
    INACTIVE_PART=/dev/mmcblk${mmcdev}p2
fi

UPDIR=$(cat /media/boot/needupdate)

# Validate path is within expected location
if [[ "${UPDIR}" != /media/data/update/* ]]; then
    echo "ERROR: needupdate path '${UPDIR}' is outside /media/data/update/. Aborting."
    exit 1
fi

/root/reflashfs.sh "${UPDIR}" "${INACTIVE_PART}" "${INACTIVE_BOOTDIR}" && \
    /root/set_active.sh "${INACTIVE_SLOT}" && \
    rm /media/boot/needupdate && \
    reboot
