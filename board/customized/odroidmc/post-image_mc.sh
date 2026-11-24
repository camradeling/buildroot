#!/bin/sh
linux_image()
{
        if grep -Eq "^BR2_LINUX_KERNEL_UIMAGE=y$" ${BR2_CONFIG}; then
                LINUX_IMAGE_TO_INSTALL=uImage
        elif grep -Eq "^BR2_LINUX_KERNEL_IMAGE=y$" ${BR2_CONFIG}; then
                LINUX_IMAGE_TO_INSTALL=Image
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
export VERSION_TAG=$(git describe --tags --dirty=dirty)
export BOARD_DIR="$(dirname $0)"
SCRIPT_FULLPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOARD_FULLPATH=${SCRIPT_FULLPATH}/${BOARD_DIR}
echo "BINARIES_DIR=${BINARIES_DIR}"
echo "TARGET_DIR=${TARGET_DIR}"
echo "BOARD_FULLPATH=${BOARD_FULLPATH}"
export PLATFORM="odroid"
export SRCDTBFILE=exynos5422-odroidxu4.dtb
export DTBFILE=exynos5422-odroidxu4.dtb
export KERNEL_IMAGE=zImage
export BOOTFILES="\"bootok\", \"boot.scr\""
echo "boot files list: ${BOOTFILES}"
export SRCBOOTINIFILE=boot.ini
export BOOTINIFILE=boot.scr
export UBOOTBIN="$(uboot_image)"
export SDCARD_IMAGE=sdcard.img
#echo -n -e \\x01 > ${BINARIES_DIR}/bootok
cp ${BOARD_DIR}/boot.ini ${BINARIES_DIR}/boot.ini
board/customized/scripts/prepare_files.sh
if [ $? -ne 0 ]; then
        exit 1
fi
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
DATA_CFG="${BOARD_DIR}/data.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

sed -i "s/%%%IMXOFFSET%%%/${IMXOFFSET}/g" ${GENIMAGE_CFG}
sed -i "s/%%%UBOOTBIN%%%/${UBOOTBIN}/g" ${GENIMAGE_CFG}
sed -i "s/%%%KERNEL_IMAGE%%%/${KERNEL_IMAGE}/g" ${GENIMAGE_CFG}
sed -i "s/%%%BOOTFILES%%%/${BOOTFILES}/g" ${GENIMAGE_CFG}
sed -i "s/%%%DTBFILE%%%/${DTBFILE}/g" ${GENIMAGE_CFG}
sed -i "s/%%%SDCARD_IMAGE%%%/${SDCARD_IMAGE}/g" ${GENIMAGE_CFG}

rm -rf "${GENIMAGE_TMP}"
rm -rf "${GENIMAGE_TMP}2"

#genimage \
#    --rootpath "${BOARD_DIR}" \
#    --tmppath "${GENIMAGE_TMP}1" \
#    --inputpath "${BINARIES_DIR}" \
#    --outputpath "${BINARIES_DIR}" \
#    --config "${OVERLAY_CFG}"

genimage \
    --rootpath "${BOARD_DIR}" \
    --tmppath "${GENIMAGE_TMP}2" \
    --inputpath "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config "${DATA_CFG}"

tune2fs -L work ${BINARIES_DIR}/rootfs.ext2
cp ${BINARIES_DIR}/rootfs.ext2 ${BINARIES_DIR}/rootfs.ext2_recovery
tune2fs -L recovery ${BINARIES_DIR}/rootfs.ext2_recovery
tune2fs -L data ${BINARIES_DIR}/data.ext4

genimage \
    --rootpath "${TARGET_DIR}" \
    --tmppath "${GENIMAGE_TMP}" \
    --inputpath "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config "${GENIMAGE_CFG}"

dd if=${BOARD_DIR}/boot/bl1.bin.hardkernel		of=${BINARIES_DIR}/sdcard.img seek=1	conv=notrunc
dd if=${BOARD_DIR}/boot/bl2.bin.hardkernel.720k_uboot	of=${BINARIES_DIR}/sdcard.img seek=31	conv=notrunc
dd if=${BINARIES_DIR}/u-boot-dtb.bin			of=${BINARIES_DIR}/sdcard.img seek=63	conv=notrunc
dd if=${BOARD_DIR}/boot/tzsw.bin.hardkernel		of=${BINARIES_DIR}/sdcard.img seek=1503	conv=notrunc

if [ ! -z $VERSION_TAG ]; then
	if [ -f ${BINARIES_DIR}/$VERSION_TAG.tar.gz ]; then
                rm ${BINARIES_DIR}/$VERSION_TAG.tar.gz
        fi
        tar czvf ${BINARIES_DIR}/$VERSION_TAG.tar.gz -C ${BINARIES_DIR} rootfs.ext2 zImage ${DTBFILE} version.txt
fi
