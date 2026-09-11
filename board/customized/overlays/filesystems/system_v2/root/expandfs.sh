#!/bin/bash
#
# Grow the data partition to the end of the disk, then grow its filesystem to
# the end of the partition. Called from overlayroot2.sh in the early-boot
# chroot, before anything mounts the partition - every step below needs it
# unmounted.
#
# Ordering is the entire point of this script. ext4 must be checked *before*
# resize2fs touches it, and that is exactly how the data partition on testbot4
# was lost: the old version ran "resize2fs -f" first, it failed partway (its
# error went to stderr, which the caller was not even capturing), and the
# "e2fsck -f -y" that came afterwards dutifully "repaired" the result - cleared
# the root inode, reverted the block count - leaving a 100M filesystem inside a
# 117.5G partition. So: check, resize, check again, and never continue past a
# step that failed.
#
# The script decides for itself whether there is anything to do, by comparing
# what the kernel reports for the partition with what the superblock reports for
# the filesystem. That makes it idempotent and, more importantly, self-healing:
# a board left in the half-expanded state above fixes itself on the next boot.
# The caller used to own that decision with a "is the partition still exactly
# 100M" test, which stops being true the moment the partition is grown - so the
# one case that needed a retry was the one case that could never get one.
#
# Usage: expandfs.sh <mmc device> <data partition number>
#   e.g. expandfs.sh /mnt/dev/mmcblk0 4

set -u

MMC=${1:-}
DATAPART=${2:-}

log() { echo "expandfs: $*"; }
die() { echo "expandfs: ERROR: $*"; exit 1; }

if [[ -z ${MMC} ]]; then
	die "no mmc device given"
fi
if [[ -z ${DATAPART} ]]; then
	die "no partition with data labeled filesystem"
fi

## the caller passes the partition number, but tolerate a full device name too
PARTNUM=${DATAPART: -1}
DEV=${MMC}p${PARTNUM}
if [[ ! -b ${DEV} ]]; then
	die "${DEV} is not a block device"
fi

## bash builtins rather than basename/cat throughout: this runs in the early
## chroot before init, where PATH is whatever the caller happened to have
PARTNAME=${DEV##*/}
DISKNAME=${PARTNAME%p[0-9]*}

## sysfs is the kernel's own view of the geometry, which is what matters here:
## writing a partition table does not change it, only a BLKPG/BLKRRPART ioctl
## does, and this is where the result shows up. Under the pivot_root in
## overlayroot2.sh the old root - and with it the sysfs mount - lives at /mnt,
## hence the second candidate.
SYSBLK=
for _base in /sys/class/block /mnt/sys/class/block; do
	if [[ -r ${_base}/${PARTNAME}/size ]]; then
		SYSBLK=${_base}
		break
	fi
done
if [[ -z ${SYSBLK} ]]; then
	die "no sysfs entry for ${PARTNAME}, cannot read the partition geometry"
fi

## all sysfs block sizes are in 512-byte sectors regardless of the real sector size
SECT=512
DISK_SECTORS=$(<"${SYSBLK}/${DISKNAME}/size")
PART_START=$(<"${SYSBLK}/${PARTNAME}/start")
PART_SECTORS=$(<"${SYSBLK}/${PARTNAME}/size")

## 33 sectors for the GPT backup header and array, plus a 1MiB alignment slack
GPT_TAIL=33
SLACK=2048
FREE_TAIL=$((DISK_SECTORS - PART_START - PART_SECTORS - GPT_TAIL))

log "disk ${DISKNAME}: ${DISK_SECTORS} sectors"
log "partition ${PARTNAME}: start ${PART_START}, ${PART_SECTORS} sectors, ${FREE_TAIL} sectors free after it"

#######################################################################
## step 1: grow the partition, if the disk is bigger than the image was
#######################################################################
if [[ ${FREE_TAIL} -gt ${SLACK} ]]; then
	log "growing ${PARTNAME} to the end of ${DISKNAME}"
	## -N keeps the start, the type and the GPT name and only changes the
	## size, so nothing has to be deleted and recreated; "+" means "all the
	## remaining space". --force silences the complaint about the GPT backup
	## header still sitting where the smaller image left it - sfdisk writes a
	## fresh GPT covering the whole device, which is what relocates it.
	if ! echo ", +" | sfdisk -N "${PARTNUM}" --force "${MMC}"; then
		die "sfdisk failed to grow ${PARTNAME}, leaving the filesystem untouched"
	fi
	sync

	## sfdisk has written the table to disk, but the kernel is still exposing the
	## old geometry: it ends its run with BLKRRPART, which re-reads the *whole*
	## table and therefore fails with EBUSY on any disk that has a mounted
	## partition - and this script runs after the pivot_root in overlayroot2.sh,
	## with the rootfs mounted from this very disk, so it always fails:
	##
	##   Re-reading the partition table failed.: Device or resource busy
	##
	## partx -u resizes the single partition through BLKPG instead, which has no
	## such restriction. Without it the resize silently deferred to the next boot
	## (the disk table was right, the kernel disagreed, and step 1's check below
	## bailed out) - correct, but it made expansion take two boots. partprobe is
	## BLKRRPART again, so it is no use as a fallback; if partx is missing we let
	## the check below defer to the next boot, where the kernel reads the table
	## fresh at scan time and no ioctl is needed.
	## absolute paths, for the same reason the header gives for the builtins: PATH
	## in this chroot is whatever the caller happened to have
	PARTX=
	for _p in /sbin/partx /usr/sbin/partx /bin/partx /usr/bin/partx; do
		if [[ -x ${_p} ]]; then
			PARTX=${_p}
			break
		fi
	done
	if [[ -n ${PARTX} ]]; then
		log "telling the kernel about the new size of ${PARTNAME} (${PARTX} -u)"
		${PARTX} -u "${MMC}" || log "partx -u failed, deferring to the next boot"
	else
		log "no partx in this image, deferring the resize to the next boot"
	fi

	## re-read what the kernel now believes. If it did not take, stop here:
	## resizing a filesystem past the end of the partition the kernel exposes
	## is precisely the corruption this script exists to avoid.
	PART_SECTORS=$(<"${SYSBLK}/${PARTNAME}/size")
	log "kernel now reports ${PART_SECTORS} sectors for ${PARTNAME}"
	if [[ $((DISK_SECTORS - PART_START - PART_SECTORS - GPT_TAIL)) -gt ${SLACK} ]]; then
		die "the kernel still reports the old size for ${PARTNAME};" \
			"the filesystem is untouched, the next boot will retry"
	fi
else
	log "${PARTNAME} already reaches the end of ${DISKNAME}, nothing to repartition"
fi

#######################################################################
## step 2: is the filesystem already filling the partition?
#######################################################################
FS_BLOCKS=$(dumpe2fs -h "${DEV}" 2>/dev/null | sed -n 's/^Block count: *//p')
FS_BLKSIZE=$(dumpe2fs -h "${DEV}" 2>/dev/null | sed -n 's/^Block size: *//p')
if [[ -z ${FS_BLOCKS} || -z ${FS_BLKSIZE} ]]; then
	die "cannot read the superblock of ${DEV}"
fi

FS_BYTES=$((FS_BLOCKS * FS_BLKSIZE))
PART_BYTES=$((PART_SECTORS * SECT))
log "filesystem: ${FS_BLOCKS} blocks of ${FS_BLKSIZE} (${FS_BYTES} bytes) in a ${PART_BYTES} byte partition"

## Don't spend a full fsck on every boot chasing a gap too small to care about.
## One block group is (8 * blocksize) blocks, i.e. 128MiB at the usual 4K - and a
## gap that small only happens on a card barely larger than the image, where
## there is nothing to gain anyway. On anything real the gap is gigabytes.
GROW_THRESHOLD=$((8 * FS_BLKSIZE * FS_BLKSIZE))
if [[ $((PART_BYTES - FS_BYTES)) -lt ${GROW_THRESHOLD} ]]; then
	log "filesystem already fills ${PARTNAME}, nothing to resize"
	exit 0
fi

#######################################################################
## step 3: check, resize, check again
#######################################################################
## e2fsck exit codes are a bitmask: 1 = errors corrected, 2 = corrected and a
## reboot is advised, 4 = errors left uncorrected, 8 = operational error.
## Anything from 4 up means the filesystem is not in a state to be resized.
log "checking ${DEV} before the resize"
e2fsck -f -y "${DEV}"
RC=$?
if [[ ${RC} -ge 4 ]]; then
	die "e2fsck returned ${RC} on ${DEV}, refusing to resize a filesystem it could not repair"
fi
log "e2fsck returned ${RC}"

log "resizing the filesystem on ${DEV} to fill the partition"
if ! resize2fs "${DEV}"; then
	die "resize2fs failed on ${DEV}; the next boot will retry"
fi

log "checking ${DEV} after the resize"
e2fsck -f -y "${DEV}"
RC=$?
if [[ ${RC} -ge 4 ]]; then
	die "e2fsck returned ${RC} after resizing ${DEV}"
fi
sync

FS_BLOCKS=$(dumpe2fs -h "${DEV}" 2>/dev/null | sed -n 's/^Block count: *//p')
log "done: ${DEV} now has ${FS_BLOCKS} blocks of ${FS_BLKSIZE}"
exit 0
