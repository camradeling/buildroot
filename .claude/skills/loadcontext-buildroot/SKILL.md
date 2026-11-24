---
name: loadcontext-buildroot
description: Load all context files for the buildroot OTA project into the conversation. Use when working in /home/denisov/progs/buildroot and you need full project context.
---

# Load Context (Buildroot OTA)

Read all project context files into the conversation so subsequent work has full context without lookups.

## Steps

1. **Read all files below in parallel.** Do NOT summarize or paraphrase — just read them silently so they are in context.
2. After all reads complete, print a short checklist showing which files were loaded and which were missing.

## Files to Load

### Project Root
- `/home/denisov/progs/buildroot/CLAUDE.md`

### Workplans
- `/home/denisov/progs/buildroot/workplans/001-ota-ab-redesign.md`

### Disk Image & Boot Configuration
- `/home/denisov/progs/buildroot/board/customized/orangepi/genimage.cfg`
- `/home/denisov/progs/buildroot/board/customized/orangepi/genimage3.cfg`
- `/home/denisov/progs/buildroot/board/customized/orangepi/boot.cmd`
- `/home/denisov/progs/buildroot/board/customized/orangepi/boot3.cmd`

### OTA Scripts (system_v2 overlay)
- `/home/denisov/progs/buildroot/board/customized/overlays/filesystems/system_v2/usr/sbin/overlayroot2.sh`
- `/home/denisov/progs/buildroot/board/customized/overlays/filesystems/system_v2/root/prepare_update.sh`
- `/home/denisov/progs/buildroot/board/customized/overlays/filesystems/system_v2/root/reflashfs.sh`
- `/home/denisov/progs/buildroot/board/customized/overlays/filesystems/system_v2/root/set_active.sh`
- `/home/denisov/progs/buildroot/board/customized/overlays/filesystems/system_v2/root/get_active.sh`
- `/home/denisov/progs/buildroot/board/customized/overlays/filesystems/system_v2/etc/recovery_partitions_check.sh`
- `/home/denisov/progs/buildroot/board/customized/overlays/filesystems/system_v2/root/expandfs.sh`

### Build Configuration
- `/home/denisov/progs/buildroot/build.sh`
- `/home/denisov/progs/buildroot/board/customized/orangepi/orangepi3.vars`
- `/home/denisov/progs/buildroot/board/customized/orangepi/orangepi3-test.vars`
- `/home/denisov/progs/buildroot/board/customized/orangepi/orangepi.vars`

### Settings
- `/home/claudea/.claude/settings.json`
- `/home/denisov/progs/buildroot/.claude/settings.local.json`

### Memory
- All `.md` files in `/home/claudea/.claude/projects/-home-denisov-progs-buildroot/memory/`

## Output Format

After reading, print:

```
Context loaded (buildroot-ota):
  [x] CLAUDE.md
  [x] 001-ota-ab-redesign.md
  [x] genimage.cfg / genimage3.cfg
  [x] boot.cmd / boot3.cmd
  [x] overlayroot2.sh
  [x] prepare_update.sh / reflashfs.sh / set_active.sh / get_active.sh
  [x] recovery_partitions_check.sh / expandfs.sh
  [x] build.sh / orangepi3.vars / orangepi3-test.vars / orangepi.vars
  [x] settings: global + local
  [ ] memory: N files loaded
  ...

Ready to work.
```
