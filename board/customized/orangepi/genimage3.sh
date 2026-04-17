#!/bin/bash

linux_image()
{
        if grep -Eq "^BR2_LINUX_KERNEL_UIMAGE=y$" ${BR2_CONFIG}; then
                LINUX_IMAGE_TO_INSTALL=uImage
        elif grep -Eq "^BR2_LINUX_KERNEL_IMAGE=y$" ${BR2_CONFIG}; then
                LINUX_IMAGE_TO_INSTALL=Image
        elif grep -Eq "^BR2_LINUX_KERNEL_IMAGEGZ=y$" ${BR2_CONFIG}; then
                LINUX_IMAGE_TO_INSTALL=Image.gz
        else
                LINUX_IMAGE_TO_INSTALL=zImage
        fi
        echo "${LINUX_IMAGE_TO_INSTALL}"
}

uboot_image()
{
        if grep -Eq "^BR2_TARGET_UBOOT_FORMAT_DTB_IMX=y$" ${BR2_CONFIG}; then
                echo "u-boot-dtb.imx"
        elif grep -Eq "^BR2_TARGET_UBOOT_FORMAT_IMX=y$" ${BR2_CONFIG}; then
                echo "u-boot.imx"
        elif grep -Eq "^BR2_TARGET_UBOOT_FORMAT_DTB_IMG=y$" ${BR2_CONFIG}; then
            echo "u-boot-dtb.img"
        elif grep -Eq "^BR2_TARGET_UBOOT_FORMAT_IMG=y$" ${BR2_CONFIG}; then
            echo "u-boot.img"
        fi
}

set -e
export VERSION_TAG=$(git describe --tags --dirty=dirty)
export BOARD_DIR="$(dirname $0)"
BOARD_NAME="$(basename ${BOARD_DIR})"
echo "BINARIES_DIR=${BINARIES_DIR}"
echo "TARGET_DIR=${TARGET_DIR}"
SCRIPT_FULLPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOARD_FULLPATH=${SCRIPT_FULLPATH}/${BOARD_DIR}
export PLATFORM="orangepi"
export SRCDTBFILE=sun50i-h618-orangepi-zero3.dtb
export DTBFILE=sun50i-h618-orangepi-zero3.dtb
export KERNEL_IMAGE="$(linux_image)"
export BOOTFILES="\"active\", \"boot.scr\""
echo "boot files list: ${BOOTFILES}"
export SRCBOOTINIFILE=boot3.cmd
export BOOTINIFILE=boot.scr
export UBOOTBIN="$(uboot_image)"
export SDCARD_IMAGE=sdcard.img
board/customized/scripts/prepare_files.sh
if [ $? -ne 0 ]; then
        exit 1
fi

GENIMAGE_CFG="${BOARD_DIR}/genimage3.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
DATA_CFG="${BOARD_DIR}/data.cfg"

sed -i "s/%%%IMXOFFSET%%%/${IMXOFFSET}/g" ${GENIMAGE_CFG}
sed -i "s/%%%UBOOTBIN%%%/${UBOOTBIN}/g" ${GENIMAGE_CFG}
sed -i "s/%%%KERNEL_IMAGE%%%/${KERNEL_IMAGE}/g" ${GENIMAGE_CFG}
sed -i "s/%%%BOOTFILES%%%/${BOOTFILES}/g" ${GENIMAGE_CFG}
sed -i "s/%%%DTBFILE%%%/${DTBFILE}/g" ${GENIMAGE_CFG}
sed -i "s/%%%SDCARD_IMAGE%%%/${SDCARD_IMAGE}/g" ${GENIMAGE_CFG}

rm -rf "${GENIMAGE_TMP}"
rm -rf "${GENIMAGE_TMP}2"

genimage \
    --rootpath "${BINARIES_DIR}/fakedata/" \
    --tmppath "${GENIMAGE_TMP}2" \
    --inputpath "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config "${DATA_CFG}"

tune2fs -L rootfs1 ${BINARIES_DIR}/rootfs.ext2
cp ${BINARIES_DIR}/rootfs.ext2 ${BINARIES_DIR}/rootfs.ext2_slot2
tune2fs -L rootfs2 ${BINARIES_DIR}/rootfs.ext2_slot2
tune2fs -L data ${BINARIES_DIR}/data.ext4

genimage                           \
	--rootpath "${TARGET_DIR}"     \
	--tmppath "${GENIMAGE_TMP}"    \
	--inputpath "${BINARIES_DIR}"  \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"

if [ ! -z $VERSION_TAG ]; then
	if [ -f ${BINARIES_DIR}/$VERSION_TAG.tar.gz ]; then
	        rm ${BINARIES_DIR}/$VERSION_TAG.tar.gz
	fi
        tar czvf ${BINARIES_DIR}/$VERSION_TAG.tar.gz -C ${BINARIES_DIR} rootfs.ext2 ${KERNEL_IMAGE} ${DTBFILE} version.txt
fi

exit $?
