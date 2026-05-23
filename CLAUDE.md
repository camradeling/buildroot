# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A customized fork of Buildroot (2024.11.2) for building embedded Linux images targeting OrangePi boards. The customizations add an A/B OTA update system with overlayfs-based read-only rootfs and a persistent data partition.

Target boards:
- **OrangePi Zero** (ARM Cortex-A7, H2+) — defconfig: `board/customized/orangepi/testbot_defconfig`
- **OrangePi Zero3** (AArch64, H618) — defconfig: `board/customized/orangepi/testbot3_defconfig`

## Build Commands

```bash
# Configure for OrangePi Zero (from output_orangepi/)
cd output_orangepi && ./config.sh    # runs make menuconfig

# Configure for OrangePi Zero3 (from output_orangepi3/)
cd output_orangepi3 && ./config.sh

# Build (from the output_* directory)
./build.sh                           # sources default.vars, runs make -j8
./build.sh test.vars                 # build with alternate variable set

# Build from top-level with out-of-tree output
make O=output_orangepi3
make O=output_orangepi

# Apply a defconfig from top-level
make O=output_orangepi3 testbot3_defconfig
make O=output_orangepi testbot_defconfig

# Standard Buildroot package operations (from output dir)
make <pkg>-rebuild                   # force rebuild single package
make <pkg>-dirclean                  # clean single package
make menuconfig                      # reconfigure
```

Build output lands in `output_orangepi3/images/` (or `output_orangepi/images/`). The key artifact is `sdcard.img` — write it to SD with `dd`.

## Disk Image Layout (genimage.cfg)

GPT partitioned SD card image:
1. **u-boot** — raw at offset 8K (not in partition table)
2. **boot** (FAT32, 32MB) — `active` file, `slot1/` and `slot2/` kernel dirs, `boot.scr`
3. **rootfs1** (ext2, 750MB) — slot 1 root filesystem
4. **rootfs2** (ext2, 750MB) — slot 2 root filesystem
5. **data** (ext4) — persistent writable data, expanded on first boot

## OTA A/B Boot Architecture

U-Boot reads `/active` from the FAT boot partition (ASCII `"1"` or `"2"`). It never writes to the boot partition. If the file is missing or unreadable, slot1 is the default.

Boot flow: U-Boot → `overlayroot2.sh` (init) → mounts active rootfs read-only as overlayfs lower → systemd

Update flow:
1. `prepare_update.sh <archname>` — unpacks tarball, writes path to `/media/boot/needupdate`, reboots
2. `rc.local` → `recovery_partitions_check.sh` — detects active/inactive slot
3. `reflashfs.sh` — dd's rootfs to inactive partition, copies kernel to inactive boot slot
4. `set_active.sh <slot>` — flips the active marker (only after successful flash)
5. Reboot into new slot

Power-fail safe: active marker is only written after dd completes successfully.

## Key Custom Files

| Path | Purpose |
|------|---------|
| `board/customized/orangepi/boot.cmd` | U-Boot script (Zero, ARM32, `bootz`) |
| `board/customized/orangepi/boot3.cmd` | U-Boot script (Zero3, AArch64, `booti`) |
| `board/customized/orangepi/genimage.cfg` | Zero disk image layout |
| `board/customized/orangepi/genimage3.cfg` | Zero3 disk image layout |
| `board/customized/overlays/filesystems/system_v2/` | Rootfs overlay (OTA scripts, systemd units, overlayroot2.sh) |
| `board/customized/overlays/services/` | Optional service overlays (openvpn, hostapd, ssh, usb_gadget, etc.) |
| `board/customized/overlays/devices/` | Per-device udev rules |
| `board/customized/scripts/createfs-scripts/` | Numbered post-build scripts (network, hostname, services, SSH keys) |
| `board/customized/scripts/before-fs-allscripts.sh` | Post-build hook that runs all createfs-scripts in order |
| `output_orangepi/default.vars` | Build-time environment config (hostname, network, GPIO, VPN, USB gadget) |
| `output_orangepi3/default.vars` | Same for Zero3 |

## Environment Variables (default.vars)

These are sourced by `build.sh` and consumed by the createfs post-build scripts:

- `BOARD_VERSION` — board identifier
- `DEV_HOSTNAME` — device hostname
- `DEVICE_IFACE`, `DEVICE_STATIC_IPADDR`, etc. — network config
- `VPN_CLIENT`, `VPN_CONFIG` — OpenVPN toggle and config path
- `SSH_KEY_FILES_LIST` — authorized SSH public keys
- `USB_GADGET_DEVICE`, `USB_RNDIS` — USB gadget config
- `WIFI_CLIENT`, `WLAN_SSID`, `WLAN_PSK` — WiFi client config

## Current Branch: ota-ab-redesign

Active work is implementing the symmetric A/B OTA schema. See `workplans/001-ota-ab-redesign.md` for the full plan. The old asymmetric approach (golden partition + bootok flag + watchdog) has been replaced with the slot1/slot2 active marker approach described above.
