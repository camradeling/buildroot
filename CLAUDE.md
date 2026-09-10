# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A customized fork of Buildroot (2024.11.2) for building embedded Linux images targeting OrangePi boards. The customizations add an A/B OTA update system with overlayfs-based read-only rootfs and a persistent data partition.

Target boards:
- **OrangePi Zero** (ARM Cortex-A7, H2+) — defconfig: `board/customized/orangepi/testbot_defconfig`
- **OrangePi Zero3** (AArch64, H618) — defconfig: `board/customized/orangepi/testbot3_defconfig`

## Build Commands

All builds are driven by the top-level `build.sh`:

```bash
# Full build for OrangePi Zero3
./build.sh orangepi3

# Full build for OrangePi Zero
./build.sh orangepi

# Build both targets
./build.sh orangepi orangepi3

# Build with alternate vars file
./build.sh orangepi3 board/customized/orangepi/orangepi3-test.vars

# Run menuconfig
./build.sh orangepi3 menuconfig

# Apply a defconfig from top-level
make O=output_orangepi3 testbot3_defconfig
make O=output_orangepi testbot_defconfig

# Standard Buildroot package operations (from top-level)
make O=output_orangepi3 <pkg>-rebuild    # force rebuild single package
make O=output_orangepi3 <pkg>-dirclean   # clean single package
```

`build.sh` auto-initializes the output directory from the target's defconfig if `.config` is missing, sources the vars file, then runs `make -j8`.

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
| `board/customized/scripts/before-fs-allscripts.sh` | Post-build hook that runs all createfs-scripts in order (aborts the build on the first non-zero exit) |
| `board/customized/scripts/after-preset-check.sh` | Post-**fakeroot** hook (testbot4 only): asserts that the systemd units enabled by Buildroot's `preset-all` match `/etc/system.vars`. See "Optional services" below |
| `board/customized/orangepi/orangepi3.vars` | Build-time environment config for Zero3 (hostname, network, GPIO, VPN, USB gadget) |
| `board/customized/orangepi/orangepi.vars` | Same for Zero |
| `build.sh` | Top-level build script (target selection, vars sourcing, auto-init) |

## Environment Variables (vars files)

Vars files live in `board/customized/orangepi/` and are sourced by `build.sh`:
- `orangepi3.vars` — production config for Zero3
- `orangepi3-test.vars` — test config for Zero3
- `orangepi.vars` — config for Zero

These are consumed by the createfs post-build scripts:

- `BOARD_VERSION` — board identifier
- `DEV_HOSTNAME` — device hostname
- `DEVICE_IFACE`, `DEVICE_STATIC_IPADDR`, etc. — network config
- `VPN_CLIENT`, `VPN_CONFIG` — OpenVPN toggle and config path
- `SSH_KEY_FILES_LIST` — authorized SSH public keys
- `USB_GADGET_DEVICE`, `USB_RNDIS` — USB gadget config
- `WIFI_CLIENT`, `WLAN_SSID`, `WLAN_PSK` — WiFi client config
- `QUECTEL_ECM` — install the udev hooks that switch a plugged Quectel modem to ECM and bring its `wwan0` uplink up (DHCP, default route at metric 700)

## Optional Services — how ON/OFF actually works

Buildroot runs `systemctl --root=$(TARGET_DIR) preset-all` as a systemd
`ROOTFS_PRE_CMD_HOOK`, i.e. **after** the post-build scripts, and the default
preset policy is *enable*. So a createfs script cannot disable a service by
removing its `multi-user.target.wants` link — the link is recreated on every
build. (Also note the fakeroot stage operates on a throwaway copy of `target/`,
which is why those links appear in `rootfs.ext2` but never in `output_*/target/`.)

The convention for anything switchable is therefore:

```
optional service = [Install] kept (let preset-all enable it)
                 + Condition*= in the unit, pointing at a config file
                 + the createfs script deletes that config file when the var is OFF
```

Examples: `hostapd.service` → `/etc/hostapd.conf` (`0010`),
`wpa_supplicant_wlan1.service` → `/etc/wpa_supplicant_wlan1.conf` (`0011`),
`openvpn@.service` → `/etc/openvpn/%i.conf` (`0008`). Genuine systemd templates
(`foo@.service`) are not touched by `preset-all` at all, so instances of them are
enabled only by the createfs scripts.

`after-preset-check.sh` enforces this: it fails the build if an enabled unit has
no condition, if an ON feature is missing its config, if an OFF feature still
ships one, or if a unit's `ConditionPathExists=` does not point at the file the
build actually manages. When adding a service, either follow the pattern or add
the unit to that script's `ALWAYS_ON` list.

## Claude Code Skills

Project-specific skills are in `.claude/skills/`:

| Skill | Description |
|-------|-------------|
| `build-buildroot` | Build for OrangePi Zero3/Zero — full build, package rebuild, linux rebuild |
| `deploy-buildroot` | Deploy OTA update to target device |
| `flash-sdcard` | Flash sdcard.img to SD card via dd |
| `loadcontext-buildroot` | Load all project context files into conversation |

## Current Branch: ota-ab-redesign

Active work is implementing the symmetric A/B OTA schema. See `workplans/001-ota-ab-redesign.md` for the full plan. The old asymmetric approach (golden partition + bootok flag + watchdog) has been replaced with the slot1/slot2 active marker approach described above.
