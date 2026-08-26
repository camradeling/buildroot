---
name: deploy-buildroot
description: Deploy an OTA update to OrangePi target. Uses the latest built tar.gz archive and 192.168.100.1 as defaults, both overridable.
---

# Deploy Buildroot OTA Update

## When to Use

After a successful build, to deploy the update to the target device.

## Defaults

| Parameter | Default | Override |
|-----------|---------|----------|
| Archive | Latest `.tar.gz` in `output_testbot4/images/` (by mtime) | User specifies a path or filename |
| Target host | `192.168.7.100` | User specifies `--host <ip>` or mentions an IP/hostname |
| SSH user | `root` | User specifies `--user <name>` |

## Steps

1. **Find the latest archive** (unless user specified one):

   ```bash
   ls -t /home/denisov/progs/buildroot/output_testbot4/images/*.tar.gz | head -1
   ```

2. **Confirm with the user** — show which archive and target will be used before deploying.

3. **Run the deploy script:**

   ```bash
   /home/denisov/progs/buildroot/tools/deploy_update.py <archive> --host 192.168.7.100
   ```

   Use `timeout: 600000` (10 minutes) to allow for reboot cycles.

4. **Report result** — show whether the update succeeded and which slot is now active.

## Example Invocations

- `/deploy-buildroot` — deploys latest archive to 192.168.7.100 (testbot4)
- `/deploy-buildroot zero3_new` or `/deploy-buildroot 192.168.100.1` — deploy to a different host
- `/deploy-buildroot test.tar.gz` — deploys a specific archive
- `/deploy-buildroot test.tar.gz 192.168.100.1` — both overridden
