#!/bin/bash
set -u
if [[ -z ${KERNEL_IMAGE} ]]; then
        KERNEL_IMAGE=zImage
fi
#copy necessary files
if [[ ! -z ${SRCBOOTINIFILE} && ! -z ${BOOTINIFILE} ]]; then
        cp ${BOARD_DIR}/${SRCBOOTINIFILE} ${BINARIES_DIR}/${SRCBOOTINIFILE}
	mkimage -A arm -O linux -T script -C none -a 0x00000000 -e 0x00000000 -n "boot script" -d ${BINARIES_DIR}/${SRCBOOTINIFILE} ${BINARIES_DIR}/${BOOTINIFILE}
fi
echo -n "1" > ${BINARIES_DIR}/active
if [ ! -d ${BINARIES_DIR}/slot1 ]; then
       mkdir ${BINARIES_DIR}/slot1
fi
cp ${BINARIES_DIR}/${KERNEL_IMAGE} ${BINARIES_DIR}/slot1/${KERNEL_IMAGE}
cp ${BINARIES_DIR}/${SRCDTBFILE} ${BINARIES_DIR}/slot1/${DTBFILE}
echo ${VERSION_TAG} > ${BINARIES_DIR}/slot1/version.txt
if [ ! -d ${BINARIES_DIR}/slot2 ]; then
       mkdir ${BINARIES_DIR}/slot2
fi
cp ${BINARIES_DIR}/${KERNEL_IMAGE} ${BINARIES_DIR}/slot2/${KERNEL_IMAGE}
cp ${BINARIES_DIR}/${SRCDTBFILE} ${BINARIES_DIR}/slot2/${DTBFILE}
echo ${VERSION_TAG} > ${BINARIES_DIR}/slot2/version.txt
echo ${VERSION_TAG} > ${BINARIES_DIR}/version.txt

if [ ! -d ${BINARIES_DIR}/fakedata ]; then
       mkdir ${BINARIES_DIR}/fakedata
fi
