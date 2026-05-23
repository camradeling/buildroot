#!/bin/sh
fail(){
	echo -e "$1"
	/bin/sh
}
###########################################################################################################################
# load module
echo "starting overlay script"
modprobe overlay
if [ $? -ne 0 ]; then
    fail "ERROR: missing overlay kernel module"
fi
echo "overlay module loaded"
###########################################################################################################################
# mount /proc
mount -t proc proc /proc
if [ $? -ne 0 ]; then
    fail "ERROR: could not mount proc"
fi
echo "proc filesystem mounted"
mount -t sysfs sys /sys
mount -t devtmpfs devt /dev
###########################################################################################################################
# create a writable fs to then create our mountpoints 
mount -t tmpfs inittemp /mnt
if [ $? -ne 0 ]; then
    fail "ERROR: could not create a temporary filesystem to mount the base filesystems for overlayfs"
fi
echo "temporary filesystem mounted"
###########################################################################################################################
mkdir /mnt/rw
###########################################################################################################################
mkdir /mnt/newroot
NEWROOT=/mnt/newroot
# default root device and mmcnum
rootDev=/dev/mmcblk1p2
mmcnum=1
rootFsType=ext4
CMDLINE=$(cat /proc/cmdline)
PARTRE="root=(\/dev\/mmcblk([0-9]*)p([0-9]*))"
if [[ ${CMDLINE} =~ ${PARTRE} ]]; then
	echo "root device is ${BASH_REMATCH[1]}"
	echo "mmcnum is ${BASH_REMATCH[2]}"
	mmcnum=${BASH_REMATCH[2]}
	rootDev=${BASH_REMATCH[1]}
fi
if [ $? -gt 0 ]; then
    fail "ERROR: could not locate the root device based on fstab"
fi
# Derive slot name from root partition number (p2=slot1, p3=slot2)
PARTNUM=${rootDev: -1}
if [ "${PARTNUM}" == "2" ]; then
    SLOTNAME=slot1
elif [ "${PARTNUM}" == "3" ]; then
    SLOTNAME=slot2
else
    SLOTNAME=slot1
fi
mkdir /mnt/${SLOTNAME}
mount -t ${rootFsType} -o ro ${rootDev} /mnt/${SLOTNAME}
if [ $? -ne 0 ]; then
    fail "ERROR: could not mount original root partition"
fi
echo "mounted original root partition"
mount -t tmpfs -o rw overlayfs /mnt/rw
if [ $? -ne 0 ]; then
    echo "ERROR: could not mount tmpfs as rw"
fi
echo "mounted tmpfs as overlay"
mkdir -p /mnt/rw/upperdir
mkdir -p /mnt/rw/workdir
###########################################################################################################################
mount -t overlay -o lowerdir=/mnt/${SLOTNAME},upperdir=/mnt/rw/upperdir,workdir=/mnt/rw/workdir overlayfs-root /mnt/newroot
if [ $? -ne 0 ]; then
    fail "ERROR: could not mount overlayFS"
fi
echo "mounted overlayfs"
BOOTPART="/dev/"
BOOTCHCK=$(${NEWROOT}/usr/sbin/blkid | grep "boot" | awk '{print $1}')
PARTRE="(\/dev\/mmcblk([0-9]*)p([0-9]*))"
if [[ ${BOOTCHCK} =~ ${PARTRE} ]]; then
	BOOTPART=${BOOTCHCK:0:$((${#BOOTCHCK}-1))}
fi
if [ ${BOOTPART} == "/dev/" ]; then
        echo "applying default bootpart name"
        BOOTPART=/dev/mmcblk${mmcnum}p1
fi
echo "BOOTPART = ${BOOTPART}"
DATAPART="/dev/"
DATACHCK=$(${NEWROOT}/usr/sbin/blkid | grep "data" | awk '{print $1}')
if [[ ${DATACHCK} =~ ${PARTRE} ]]; then
	DATAPART=${DATACHCK:0:$((${#DATACHCK}-1))}
fi
if [ ${DATAPART} == "/dev/" ]; then
        echo "applying default datapart name"
        DATAPART=/dev/mmcblk${mmcnum}p4
fi
echo "DATAPART = ${DATAPART}"
DATAPARTNUM=${DATAPART: -1}
# create mountpoints inside the new root filesystem-overlay
mkdir -p /mnt/newroot/${SLOTNAME}
mount --move /mnt/${SLOTNAME} /mnt/newroot/${SLOTNAME}
mkdir -p /mnt/newroot/rw
mount --move /mnt/rw /mnt/newroot/rw
#expand data fs if needed
if [ ! -d ${NEWROOT}/media/data ]; then
        mkdir ${NEWROOT}/media/data
fi
DATAPARTSIZE=$(${NEWROOT}/usr/sbin/fdisk -l /dev/mmcblk${mmcnum} | grep ${DATAPART} | awk '{print $5}')
echo "DATAPARTSIZE = ${DATAPARTSIZE}"
NEEDRESIZE=false
if [ ${DATAPARTSIZE} == "100M" ]; then
	NEEDRESIZE=true
fi
# change to the new overlay root
cd ${NEWROOT}
pivot_root . mnt
exec chroot . sh -c "$(cat <<END
##################################################### in pivot root ####################################################
umount /mnt/proc
mount -o rw,remount /${SLOTNAME}
echo "expanding data filesystem"
if [[ ${NEEDRESIZE} == "true" ]]; then
	/root/expandfs.sh /mnt/dev/mmcblk${mmcnum} ${DATAPARTNUM} > /root/expandfs.log
fi
echo "checking filesystems"
fsck -y /mnt${BOOTPART}
e2fsck -y /mnt${DATAPART}
echo "mounting data partition"
mount /mnt${DATAPART} /media/data
echo "syncing custom files"
if [[ ! -d /media/data/custometc ]]; then
	mkdir /media/data/custometc
	systemd-machine-id-setup
        cp /etc/machine-id /media/data/custometc/
fi
rsync -a /media/data/custometc/ /etc/
echo "switch to init"
exec /sbin/init
END
)"
