---
name: flash-sdcard
description: Flash sdcard.img to an SD card device using dd. Default device /dev/sdb, overridable. Shows progress with status=progress.
---

# Flash SD Card

## When to Use

After a successful build, to write `sdcard.img` to a physical SD card for the OrangePi Zero3.

## Defaults

| Parameter | Default | Override |
|-----------|---------|----------|
| Image | `output_orangepi3/images/sdcard.img` | User specifies a path |
| Device | `/dev/sdb` | User specifies a device |

## Steps

1. **Confirm with the user** — show the image path, target device, and device size. This is destructive — always ask before proceeding.

2. **Verify the device exists and is reasonable:**

   ```bash
   lsblk /dev/sdb
   ```

   Refuse to flash if the device looks like a system disk (has mounted partitions on `/`, `/home`, etc.).

3. **Flash the image:**

   ```bash
   sudo dd if=/home/denisov/progs/buildroot/output_orangepi3/images/sdcard.img of=/dev/sdb bs=100M status=progress conv=fsync
   ```

   Use `timeout: 600000` (10 minutes).

4. **Sync and report:**

   ```bash
   sudo sync
   ```

   Report success with bytes written.

## Safety Checks

- ALWAYS confirm with the user before running dd
- NEVER flash to `/dev/sda` or any device with mounted system partitions
- Show `lsblk` output so the user can verify the target is correct
