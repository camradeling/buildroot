---
name: build-buildroot
description: Build the buildroot project for OrangePi Zero3 (default) or OrangePi Zero. Supports full build, single package rebuild, and linux-only rebuild.
---

# Build Buildroot

## When to Use

After making changes to the buildroot project at `/home/denisov/progs/buildroot` — DTS changes, package configs, overlay scripts, kernel config, or defconfig updates.

## Targets

| Board | Target name | Output Dir | Defconfig | Default vars |
|-------|-------------|-----------|-----------|--------------|
| OrangePi Zero3 (default) | `orangepi3` | `output_orangepi3/` | `testbot3_defconfig` | `board/customized/orangepi/orangepi3.vars` |
| OrangePi Zero | `orangepi` | `output_orangepi/` | `testbot_defconfig` | `board/customized/orangepi/orangepi.vars` |

Default to OrangePi Zero3 unless the user specifies otherwise.

## Build System

All builds are invoked from the top-level `build.sh`:

```bash
./build.sh <target> [vars-file] [make-goal]
```

Examples:
- `./build.sh orangepi3` — full build with default vars
- `./build.sh orangepi3 board/customized/orangepi/orangepi3-test.vars` — build with alternate vars
- `./build.sh orangepi3 menuconfig` — run menuconfig
- `./build.sh orangepi orangepi3` — build both targets

The script auto-initializes the output directory with the target's defconfig if `.config` is missing.

## Build Tiers

| Tier | Command | Time | When |
|------|---------|------|------|
| Full build | `./build.sh orangepi3` | ~15-30 min | Clean build, defconfig change, first build |
| Package rebuild | `make -C . O=output_orangepi3 <pkg>-rebuild && ./build.sh orangepi3` | ~1-5 min | Single package change |
| Linux rebuild | `make -C . O=output_orangepi3 linux-rebuild && ./build.sh orangepi3` | ~5-10 min | DTS or kernel config change |
| Package clean + rebuild | `make -C . O=output_orangepi3 <pkg>-dirclean <pkg>-rebuild && ./build.sh orangepi3` | ~2-5 min | When rebuild alone doesn't pick up changes |

**Important:** Always use `./build.sh <target>` (not bare `make`) for the final image step. `build.sh` sources environment variables from the vars file that the post-build createfs scripts depend on (hostname, network, SSH keys, VPN, etc.). A bare `make` skips these and produces an incorrectly configured image.

## Steps

1. **Determine build scope** from what changed:
   - DTS file (`*.dts`) → Linux rebuild
   - Kernel config → Linux rebuild
   - Single package source → Package rebuild
   - Overlay files only → `./build.sh orangepi3` (no rebuild needed, just repack)
   - Defconfig or broad config change → Full build

2. **Run the build** from the project root:

   ```bash
   cd /home/denisov/progs/buildroot && make -C . O=output_orangepi3 linux-rebuild && ./build.sh orangepi3
   ```

   Use `run_in_background: true` and `timeout: 1800000` (30 minutes).

3. **Check the result:**
   - Exit code 0 = success
   - On failure, show the last 30 lines of output for diagnosis
   - Image lands at `output_orangepi3/images/sdcard.img`

## Common Package Names

| Package | What |
|---------|------|
| `linux` | Kernel + DTS |
| `xr819-xradio` | WiFi kernel module |
| `armbian-firmware` | Firmware blobs (WiFi, BT) |
| `host-uboot-tools` | mkimage for boot.scr |
| `uwe5622-wifi` | UWE5622 WiFi/BT driver (Zero3) |

## Vars Files

Located in `board/customized/orangepi/`:
- `orangepi3.vars` — default production config for Zero3
- `orangepi3-test.vars` — test config for Zero3 (no VPN, different SSH keys)
- `orangepi.vars` — default config for Zero

## Notes

- `build.sh` sources the vars file, then runs `make -j8` with `-C` pointing to the project root
- The output dir is auto-created and initialized from defconfig on first run
- To apply a defconfig manually: `make O=output_orangepi3 testbot3_defconfig`
