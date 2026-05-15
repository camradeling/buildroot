# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A customized fork of Buildroot (2024.11.2) for building embedded Linux firmware images targeting Orange Pi Zero (H2+), Orange Pi Zero3 (H618), and Odroid MC (Exynos5422). The customizations live in `board/customized/` and `output_*/` directories; the rest is stock Buildroot.

## Build Commands

Each target has its own output directory with a wrapper Makefile:

```bash
# Orange Pi Zero (ARMv7, sunxi H2+)
cd output_orangepi && ./build.sh          # builds with default.vars
cd output_orangepi && ./config.sh         # opens menuconfig

# Orange Pi Zero3 (AArch64, sunxi H618)
cd output_orangepi3 && ./build.sh

# Odroid MC (ARMv7, Exynos5422)
cd output_odroidmc && ./build.sh
```

Or use standard Buildroot from the repo root:

```bash
make O=output_orangepi orangepi_zero_defconfig   # only needed once
make O=output_orangepi -j8
```

Build output lands in `output_<target>/images/sdcard.img`.

To create a deployable OTA tarball: the `genimage.sh` post-image script automatically produces `<version-tag>.tar.gz` containing `rootfs.ext2`, `zImage`, DTB, and `version.txt`.

## Flash / Deploy

Write full image to SD card:
```bash
sudo dd if=output_orangepi/images/sdcard.img of=/dev/sdX bs=1M
```

OTA update (on device): copy `<tag>.tar.gz` to `/media/data/update/`, then:
```bash
/root/prepare_update.sh <tag>    # unpacks, writes needupdate marker, reboots
```

## Architecture

### Partition Layout (GPT, defined in `genimage.cfg`)

| Partition | Mount | Purpose |
|-----------|-------|---------|
| u-boot | raw @ 8K | SPL + U-Boot |
| boot (FAT32, 32MB) | /media/boot | `active` marker, `boot.scr`, `slot1/`, `slot2/` |
| rootfs1 (ext2, 750MB) | overlayfs lower | Slot 1 rootfs |
| rootfs2 (ext2, 750MB) | overlayfs lower | Slot 2 rootfs |
| data (ext4) | /media/data | Persistent data, overlay upper |

### OTA A/B Slot Design

Symmetric A/B with a persistent `active` file on the FAT boot partition (ASCII "1" or "2"):

1. **U-Boot** (`boot.cmd`) reads `active`, selects `slot1/` or `slot2/` kernel + DTB, passes matching root partition to kernel. Never writes.
2. **Init** (`/sbin/overlayroot2.sh`) mounts the rootfs partition read-only as overlayfs lower layer, with `/media/data` as upper.
3. **Update** flashes to the inactive slot, then flips the `active` marker only after successful dd. Power-fail safe: marker still points to old slot if interrupted.

Key scripts in `board/customized/overlays/filesystems/system_v2/root/`:
- `set_active.sh` / `get_active.sh` — read/write the slot marker
- `reflashfs.sh` — stages kernel as `.new`, dd's rootfs, finalizes with rename
- `prepare_update.sh` — unpacks tarball, triggers reboot into recovery check
- `recovery_partitions_check.sh` (in `etc/`) — runs at boot, drives the update if `needupdate` exists

### Build Customization Flow

1. `output_<target>/build.sh` sources `default.vars` (network, GPIO, VPN, hostname config)
2. Buildroot runs with `BR2_ROOTFS_POST_BUILD_SCRIPT` → `board/customized/scripts/before-fs-allscripts.sh`
3. That script runs numbered scripts in `board/customized/scripts/createfs-scripts/` (systemd cleanup, network config, hostname, SSH keys, etc.)
4. `BR2_ROOTFS_POST_IMAGE_SCRIPT` → `board/customized/orangepi/genimage.sh` (creates slot dirs, builds `boot.scr`, copies kernel to both slots, runs `genimage`)

### Directory Map

| Path | Contents |
|------|----------|
| `board/customized/orangepi/` | Board-specific: defconfigs, genimage configs, boot.cmd, DTS, patches |
| `board/customized/overlays/filesystems/system_v2/` | Root filesystem overlay (rc.local, OTA scripts, systemd units) |
| `board/customized/overlays/devices/` | Per-device overlays (testbot, testbot3) |
| `board/customized/overlays/services/` | Optional service configs (OpenVPN, hostapd, wpa_supplicant, GPIO, USB gadget) |
| `board/customized/scripts/` | Post-build scripts that customize the rootfs before image generation |
| `output_orangepi/default.vars` | Build-time device configuration (IP, GPIO pins, VPN, WiFi) |
| `workplans/` | Implementation plans for ongoing work |

### Targets and Defconfigs

| Target | Defconfig | SoC | Arch |
|--------|-----------|-----|------|
| orangepi | `board/customized/orangepi/testbot_defconfig` | Allwinner H2+ | ARMv7 (Cortex-A7) |
| orangepi3 | `board/customized/orangepi/testbot3_defconfig` | Allwinner H618 | AArch64 (Cortex-A53) |
| odroidmc | `board/customized/odroidmc/odroidxu4_defconfig` | Samsung Exynos5422 | ARMv7 (Cortex-A15/A7) |

## Current Work

Branch `ota-ab-redesign` — implementing the symmetric A/B OTA schema (see `workplans/001-ota-ab-redesign.md` for the full plan).
