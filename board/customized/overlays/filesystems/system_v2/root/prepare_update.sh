#!/bin/bash
ARCHNAME=${1}
ARCHPATH=/media/data/update

if [ ! -f "${ARCHPATH}/${ARCHNAME}.tar.gz" ]; then
    echo "no such file: ${ARCHPATH}/${ARCHNAME}.tar.gz"
    exit 1
fi

rm -rf "${ARCHPATH}/${ARCHNAME}"
mkdir "${ARCHPATH}/${ARCHNAME}"

if ! tar xzf "${ARCHPATH}/${ARCHNAME}.tar.gz" -C "${ARCHPATH}/${ARCHNAME}"; then
    echo "failed to unpack ${ARCHNAME}"
    exit 1
fi

if [ ! -d /media/boot ]; then
    echo "boot partition not mounted at /media/boot"
    exit 1
fi

echo "${ARCHPATH}/${ARCHNAME}" > /media/boot/needupdate
reboot
