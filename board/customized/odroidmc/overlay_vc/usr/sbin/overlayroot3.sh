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
###########################################################################################################################
# create a writable fs to then create our mountpoints 
mount -t tmpfs inittemp /mnt
if [ $? -ne 0 ]; then
    fail "ERROR: could not create a temporary filesystem to mount the base filesystems for overlayfs"
fi
echo "temporary filesystem mounted"
###########################################################################################################################
mkdir /mnt/lower
mkdir /mnt/rw
#mount -t tmpfs root-rw /mnt/rw
#if [ $? -ne 0 ]; then
#    fail "ERROR: could not create tempfs for upper filesystem"
#fi
###########################################################################################################################
mkdir /mnt/rw/upper
mkdir /mnt/rw/work
mkdir /mnt/newroot
# mount root filesystem readonly 
rootDev=/dev/mmcblk1p2
rootFsType=ext4
blkid $rootDev
if [ $? -gt 0 ]; then
    fail "ERROR: could not locate the root device based on fstab"
fi
#echo "rootDEv = ${rootDev}, rootMountPoint = ${rootMountPoint}, rootFsType = ${rootFsType}"
mount -t ${rootFsType} -o ro ${rootDev} /mnt/lower
if [ $? -ne 0 ]; then
    fail "ERROR: could not ro-mount original root partition"
fi
echo "remounted original root partition"
overlayDev=/dev/mmcblk1p3
mount -t ${rootFsType} -o rw ${overlayDev} /mnt/rw
dataDev=/dev/mmcblk1p4
###########################################################################################################################
mount -t overlay -o lowerdir=/mnt/lower,upperdir=/mnt/rw/upperdir,workdir=/mnt/rw/workdir overlayfs-root /mnt/newroot
if [ $? -ne 0 ]; then
    fail "ERROR: could not mount overlayFS"
fi
echo "mounted overlayfs"
# create mountpoints inside the new root filesystem-overlay
mkdir -p /mnt/newroot/lower
mount --move /mnt/lower /mnt/newroot/lower
mkdir -p /mnt/newroot/rw
mount --move /mnt/rw /mnt/newroot/rw
# change to the new overlay root
cd /mnt/newroot
pivot_root . mnt
exec chroot . sh -c "$(cat <<END
#
#umount /mnt/mnt
umount /mnt/proc
#umount /mnt/dev
#umount /mnt
if [ ! -d "/media/data" ]; then
	mkdir /media/data
fi
mount -o rw,remount /lower
mount /mnt/dev/mmcblk1p4 /media/data
umount /mnt/dev
# continue with regular init
exec /sbin/init
END
)"
