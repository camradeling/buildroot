# Plan 001 — OTA A/B Schema Redesign

## Context

Current OTA schema uses an asymmetric A/B approach with a one-shot boot watchdog:
- p2 is a sacred golden/recovery image, never OTA-touched
- p3 is the OTA target, only booted when a `bootok` flag byte = 0x01
- U-Boot clears the flag before handoff; userspace must re-arm it or the next boot falls back to p2

This plan replaces it with a **symmetric A/B schema** with a persistent active marker.

## Goals

- U-Boot simply reads which slot is active and boots it — no flag clearing, no watchdog
- Both rootfs partitions are equal peers (rootfs1, rootfs2)
- Update flashes to the inactive slot, then flips the active marker
- Remove "golden partition" asymmetry and all watchdog machinery
- Rename partitions: rootfs / rootfs_recovery → rootfs1 / rootfs2 everywhere

## New Boot Flow

```
determine active slot (1 or 2)
  → U-Boot loads kernel from slot1/ or slot2/ on FAT
  → passes root=/dev/mmcblk0p2 or p3 to kernel
  → overlayroot2.sh mounts that partition read-only as lower layer
  → systemd starts normally
```

## New Update Flow

```
1. prepare_update.sh <archname>
     unpack tarball from /media/data/update/
     write path to /media/boot/needupdate
     reboot

2. rc.local → recovery_partitions_check.sh
     detect current active slot
     determine inactive slot + partition + boot dir
     call reflashfs.sh <updir> <inactive_part> <inactive_bootdir>

3. reflashfs.sh
     verify checksum (sha256)
     cp kernel files to /media/boot/slotN/
     dd rootfs.ext2 → inactive partition (conv=fsync)
     return success

4. recovery_partitions_check.sh (after reflashfs returns 0)
     set_active.sh <inactive_slot>   ← marker flipped HERE, after full dd
     rm /media/boot/needupdate
     reboot

5. U-Boot reads active = new slot → boots new rootfs
```

Power-fail safety: if power fails before step 4, active marker still points to old slot. Safe.

---

## Files to Change

| File | Change |
|------|--------|
| `board/customized/orangepi/genimage.cfg` | Rename partition labels; rename `default/`→`slot1/`, `updated/`→`slot2/` in boot FAT |
| `board/customized/orangepi/boot.cmd` | Rewrite: read `active` file, select slot, no fatwrite |
| `board/customized/orangepi/boot3.cmd` | Same as boot.cmd for Zero3 |
| `overlays/filesystems/system_v2/etc/recovery_partitions_check.sh` | Major rewrite: remove watchdog, add slot detection |
| `overlays/filesystems/system_v2/root/reflashfs.sh` | Slot-aware args, add `set -e`, add checksum, cp→dd ordering fix |
| `overlays/filesystems/system_v2/root/prepare_update.sh` | Fix inverted tar check, remove dropflag call |
| `overlays/filesystems/system_v2/root/setflag.sh` | Replace with `set_active.sh` |
| `overlays/filesystems/system_v2/root/dropflag.sh` | Delete |
| `overlays/filesystems/system_v2/root/getflag.sh` | Replace with `get_active.sh` |
| `overlays/filesystems/system_v2/root/getrazdel.sh` | Update partition detection to use rootfs1/rootfs2 labels |
| `overlays/filesystems/system_v2/etc/systemd/system/syncfiles.service` | Fix undefined `${PID_FILE}` |

---

## Step-by-Step Implementation

### Step 1 — `genimage.cfg`: rename partitions and kernel dirs

```
partition rootfs_ro  → partition rootfs1  (GPT label "rootfs1")
partition rootfs_new → partition rootfs2  (GPT label "rootfs2")

FAT boot partition contents:
  bootok           → active          (ASCII "1" or "2")
  default/zImage   → slot1/zImage
  default/*.dtb    → slot1/*.dtb
  default/version.txt → slot1/version.txt
  updated/zImage   → slot2/zImage
  updated/*.dtb    → slot2/*.dtb
  updated/version.txt → slot2/version.txt
```

### Step 2 — `boot.cmd`: persistent active marker, no flag clearing

```bash
setenv fdt_high ffffffff

# Default to slot1 if active file is missing or unreadable
setenv bootslot slot1
setenv rootpart /dev/mmcblk0p2

if fatload mmc 0:1 ${kernel_addr_r} active 1; then
    if itest.b *${kernel_addr_r} == 0x32; then
        setenv bootslot slot2
        setenv rootpart /dev/mmcblk0p3
    fi
fi

setenv bootargs "console=ttyS0,115200 earlyprintk root=${rootpart} rootwait init=/sbin/overlayroot2.sh"
fatload mmc 0 ${kernel_addr_r} ${bootslot}/zImage
fatload mmc 0 ${fdt_addr_r} ${bootslot}/sun8i-h2-plus-orangepi-zero.dtb
bootz ${kernel_addr_r} - ${fdt_addr_r}
```

Key: no `fatwrite` — U-Boot never modifies the active marker.
Fallback: if `active` file is missing, slot1 is used by default.

### Step 3 — New `set_active.sh` and `get_active.sh`

**`set_active.sh`** (replaces setflag.sh + dropflag.sh):
```bash
#!/bin/bash
SLOT=${1}
if [[ "${SLOT}" != "1" && "${SLOT}" != "2" ]]; then
    echo "Usage: set_active.sh <1|2>"
    exit 1
fi
echo -n "${SLOT}" > /media/boot/active
sync
```

**`get_active.sh`** (replaces getflag.sh):
```bash
#!/bin/bash
SLOT=$(cat /media/boot/active 2>/dev/null)
if [[ "${SLOT}" != "1" && "${SLOT}" != "2" ]]; then
    echo "WARNING: active marker missing or invalid, defaulting to slot1" >&2
    echo "1"
else
    echo "${SLOT}"
fi
```

### Step 4 — `recovery_partitions_check.sh`: rewrite

```bash
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
```

### Step 5 — `reflashfs.sh`: slot-aware, robust

```bash
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

# Copy kernel files to target boot slot (source preserved until dd completes)
cp "${UPDIR}/zImage"      /media/boot/${TARGET_BOOTDIR}/zImage.new
cp "${UPDIR}"/*.dtb       /media/boot/${TARGET_BOOTDIR}/
cp "${UPDIR}/version.txt" /media/boot/${TARGET_BOOTDIR}/version.txt
sync

# Flash rootfs — active marker is NOT flipped until this returns successfully
echo "Flashing rootfs to ${TARGET_PART}..."
dd if="${UPDIR}/rootfs.ext2" of="${TARGET_PART}" bs=1M conv=fsync
echo "Rootfs flashed."

# Finalize kernel file (rename from .new to final name)
mv /media/boot/${TARGET_BOOTDIR}/zImage.new /media/boot/${TARGET_BOOTDIR}/zImage
sync

# Remove update source
rm -r "${UPDIR}"
```

### Step 6 — `prepare_update.sh`: fix tar check, remove dropflag

```bash
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
```

### Step 7 — `getrazdel.sh`: update detection

```bash
#!/bin/bash
SLOT=$(/root/get_active.sh)
ROOTPART=$(lsblk -o NAME,MOUNTPOINT | grep lower | awk '{print $1}')
ROOTPART=/dev/${ROOTPART:2:$((${#ROOTPART}-2))}

if [[ "${SLOT}" == "1" && "${ROOTPART}" == *"p2" ]]; then
    echo "slot1"
elif [[ "${SLOT}" == "2" && "${ROOTPART}" == *"p3" ]]; then
    echo "slot2"
else
    echo "error"
fi
```

### Step 8 — Fix `syncfiles.service`

```ini
[Unit]
Description=inotify based file syncing Service

[Service]
Type=simple
WorkingDirectory=/root
Environment=PID_FILE=/run/inot.pid
ExecStart=/sbin/start-stop-daemon -S -m -p ${PID_FILE} -x /usr/sbin/inot.sh
ExecStop=/sbin/start-stop-daemon -K -x /usr/sbin/inot.sh -p ${PID_FILE} --remove-pidfile --signal INT
Restart=always
RestartSec=1s

[Install]
WantedBy=multi-user.target
```

---

## Suggestions for Plan Improvement

### Suggestion A — U-Boot env partition for the active marker (recommended)

The `active` file lives on the FAT boot partition, which has no journaling.
A power failure during `echo "2" > /media/boot/active` can silently corrupt FAT.
If the file goes missing, `get_active.sh` silently falls back to slot1, which may be wrong.

**Better:** store the active slot in U-Boot's environment partition using `fw_setenv`/`fw_printenv`.
U-Boot env uses a CRC-protected double-copy scheme — writes are atomic and verified.
Both U-Boot and Linux can read/write it.

```bash
# from Linux
fw_setenv active_slot 2

# in boot.cmd
if test "${active_slot}" = "2"; then
    setenv bootslot slot2
    setenv rootpart /dev/mmcblk0p3
fi
```

Requires:
- `BR2_PACKAGE_UBOOT_TOOLS=y` in defconfig
- A small uboot-env partition added to `genimage.cfg`
- U-Boot configured with `CONFIG_ENV_IS_IN_MMC` pointing to that partition

### Suggestion B — Stage kernel files, finalize after dd

Already included in Step 5 above (`zImage.new` → `zImage` rename after dd).
Ensures that the inactive slot's kernel directory is never left in a half-written state
if power fails during the update.
Note: FAT doesn't guarantee atomic rename, but this is still better than overwriting in place.

### Suggestion C — Explicit boot partition mount failure detection in `rc.local`

Currently if `mount ${BOOTPART} /media/boot` fails in rc.local, the check script runs
without the boot partition mounted, `get_active.sh` silently defaults to slot1,
and `needupdate` is never found. Failure is invisible.

Add after the mount line in `rc.local`:
```bash
if ! mountpoint -q /media/boot; then
    echo "ERROR: failed to mount boot partition, skipping recovery check" >&2
else
    /etc/recovery_partitions_check.sh
fi
```

### Suggestion D — Embed version info in rootfs at build time

After a few updates it's hard to know which slot has which version without
reading the FAT boot partition. Add a `/etc/slot_version` or `/etc/build_info`
file written into the rootfs image at build time (via `BR2_ROOTFS_POST_BUILD_SCRIPT`).

```bash
# in post-build script
echo "${VERSION_TAG}" > ${TARGET_DIR}/etc/build_info
```

Then `cat /etc/build_info` tells you the running version without needing /media/boot.

### Suggestion E — Flag-file based first-boot expansion

`overlayroot2.sh` checks `if [ ${DATAPARTSIZE} == "100M" ]` via fdisk output string matching.
This is fragile across different fdisk versions and locale settings.

Replace with a flag file:
```bash
if [ ! -f /media/data/.expanded ]; then
    /root/expandfs.sh /dev/mmcblk${mmcnum} ${DATAPARTNUM}
    touch /media/data/.expanded
fi
```

---

## Effort Estimate

| Work item | Effort |
|-----------|--------|
| Steps 1–8 (core plan) | ~2–3 days |
| Suggestion A (U-Boot env) | +1 day |
| Suggestions B–E | +2–3 hours total |

Suggestions B–E are cheap and should be included in the same implementation pass.
Suggestion A is the most impactful for correctness and is recommended for devices
deployed without physical access for recovery.
