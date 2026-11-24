#!/usr/bin/env python3
"""Deploy an OTA update archive to an OrangePi target via SSH."""

import argparse
import os
import subprocess
import sys
import time

DEFAULT_HOST = "192.168.100.1"
DEFAULT_USER = "root"
DEFAULT_KEY = os.path.expanduser("~/.ssh/id_rsa_zero3")
REMOTE_UPDATE_DIR = "/media/data/update"


def run_ssh(host, user, cmd, key=None, check=True):
    full_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
    if key:
        full_cmd += ["-i", key]
    full_cmd += [f"{user}@{host}", cmd]
    print(f"  -> {cmd}")
    result = subprocess.run(full_cmd, capture_output=True, text=True)
    if result.stdout.strip():
        print(f"     {result.stdout.strip()}")
    if result.returncode != 0 and check:
        print(f"  ERROR: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result


def run_scp(host, user, local_path, remote_path, key=None):
    full_cmd = ["scp", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
    if key:
        full_cmd += ["-i", key]
    full_cmd += [local_path, f"{user}@{host}:{remote_path}"]
    print(f"  -> scp {os.path.basename(local_path)} to {remote_path}")
    result = subprocess.run(full_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  ERROR: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)


def wait_for_host(host, user, key=None, timeout=120):
    print(f"Waiting for {host} to come back online (timeout {timeout}s)...")
    start = time.time()
    while time.time() - start < timeout:
        cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
               "-o", "ConnectTimeout=5"]
        if key:
            cmd += ["-i", key]
        cmd += [f"{user}@{host}", "echo ok"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"  Host is back after {int(time.time() - start)}s")
            return True
        time.sleep(5)
    print("  TIMEOUT waiting for host", file=sys.stderr)
    return False


def main():
    parser = argparse.ArgumentParser(description="Deploy OTA update to OrangePi target")
    parser.add_argument("archive", help="Path to the update .tar.gz archive")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Target IP (default: {DEFAULT_HOST})")
    parser.add_argument("--user", default=DEFAULT_USER, help=f"SSH user (default: {DEFAULT_USER})")
    parser.add_argument("--key", default=DEFAULT_KEY, help=f"SSH identity file (default: {DEFAULT_KEY})")
    parser.add_argument("--no-wait", action="store_true", help="Don't wait for reboot completion")
    args = parser.parse_args()

    archive = os.path.abspath(args.archive)
    if not os.path.isfile(archive):
        print(f"ERROR: file not found: {archive}", file=sys.stderr)
        sys.exit(1)

    if not archive.endswith(".tar.gz"):
        print(f"ERROR: archive must be a .tar.gz file", file=sys.stderr)
        sys.exit(1)

    archname = os.path.basename(archive).removesuffix(".tar.gz")

    key = args.key if os.path.isfile(args.key) else None
    print(f"Deploying '{archname}' to {args.user}@{args.host}")
    print()

    # Ensure target directory exists
    print("[1/4] Preparing target directory...")
    run_ssh(args.host, args.user, f"mkdir -p {REMOTE_UPDATE_DIR}", key=key)

    # Copy archive to target
    print("[2/4] Copying archive to target...")
    run_scp(args.host, args.user, archive, f"{REMOTE_UPDATE_DIR}/{archname}.tar.gz", key=key)

    # Get current active slot before update
    print("[3/4] Checking current slot...")
    result = run_ssh(args.host, args.user, "/root/get_active.sh", key=key)
    current_slot = result.stdout.strip()
    expected_slot = "2" if current_slot == "1" else "1"
    print(f"     Current slot: {current_slot}, will update to slot: {expected_slot}")

    # Trigger the update (this will reboot the device)
    print("[4/4] Triggering update (device will reboot)...")
    run_ssh(args.host, args.user, f"/root/prepare_update.sh {archname}", key=key, check=False)

    if args.no_wait:
        print("\nUpdate triggered. Device is rebooting.")
        return

    # Wait for first reboot (prepare_update reboots)
    print("\nWaiting for first reboot (unpack + flash)...")
    time.sleep(10)
    if not wait_for_host(args.host, args.user, key=key, timeout=180):
        sys.exit(1)

    # After first reboot, recovery_partitions_check.sh will flash and reboot again
    # Wait a bit for the flash to start, then wait for second reboot
    print("Waiting for flash + second reboot...")
    time.sleep(15)
    if not wait_for_host(args.host, args.user, key=key, timeout=300):
        sys.exit(1)

    # Verify the new slot is active
    print("\nVerifying update...")
    result = run_ssh(args.host, args.user, "/root/get_active.sh", key=key)
    new_slot = result.stdout.strip()
    if new_slot == expected_slot:
        print(f"  SUCCESS: now running on slot {new_slot}")
    else:
        print(f"  WARNING: expected slot {expected_slot} but got slot {new_slot}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
