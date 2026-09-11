# Plan 002 — Unified Routing / NAT Model

## Context

testbot4 grew from "eth0 + AP" to six interfaces, and each one was wired up by a
different mechanism as it was added. The result is that no single place knows how
traffic is supposed to leave the board.

Interfaces as of today (names are all forced, `net.ifnames=1` + udev rules):

| Iface   | Role                | Address                       | Default route today            |
|---------|---------------------|-------------------------------|--------------------------------|
| `eth0`  | uplink              | static `192.168.7.100/24`     | none (`DEVICE_STATIC_GATEWAY` commented out) |
| `eth0:1`| uplink (DHCP alias) | DHCP                          | metric 50, or **0** on the `TIMEOUT` path |
| `wlan0` | LAN (AP)            | static `192.168.3.1/24`       | never                          |
| `wlan1` | uplink (WiFi client)| DHCP                          | metric 200 (`wlan1-fix-metric.sh`, after `sleep 3`) |
| `usb0`  | LAN + last-resort uplink | static `192.168.100.1/24` | metric 1000 via `192.168.100.75` |
| `wwan0` | uplink (Quectel ECM)| DHCP from modem               | metric 700 (`dhclient-exit-hooks`) |
| `tun*`/`tap*` | VPN           | from OpenVPN config           | only if the config lets the server push it |

Three separate problems:

1. **NAT hardcodes topology.** `wlan0-ap-setup.sh` masquerades out
   `${WIFI_AP_WAN_IFACE:-eth0}` and `wlan1-client-setup.sh` masquerades out
   `wlan1`. So AP clients get internet over eth0, or over wlan1, and over
   nothing else — `wwan0` and `usb0` uplinks are unreachable for them. The rules
   are also added/removed by hostapd and wpa_supplicant `ExecStartPost`/
   `ExecStopPost` hooks, so restarting hostapd tears down NAT.
2. **Route metrics have four owners.** The hardcoded `metric 50` in
   `dhclient-script` (plus a bare `route add default gw` with metric 0 in its
   `TIMEOUT` branch), `wlan1-fix-metric.sh`, `dhclient-exit-hooks`, and
   `usbstart.sh`. No table anywhere says what the intended priority order is.
3. **`/etc/scripts/` mixes two kinds of script.** `rc.local` runs
   `/etc/scripts/*.sh` with no arguments. Boot scripts (`usbstart.sh`) rely on
   that; service hooks (`wlan0-ap-setup.sh`, `wlan1-client-setup.sh`) survive it
   only because their `case "$1"` matches nothing. The Quectel scripts have no
   such guard, so they run at boot too — and with no modem plugged,
   `quectel_ecm.sh` burns its full 20s port-wait loop. `rc-local.service` is
   `Type=forking` while `rc.local` never forks, and `hostapd.service` /
   `wpa_supplicant_wlan1.service` are `After=rc-local.service`, so that 20s
   (plus 3s from `wlan1-fix-metric.sh`) delays the AP on every modem-less boot.

## Key Insight

Nothing needs to discover "the current default gateway". The kernel already
sends forwarded packets to the lowest-metric default route, and an `iptables`
`POSTROUTING` rule is only consulted for packets that are actually leaving. So
rules installed once at boot are automatically "NAT out whatever the default
route happens to be". No watcher, no daemon, no `WIFI_AP_WAN_IFACE`.

The rule set is keyed on the **LAN** the traffic comes from (`-s <lan> ! -o
<own iface>`), not on the uplink it leaves by — see the NAT section for why the
original uplink-keyed form was dropped.

That splits cleanly:

- **Which uplink wins** = route metrics, one table, one owner.
- **NAT** = static, uplink-agnostic, order-insensitive rules.

## Decisions (from review)

- `ip rule add blackhole iif tap_l2` in `rc.local`: **removed** (done).
- `usb0` stays a **last-resort uplink**, last in the metric ladder.
- VPN takes the default route **optionally, decided by its own config**. The
  template `configs/dummy.conf` already carries `pull-filter ignore
  redirect-gateway` and `route-nopull`; with those the tunnel carries only its
  own `route` directives, without them the server's `redirect-gateway def1`
  installs `0.0.0.0/1` + `128.0.0.0/1`, which beat *any* default route
  regardless of metric. So the VPN needs no place in the metric ladder — it only
  needs to be in the NAT set. Non-OpenVPN protocols: later.

## Target Model

### Metric ladder — single source of truth (implemented)

`/etc/iface-metrics`, one table, room to insert:

```
# iface   metric
eth0      100
eth0:1    100
wlan1     200
wwan0     700
usb0      2000
```

The lookup is one small script, `/usr/sbin/iface-metric <iface>`, rather than a
function copied into each caller: `dhclient-script` and `usbstart.sh` both need
it and live in different overlays. It always prints a number and exits 0, so
callers can inline it — an empty metric would be worse than a wrong one, since
`route add default gw X metric` with nothing after it is a syntax error and a
bare `route add default gw X` means metric **0**, outranking everything.

Unlisted interfaces get **900**: below every named uplink, above `usb0`'s
last-resort 2000. A non-numeric value in the table takes the same fallback
instead of degenerating to 0.

Both route-installing branches of `dhclient-script` use it, which closes the
metric-0 hole in the `TIMEOUT` path. `usbstart.sh` reads `usb0` from the same
file (its metric moves 1000 → 2000, still last).

`wlan1-fix-metric.sh` and `dhclient-exit-hooks` are deleted. `0011` and `0012`
delete them from `output/target/` too, and `after-preset-check.sh` rule D fails
the build if any retired path is still in the image — leftovers there are not
dead weight but a second owner, since `rc.local` runs every `/etc/scripts/*.sh`
and `dhclient-script` sources `/etc/dhclient-exit-hooks` on every lease.

Verified by unit-testing the lookup against a synthetic table: each listed
interface returns its own metric, `eth0` and `eth0:1` do not cross-match, an
unlisted alias, a missing table and a corrupt value all return 900, and the
script parses under busybox `ash` as well as bash.

Confirmed end to end on testbot4 (2026-09-11), with the table as the only owner —
no exit hook, no `wlan1-fix-metric.sh`:

```
default via 192.168.43.1 dev wwan0  metric 700
default via 192.168.100.75 dev usb0  metric 2000
```

### NAT — keyed on the LAN, not on the uplink (implemented)

One boot-time script, idempotent (`-C || -A`), one rule per LAN subnet:

```
-t nat -A POSTROUTING -s 192.168.3.0/24   ! -o wlan0 -j MASQUERADE
-t nat -A POSTROUTING -s 192.168.100.0/24 ! -o usb0  -j MASQUERADE
```

Verified live on testbot4 (2026-09-10), where the only rule in the table was
`-o eth0 -j MASQUERADE` and `eth0` had no carrier: `ping -I 192.168.3.1 8.8.8.8`
was 100% loss and `ping -I wwan0 8.8.8.8` 0%. Adding the two rules by hand took
the LAN-sourced ping to 0% loss and made DNS resolve from a LAN source address;
they were then removed to leave the board as found.

**This replaces the uplink-keyed set this plan originally specified** (one
`-o <uplink> -j MASQUERADE` per candidate uplink). Both are uplink-agnostic in
the sense that matching happens at packet time, but the uplink-keyed form still
carries a *list of uplinks*, and that list is precisely the thing that went
stale: `wwan0` was added, nobody updated the list, and AP clients lost the
internet. Keyed on the LAN there is no list to keep in sync — a second modem, a
tunnel, anything new is covered with zero edits.

Three further advantages:

- Board-originated traffic is untouched. The uplink-keyed form rewrites our own
  packets too (harmless, but every counter becomes noise).
- `usb0`'s dual role as LAN *and* last-resort uplink falls out correctly and
  symmetrically: AP clients egressing `usb0` are NATted to `192.168.100.1`, and
  `usb0`-side traffic egressing `wwan0` is NATted, with no special case.
- `! -o <own iface>` leaves LAN↔LAN traffic alone, so an AP client reaching a
  `usb0` client keeps its real source address.

Implemented as `services/netpolicy/` (`usr/sbin/netpolicy` +
`netpolicy.service`), a `Type=oneshot` `RemainAfterExit=yes` unit ordered with
`network-pre.target`. Subnets are derived at runtime from `WIFI_AP_ADDR` /
`WIFI_AP_NETMASK` in `system.vars` and `USB_ADDR` in
`/etc/profile.d/usbaddr.sh`; there is no `ipcalc` in the image, so the script
does the mask arithmetic itself and rejects non-contiguous masks. No feature
gating: with the AP or gadget off the interface has no address, so nothing can
carry that source and the rule is inert — which also means enabling a feature at
runtime cannot leave NAT missing.

Scoped to the two targets that have an AP: the overlay is added to
`testbot3_defconfig` and `testbot4_defconfig`. `testbot` (Zero) has no
`hostapd_wlan0`/`dnsmasq_wlan0` overlay, so it is unaffected. `ip_forward`
therefore stays in `rc.local` rather than moving into the unit — moving it would
drop forwarding on `testbot`. `netpolicy.service` is always-on with no
`Condition*=`, so it is added to `ALWAYS_ON` in `after-preset-check.sh`.

`wlan0-ap-setup.sh` loses its `iptables` block and keeps only the AP address
assignment. `wlan1-client-setup.sh` did nothing else at all, so it is deleted
along with the `ExecStartPost=`/`ExecStopPost=` hooks in
`wpa_supplicant_wlan1.service`; `0011` deletes the stale copy from
`output/target/`, which the overlay rsync would otherwise keep shipping. Having
the rules in those hooks was itself a bug: `systemctl restart hostapd` removed
NAT for the whole board.

The existing `FORWARD` rules are dropped: the `FORWARD` policy is `ACCEPT`, so
they gate nothing while reading like a firewall. A real firewall (policy `DROP` +
stateful rules) is a separate decision, deliberately not half-done here.

Not addressed, and needing a decision: these rules also NAT LAN traffic leaving
through a tunnel, which is right for a road-warrior client but wrong for a
site-to-site peer that expects the real LAN subnet. The insertion point for a
`RETURN` on the remote subnets is documented in the script header.

### `wwan0` — driven by the device unit (implemented)

Replace the ifupdown path with the shape `dhclient_wlan1.service` already uses:
`Type=simple`, `BindsTo=`/`After=sys-subsystem-net-devices-wwan0.device`,
`ExecStartPre` brings the link up, `ExecStart=/sbin/dhclient wwan0 -d`,
`Restart=always`. `BindsTo` makes systemd stop it when the modem is unplugged,
which is the one thing ifupdown cannot do here — and it removes the stale
`/run/network/ifstate` workaround. Deletes `interfaces.d/wwan0`.

What *starts* it is `[Install] WantedBy=sys-subsystem-net-devices-wwan0.device`,
not udev. The net-device udev rule that used to do it is deleted: it never worked,
because renaming the interface makes the kernel emit a second `ACTION=move` uevent
and udev rewrites the device's database entry without the `SYSTEMD_WANTS` the
`ACTION=="add"` rule had set. The `.wants` link on the device unit is the
level-triggered form of the same intent and survives anything that touches the
device's properties. `99-quectel-ecm.rules` keeps only the USB-parent rule for the
mode switch, which has no device unit to hang off.

Field testing on testbot4 (2026-09-10, again 2026-09-11) turned this from a
tidy-up into the fix for three real outages — see "Field findings: the wwan0
bring-up path" below.

### `/etc/scripts/` hygiene (implemented)

`quectel_ecm.sh` moved to `/usr/libexec/quectel/`, out of the `rc.local` glob —
udev is its only correct trigger, there was no boot-time role to preserve. It now
asks sysfs whether a 2c7c device exists *before* waiting for anything and exits
immediately when there is none; the `AT_PORT_WAIT` loop only runs once a modem has
been found, waiting for its `ttyUSB*` ports to bind. `quectel_ecm_up.sh` is gone
entirely: every job it had (guard on `QUECTEL_ECM`, check the interface exists,
`ifdown --force` to clear stale `ifstate`, wait for carrier, `ifup`) either moved
into the unit or stopped existing with ifupdown.

`wlan0-ap-setup.sh` stays in `/etc/scripts/`. It is a service hook, so `rc.local`
runs it with no arguments and its `case "$1"` matches nothing — harmless, and
moving it is a separate cleanup with no bug behind it.

## Phases

| # | Work | Files |
|---|------|-------|
| 0 | `rc.local` blackhole rule removed | `system_v2/etc/rc.local` **(done)** |
| 1 | Quectel scripts out of `/etc/scripts`, wait loop restructured; `wwan0` to the `BindsTo` + `dhclient -d` shape (drops the `KillMode=process` stopgap) | `services/quectel_ecm/*`, `0012-quectel_ecm_service.sh`, `after-preset-check.sh` **(done)** |
| 2 | `/etc/iface-metrics` + `iface-metric` as sole metric owner; delete `wlan1-fix-metric.sh` and `dhclient-exit-hooks`; `usbstart.sh` reads the table | `system_v2/usr/sbin/dhclient-script`, `system_v2/etc/iface-metrics` (new), `system_v2/usr/sbin/iface-metric` (new), `wpa_supplicant_wlan1/*`, `usb_gadget/etc/scripts/usbstart.sh`, `0011`, `after-preset-check.sh` **(done)** |
| 3 | `netpolicy` oneshot unit with the LAN-keyed NAT set; strip `iptables` from the two setup scripts; retire `WIFI_AP_WAN_IFACE` | new `services/netpolicy/{usr/sbin/netpolicy,etc/systemd/system/netpolicy.service}`, `hostapd_wlan0/etc/scripts/wlan0-ap-setup.sh`, `wpa_supplicant_wlan1/etc/scripts/wlan1-client-setup.sh` (deleted), `wpa_supplicant_wlan1.service`, `0010`, `0011`, `after-preset-check.sh`, `system.vars`, `orangepi_new-test.vars`, `testbot3_defconfig`, `testbot4_defconfig` **(done)** |
| 4 | "OFF means off" — runtime `Condition*=` gating + a post-fakeroot assertion pass | `hostapd.service`, `dnsmasq_wlan0.service`, `dnsmasq_usb0.service`, `wpa_supplicant_wlan1.service`, `dhclient_wlan1.service`, new `openvpn@.service`, `0001`, `0007`, `0008`, `0010`, `0011`, `system.vars`, new `after-preset-check.sh`, `testbot4_defconfig` **(done)** |
| 5 | **Xray as the LAN's uplink** — every packet forwarded from `usb0`/`wlan0` goes into a local Xray client over TPROXY; the box's own traffic stays direct. Needs a kernel rebuild, `iproute2`, an `xray` package and a clock that is not from 2024 | `linux_zero3.config`, `testbot4_defconfig`, new `package/xray/*`, new `services/xray/*`, new `0013-xray_client_service.sh`, `0007`, `0010`, `quectel_ecm/*`, `after-preset-check.sh`, `system.vars`, `orangepi4-test.vars` |
| 6 | *Optional, later:* reachability-based failover watcher (moved out of 5) | new |

## Phase 4 — "OFF means off" (resolved, implemented)

Buildroot runs `systemctl --root=$(TARGET_DIR) preset-all` as a
`SYSTEMD_ROOTFS_PRE_CMD_HOOK`, i.e. **after** the post-build scripts, and the
default preset policy is *enable*. Verified in the shipped `rootfs.ext2`:
`openvpn@client.service`, `openvpn@server.service`,
`wpa_supplicant_wlan1.service` and `dhclient_wlan1.service` are all enabled
despite `VPN_CLIENT=OFF` and `WIFI_CLIENT=OFF`, and the SSID/PSK are still
patched into `wpa_supplicant_wlan1.conf`. So `wlan1` can associate and install a
metric-200 default route on a build where the WiFi client is supposedly off, and
`0008`'s link removal is silently undone.

Any metric ladder is only as good as this. Note `0001-remove_systemd_services.sh`
was *already* trying to remove four of these links — it just runs before
`preset-all` puts them back, so it has never had any effect on the shipped image.

### Decision: gate at runtime on the config artifact

Stop fighting `preset-all`. Keep `[Install]`, let every optional unit be enabled,
and make each one refuse to start unless its config file is present:

```
optional service = [Install] kept
                 + Condition*= on a config file
                 + createfs deletes that config file when the var is OFF
```

| Unit | Gate | Deleted by |
|------|------|-----------|
| `hostapd.service` | `/etc/hostapd.conf` | `0010`, `WIFI_AP != ON` |
| `dnsmasq_wlan0.service` | `/etc/dnsmasq_wlan0.conf` | `0010`, `WIFI_AP != ON` |
| `dnsmasq_usb0.service` | `/etc/dnsmasq_usb0.conf` | `0007`, USB gadget or RNDIS off |
| `wpa_supplicant_wlan1.service` | `/etc/wpa_supplicant_wlan1.conf` | `0011`, `WIFI_CLIENT != ON` |
| `dhclient_wlan1.service` | `/etc/wpa_supplicant_wlan1.conf` | `0011`, `WIFI_CLIENT != ON` |
| `openvpn@%i.service` | `/etc/openvpn/%i.conf` | `0008`, `VPN_CLIENT != ON` |

The gate also removes the WiFi-client hazard for the metric ladder directly: no
`wpa_supplicant_wlan1.conf` means no association and no metric-200 default route,
whatever the `.wants` directory says.

`openvpn@client.service` and `openvpn@server.service` were two byte-identical
*concrete* files with a literal `@` in the name, so `preset-all` treated them as
ordinary units and enabled both — including the server, for which no
`/etc/openvpn/server.conf` has ever existed. They are replaced by one real
template `openvpn@.service`; `preset-all` does not enable templates, so from now
on the only thing that enables an instance is `0008`. `0008` also deletes the two
stale unit files, since `output/target/` is not wiped between builds and the
overlay rsync has no `--delete`.

`VPN_CLIENT` is now written into `/etc/system.vars` like the other feature flags,
which both makes it introspectable on the target and gives the assertion pass
below something environment-independent to read.

### Belt and braces: `after-preset-check.sh`

`BR2_ROOTFS_POST_FAKEROOT_SCRIPT` is the only hook that runs *after* `preset-all`
(`fs/common.mk:183`, right after `ROOTFS_PRE_CMD_HOOKS`). Wired up in
`testbot4_defconfig` to `board/customized/scripts/after-preset-check.sh`, which
**asserts and never mutates** — three rules, all read-only:

- **A.** every unit linked in `/etc/systemd/system/multi-user.target.wants` is
  either on an explicit always-on allowlist or carries a
  `Condition*=`/`ExecCondition=` line. This is the rule that catches a newly
  added package shipping an auto-enabled unit.
- **B.** for each feature, ON ⇒ all its config artifacts exist, OFF ⇒ all are
  gone.
- **C.** each gated unit's `ConditionPathExists=` (with `%i` expanded) points at
  one of that feature's artifacts, so a typo on either side fails the build
  instead of silently disabling the feature forever.

It reads `${TARGET_DIR}/etc/system.vars`, not the build environment. It runs once
per filesystem type on a throwaway copy of `target/` that Buildroot deletes
afterwards, so it is idempotent by construction. Non-zero exit aborts the build
(the generated fakeroot script has `set -e`).

Only `testbot4_defconfig` is wired up: the allowlist was derived from testbot4's
image, and enabling it for testbot/testbot3 without checking their unit sets
would fail those builds for unrelated reasons.

Known allowlist entry worth revisiting: `systemd-networkd.service` is enabled by
preset and ships no `.network` files, so it manages nothing — a candidate for
removal from the defconfig rather than for the allowlist.

## Field findings: the `wwan0` bring-up path

Measured on live testbot4 hardware (EC200A, `EC200ACNHAR01A07M16`, China Telecom)
while chasing "wwan0 is up but no internet". Five separate defects, in the order
they were found; all are fixed. The fourth is also the case for Phase 1, and the
fifth is the one that came back — the same blackhole as the first, reached by a
different route, on an image that already carried the fix for it.

### 1. `AT+QNETDEVCTL` is not persistent (fixed)

The modem had a perfectly healthy PDP context (`+CGACT: 1,1`, `+CGPADDR:
1,"10.93.147.203"`, `+CSQ: 25,99`, registered on 46011) but reported
`+QNETDEVCTL: 0,0,0,0` — the data call was never bound to the ECM net device. The
host still gets a lease from the modem's *internal* DHCP server
(192.168.43.100/24 via 192.168.43.1) and can ping the modem, so the board looks
correctly configured while nothing reaches the internet. `AT+QNETDEVCTL=1,1,1`
fixed it instantly (223.5.5.5 at 44 ms).

**It does not survive a modem reset, despite the autoconnect argument.** Verified
three times: after each `AT+CFUN=1,1` the modem came back reporting `0,0,0,0`.
So it must be re-asserted on every enumeration, which is what
`ensure_netdev_bound()` in `quectel_ecm.sh` now does — placed *before* the
`usbnet` mode read, because `usbnet=1` takes the "nothing to do" early exit.

`AT+QCFG="nat"` is deliberately left at 0; traffic flows regardless.

### 2. `flock` FD leaked into `dhclient` (fixed)

`quectel_ecm_up.sh` did `exec 9> ${LOCK_FILE}; flock -n 9` and then `ifup`, which
spawns `dhclient` — a daemon that **inherits FD 9 and holds the lock for its
entire lifetime**. Every later invocation therefore exited silently at
`flock -n 9 || exit 0`, with no log line to show why. Confirmed by finding
`dhclient` in `/proc/*/fd/9` pointing at the lock file, and in the journal as a
udev-triggered run that logged `Starting` → `Deactivated successfully` in the
same second with zero script output.

Fixed by closing the descriptor on the commands that spawn daemons:
`ifdown --force ${IFACE} ... 9>&-` and `ifup ${IFACE} 9>&-`.

### 3. systemd reaped the DHCP client (stopgap applied)

`quectel-ecm-up.service` is `Type=oneshot` with `RemainAfterExit=no`, so the
default `KillMode=control-group` made systemd SIGTERM everything left in the
cgroup the moment the script exited. The journal shows it plainly:

```
dhclient[20761]: bound to 192.168.43.100 -- renewal in 40247 seconds.
systemd[1]: quectel-ecm-up.service: Deactivated successfully.
```

`wwan0` kept its address and its metric-700 route — nothing removes them — but
there was no client left to renew an 11-hour lease, so the link would have gone
quietly dead. `KillMode=process` added as a stopgap; Phase 1 removes the need for
it, because there the client *is* the main process.

### 4. `ENV{SYSTEMD_WANTS}` never reached the device at all (fixed)

The net rule's `ENV{SYSTEMD_WANTS}+="quectel-ecm-up.service"` produced no job —
not on a modem reset and, as the 2026-09-11 image showed, not on a cold boot
either. `wwan0` existed, `UP`-able, with no address, and `dhclient` had never run:

```
# systemctl is-active quectel-ecm-up.service        -> inactive (NRestarts=0)
# systemctl is-active sys-subsystem-net-devices-wwan0.device -> active
# systemctl show sys-subsystem-net-devices-wwan0.device -p Wants
Wants=
```

`udevadm test /sys/class/net/wwan0` prints `SYSTEMD_WANTS=quectel-ecm-up.service`,
so the rule matches — but the property was not in the device's database:

```
# grep SYSTEMD /run/udev/data/n3
E:SYSTEMD_ALIAS=/sys/subsystem/net/devices/wwan0     <- and nothing else
```

The mechanism is the rename. `79-quectel-ecm-name.rules` applies `NAME="wwan0"`,
the kernel emits a second uevent for it (`ACTION=move`, visible in dmesg as
`cdc_ether 1-1:1.0 wwan0: renamed from usb0`), udev re-runs the rules for it, the
`ACTION=="add"` rule does not match, and the database entry is rewritten *without*
`SYSTEMD_WANTS`. `udevadm trigger --action=add /sys/class/net/wwan0` puts the
property back, starts the unit and brings the uplink up on the spot — which is what
pinned the mechanism down, and also corrects an earlier reading of this same
symptom recorded here (that the device unit "stayed active plugged across the
reset", and that a synthetic `add` did not help — neither holds).

An `AT+CFUN=1,1` on the fixed-by-hand board then showed the second half:

```
15:55:22 usb 1-1: USB disconnect            -> BindsTo stopped the unit cleanly,
15:55:22 Stopped DHCP client for ... wwan0      no orphan dhclient, routes gone
15:55:31 cdc_ether 1-1:1.0 wwan0: renamed from usb1
15:55:31 Finished Switch Quectel modem to ECM mode
         ... and nothing started quectel-ecm-up.service
```

`Restart=always` cannot cover that: the unit was *stopped* by `BindsTo`, not
failed. So the fix is `[Install] WantedBy=sys-subsystem-net-devices-wwan0.device`
and deleting the net udev rule. A `.wants` link on the device unit is
level-triggered by construction — systemd starts the unit every time the device
unit activates, on the first boot and on every re-enumeration, with no property to
lose. `after-preset-check.sh` rule F fails the build if `preset-all` ever stops
creating that link, since an image without it boots, switches the modem to ECM and
leaves `wwan0` addressless — a failure with no error message anywhere.

### 5. One lock for two jobs, and a ten-minute blackhole (fixed)

Reported as "testbot is up but internet is not working" on the image that already
had finding 1's `ensure_netdev_bound()` in it. The modem again reported
`+QNETDEVCTL: 0,0,0,0`, and this time the reason was on our side of the serial
port: **`quectel_ecm.sh` never ran its checks at all.**

`modem-time` and `quectel_ecm.sh` both talk to the same ttyUSB, so they were made
to share `/run/quectel_ecm.lock`. But the two need opposite lock semantics, and
they had the same one:

```
16:25:04.869  Started Set system clock from the Quectel modem   <- modem-time
16:25:04.945  Started Switch Quectel modem to ECM mode          <- quectel_ecm, 76ms later
16:25:05.172  quectel-ecm.service: Deactivated successfully     <- 227ms in, exit 0, silent
```

`modem-time` polls, so it holds the port for a full AT round (port discovery plus
two commands, ~9 s measured) and it won the race by 76 ms. `quectel_ecm.sh`'s
`flock -n 9 || exit 0` is a *single-instance* guard — "another mode switch is
already running, I have nothing to add" — and applying it to a *port* contention
turned it into "someone else is using the modem, so skip the entire job". Not one
`quectel_ecm` line appears in the journal for ten minutes.

What followed looked healthy from every vantage point on the board: `wwan0`
appeared, `dhclient` took 192.168.43.100 from the modem's own DHCP server, the
metric-700 default route was installed, `ping 192.168.43.1` answered — and not one
packet reached the carrier, because the data call was never bound. The user's
laptop associated at 16:25:15, had a lease at 16:25:20, saw nothing work, and gave
up at 16:25:45. The blackhole ended at 16:35:37, when an unrelated modem
re-enumeration finally let the mode switch win the lock and assert
`AT+QNETDEVCTL`.

The fix is two locks with the semantics each job actually needs
(`quectel_at.inc`):

| Lock | fd | Mode | Owner | Question it answers |
|---|---|---|---|---|
| `/run/quectel_at.lock` | 8 | blocking, `-w ${LOCK_WAIT}` | both scripts, via `with_modem_lock` | may I talk to the serial port? |
| `/run/quectel_ecm.lock` | 9 | `flock -n`, exit 0 | `quectel_ecm.sh` only | is another mode switch already running? |

`quectel_ecm.sh` now runs *all* of its AT work — port discovery, the
`QNETDEVCTL` assertion, the `usbnet` read, the mode switch — inside one
`with_modem_lock ecm_check` hold with `LOCK_WAIT=60`, because waiting a minute for
a poller that holds the port for nine seconds is obviously right and skipping the
job is obviously wrong. `with_modem_lock` returns **111** when it never got the
port, which is deliberately distinct from anything `ecm_check` returns: "the modem
was busy" and "the modem refused" are different failures, and it was the first of
them that used to be silent.

Contributing factor, not the cause, and **not fixed**: `dhclient` starts at boot+3 s
with the fake pre-NITZ clock, and the jump when `modem-time` sets the real clock
(`+60745205 s` on the current image) expires all of its timers at once. On the
outage boot that caught it mid-`DHCPDISCOVER`: `No DHCPOFFERS received` →
`sleeping`, and the retry only landed at 16:28:17, so for the first 3.4 minutes
`wwan0` had no address either. Whether it hurts is pure luck of ordering — on the
verification boot below the lease landed 19 s *before* the jump and the uplink was
up throughout. It is benign in the steady state (the lease comes from the modem's
own always-on DHCP server and `QNETDEVCTL` autoconnect redials by itself), but the
renewal deadline is left in the past and nothing has been measured about what
`dhclient` does with an 11-hour lease it thinks expired two years ago. If this ever
needs fixing the shape is ordering, not retries: set the clock before starting the
DHCP client, or restart the client once the clock moves.

Verified on the rebuilt image (slot 1), on the first boot after the deploy — the
same race, now won by waiting instead of skipping:

```
15:42:36.743  Starting Set the system clock from the Quectel modem (AT+QLTS)
15:42:36.750  Starting DHCP client for the Quectel ECM uplink (wwan0)
15:42:36.760  Starting Switch Quectel modem to ECM mode        <- 17ms behind again
15:42:42.077  modem_time: attempt 1/12: ... outside the plausible window   <- held the port
15:42:44.569  dhclient: DHCPACK of 192.168.43.100 from 192.168.43.1
15:42:47.152  quectel_ecm: data call not bound (+QNETDEVCTL: 0,0,0,0), binding it
15:42:50.521  quectel_ecm: AT+QNETDEVCTL=1,1,1 accepted
15:42:52.892  quectel_ecm: usbnet=1 (ECM) already set, nothing to do
```

`quectel_ecm` lost the port by 17 ms, waited ~10 s for `modem-time`'s first attempt
to finish, and did its whole job — 11 s from enumeration to a bound data call
instead of ten minutes to none. No `111`, no `flock` timeout, no failed units.
`ping 1.1.1.1` from the board: 74 ms average, and the probe through the tunnel
answers `HTTP/1.1 301`.

## Does any of this need a watcher?

**No — not for the model above.** Metric-ordered default routes plus static
uplink-agnostic NAT is fully declarative. DNS is already uplink-agnostic:
`resolv.conf` is a static `nameserver 1.1.1.1` and `dhclient-script`
deliberately does not overwrite it (its `cat /etc/resolv.conf.*` lines are
commented out).

A watcher is only needed for **reachability-based** failover: an uplink with
carrier and a lease but no working internet (dead SIM, captive portal, switch
with no upstream). Metrics encode presence, not reachability. Constraints if we
go there:

- `/sbin/ip` is a **busybox applet** (5.9 KB against `libbusybox.so.1.36.1`), not
  iproute2. There is no `ip monitor`, so route watching must poll. `ip route …
  metric` works; **`ip rule` and named tables do not** — see Phase 5, where both
  were measured on the board. (An earlier revision of this document claimed they
  did, on the assumption that `usbstart.sh` and `rc.local` used them. Neither
  ever did — `grep 'ip rule\|table ' ` finds nothing in either.)
- Sizing: ~50-line probe loop, `Restart=always` unit or a timer, plus optionally
  `conntrack -F` on uplink change (`conntrack-tools` is already in the image).
- On uplink failover an active OpenVPN tunnel dies until it reconnects, because
  the host route to the server via the old gateway goes stale. OpenVPN recovers
  on its own via keepalive/ping-restart; tuning that is part of Phase 5, not
  earlier.

## Phase 5 — Xray as the LAN's uplink (planned)

Goal: **every packet the board forwards from `usb0` or `wlan0` leaves through an
Xray client running on the board**; everything the board itself originates
(dhclient, SSH, the modem's AT session, Xray's own connection to the server)
keeps going out directly. That asymmetry is the whole design, and it falls out of
one decision: intercept in **`mangle PREROUTING`** only, never in `OUTPUT`.

Consequences worth stating up front, because they are what makes this cheap:

- No `OUTPUT` rule means no "don't proxy the proxy" problem — no `-m owner
  --uid-owner`, no cgroup match, no mark reserved for Xray's own sockets, and no
  way to lock myself out of the board over `usb0` while editing rules.
- Xray's outbound is an ordinary socket, so it follows the **metric ladder**
  (`/etc/iface-metrics`) like everything else. Uplink failover needs no code: the
  TCP connection to the server dies with the old gateway, Xray redials, and it
  redials over whatever uplink now has the lowest metric. Contrast OpenVPN's
  `redirect-gateway def1`, which installs `0.0.0.0/1` + `128.0.0.0/1` and fights
  the ladder (see the note in `/etc/iface-metrics`).
- No tunnel interface at all, so nothing to add to the metric ladder, no MTU or
  MSS clamping (Xray terminates the client's TCP locally and opens its own), and
  `netpolicy`'s NAT set stays exactly as it is.

### What the board can do today — measured, not assumed

Everything below was checked on the running testbot4 (`/proc/config.gz`, live
`ip`/`iptables`), because each item is a build change if it is missing.

**1. The kernel has none of the transparent-proxy machinery.**

```
# zcat /proc/config.gz | grep -E 'TPROXY|MATCH_SOCKET|MULTIPLE_TABLES|ADVANCED_ROUTER|REDIRECT'
(nothing)
# zcat /proc/config.gz | grep -E 'XT_MARK|MATCH_ADDRTYPE|TUN'
CONFIG_NETFILTER_XT_MARK=m
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=m
CONFIG_TUN=y
```

`CONFIG_IP_ADVANCED_ROUTER` off means `CONFIG_IP_MULTIPLE_TABLES` is off, i.e.
**no policy routing at all**:

```
# ip rule add fwmark 0x1 lookup 100
ip: RTNETLINK answers: Operation not supported
```

`REDIRECT` is not built either (`iptables -t nat -j REDIRECT` → "Extension
REDIRECT revision 0 not supported, missing kernel module?"), so the simpler
NAT-based interception is not a shortcut we already have — and it could not carry
UDP anyway. Since a `linux-rebuild` is unavoidable, TPROXY is the choice.

Fragment to add to `board/customized/orangepi/linux_zero3.config`:

```
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MULTIPLE_TABLES=y
CONFIG_NETFILTER_XT_TARGET_TPROXY=m
CONFIG_NF_TPROXY_IPV4=m
CONFIG_NETFILTER_XT_MATCH_SOCKET=m
CONFIG_NF_SOCKET_IPV4=m
```

`xt_socket` is not needed by the forwarding-only rule set below (reply packets
come back out of Xray's own transparent socket, which is local output, not
`PREROUTING`), but it is the one piece that would be missing if we ever want to
proxy the box's own traffic too, and it costs one module. The userspace side is
already there: `iptables v1.8.10 (legacy)` has the `TPROXY`, `socket`, `owner`
and `addrtype` extensions compiled in, so only the kernel is short.

**2. `busybox ip` cannot do policy routing, and fails *silently*.** This is the
nastiest finding of the phase. `ip rule` at least reports the kernel's refusal,
but `table` is parsed and thrown away:

```
# ip route add local default dev lo table 100
# ip route                     # <-- "table 100" was ignored; this is table main
local default dev lo scope host
default via 192.168.43.1 dev wwan0  metric 700
...
```

A `local default` in `main` with metric 0 beats every real default route, so that
one command black-holes the entire uplink to the local stack. (Observed live and
removed with `ip route del local default dev lo`.) So Phase 5 also brings in
**`BR2_PACKAGE_IPROUTE2=y`**. `/sbin` is a symlink to `usr/sbin`, so iproute2's
`/usr/sbin/ip` lands on the same path as the busybox symlink and, being installed
after busybox, wins — that is exactly the kind of thing that must be *asserted*
at build time rather than assumed (rule G below). It also gets us `ip monitor`,
which the Phase 6 watcher wanted.

**3. The clock is wrong and NTP cannot fix it on this SIM.**

```
# date
Tue Oct  8 16:24:37 UTC 2024          # RTC has no battery: RTC time = 1970-01-02
# timedatectl | grep synchronized
System clock synchronized: no
# journalctl -u systemd-timesyncd
Timed out waiting for reply from 216.239.35.12:123 (time4.google.com)   (x many)
```

DNS resolves, so timesyncd is reaching the network — UDP/123 itself is dropped.
A two-year-old clock breaks TLS certificate validity and REALITY alike, so this
is a hard prerequisite, not polish. The fix is already on the board: the modem
knows the network time.

```
# echo -e 'AT+CCLK?\r' > /dev/ttyUSB2   (reading the reply back)
+CCLK: "26/09/11,12:25:41+32"          # correct; +32 = quarter-hours = UTC+8
```

So Phase 5 adds a small `modem-time` oneshot in the `quectel_ecm` overlay that
parses `AT+CCLK?` and `date -s`. It is ordered before `xray.service` and, being
part of the Quectel overlay, is gated by the same artifacts as the rest of it.
`systemd-timesyncd` stays enabled and will correct the clock properly whenever
the board sits behind an uplink that permits NTP.

**No NTP package is needed, and none would help.** `systemd-timesyncd` is already
in the image and already enabled (`sysinit.target.wants`), and it is a full SNTP
client — `ntp`, `chrony` or `busybox ntpd` would send the same UDP/123 packets
into the same filter. Nor can the tunnel rescue it: this design intercepts
`PREROUTING` only, so the board's *own* NTP traffic never enters the tunnel, and
even if an exception were added, REALITY puts a client timestamp in the
ClientHello that the server checks against a tolerance window — a two-year skew
fails the handshake before there is a tunnel to sync through. The board also has
no RTC battery (`RTC time: Fri 1970-01-02`), so this is a cold-boot problem every
time, not a one-off. The modem is the only source that is in-band, permitted, and
available before the first TLS handshake.

**4. The APN does pass 443 to the real server.** Measured over `wwan0` against the
actual endpoint from `XRAY_CONFIG`, with this build host as the control:

| Target | Board over `wwan0` | Host (control) |
|---|---|---|
| `170.205.36.149:443` (REALITY) | **ok** — TLS in 0.69 s, `HTTP 200` through the front | ok |
| `170.205.36.149:8388` (shadowsocks) | blocked | ok |
| `1.1.1.1:443`, `8.8.8.8:443`, `8.8.8.8:853` | blocked | ok |
| `8.8.8.8:53`, `1.1.1.1:53` (TCP and UDP) | ok | ok |
| UDP/123 to any NTP server | blocked | ok |
| ICMP | ok, 0% loss | ok |

End-to-end proof, run on the board with its 2024 clock (hence `-k`), which drives
the REALITY front all the way to the real site behind it:

```
# curl -k --resolve www.cloudflare.com:443:170.205.36.149 https://www.cloudflare.com/
http_code=200 tls=0.687216s total=5.569405s
```

An earlier pass of this section concluded "the APN filters 443" from probes to
`1.1.1.1`, `8.8.8.8` and `93.184.216.34`. That was wrong: the first two are public
resolvers, and this carrier specifically blocks DoH/DoT to them (which is exactly
the `:443`/`:853` pattern above, with `:53` left open), while `93.184.216.34` is
the retired `example.com` address that stopped answering in 2025. **Probe the
endpoint you actually care about.** What survives from that pass: UDP/123 really is
blocked (four different Google NTP addresses, repeatedly, over hours), and this
server's shadowsocks port really is unreachable from the board while the host
reaches it — so the carrier does police some non-standard ports. 443 is not one of
them, so REALITY on 443 needs no workaround and no second listener.

**5. Space and TLS trust.** `rootfs.ext2` is 512 MB with ~206 MB free at build
time (473 MB free at runtime on the overlay, but the image is what OTA ships), so
a 30–50 MB Go binary fits without resizing anything. `/etc/ssl/certs` exists and
is **empty** — there is no `ca-certificates` package in the image. With REALITY
that is fine: the server is authenticated by its public key (`pbk`), not by a
certificate chain, and the certificate the front presents is Cloudflare's real one
which we never validate. So `BR2_PACKAGE_CA_CERTIFICATES=y` is optional — worth
half a megabyte only for `curl https://` to work as a diagnostic (today it needs
`-k`, which is how the probe above was run).

### Packages

| Need | State | Action |
|------|-------|--------|
| `xray` | **absent** — no xray/v2ray/sing-box in the tree (`package/shadowsocks-libev` is the only relative) | new package, see below |
| `iproute2` | **absent** (busybox applet only) | `BR2_PACKAGE_IPROUTE2=y` |
| `ca-certificates` | **absent**, `/etc/ssl/certs` empty | optional — REALITY authenticates by `pbk`, so only `curl https://` wants it |
| `iptables` 1.8.10 legacy | present, all needed extensions built | — |
| `conntrack-tools` | present (`BR2_PACKAGE_CONNTRACK_TOOLS=y`) | used for `conntrack -F` on transitions |
| `dnsmasq` | present, with conntrack support | two `server=` lines added, see DNS |
| kernel netfilter/policy routing | **absent** | fragment above + `linux-rebuild` |
| `host-go` | present, **1.23.6** (`BR2_PACKAGE_HOST_GO=y` already in the defconfig) | decides which Xray we can compile |
| NTP client | `systemd-timesyncd` present and enabled | **no package needed** — UDP/123 is filtered, not missing; clock comes from `AT+CCLK?` |
| geoip/geosite `.dat` | absent | **not needed** — routing everything means no geo rules |

Three ways to get the binary, all viable, checked against the real releases:

- **(A) prebuilt release, recommended for the first cut.** `Xray-linux-arm64-v8a.zip`,
  19.7 MB, from the current release (`v26.3.27`, 2026-03-27). A ~15-line generic
  package with `$(UNZIP)` in `_EXTRACT_CMDS` (the pattern `package/angularjs`
  uses; `$(UNZIP)` is defined in `package/Makefile.in`), hash pinned. No
  toolchain churn, byte-identical to what the server side is presumably tested
  against. License MPL-2.0.
- **(B) build from source with the host-go we have.** `$(eval $(golang-package))`
  gets us vendoring for free (`pkg-golang.mk` sets `_DOWNLOAD_POST_PROCESS = go`
  for every Go package, so `make xray-source` vendors the modules), the .mk is
  five lines on the `package/cloudflared` model, and `XRAY_BIN_NAME = xray` fixes
  up the `main` build target's name. But `go.mod` pins the toolchain, and
  host-go is 1.23.6:

  | tag | `go` directive |
  |---|---|
  | `v26.3.27` (current) | 1.26 |
  | `v25.8.3`, `v25.3.6` | 1.24 |
  | `v24.12.31` | 1.21.4 |

  So (B) means pinning `v24.12.31` — 15 months old, and REALITY has moved since
  (post-quantum key exchange landed in the 25.x line). Acceptable only if the
  server is configured to match.
- **(C) bump `GO_VERSION` in `package/go` to ≥1.26 and build current.** The clean
  end state, but a host-toolchain bump with its own bootstrap chain, and nothing
  else in this image needs it. Do it later, if at all.

Recommendation: (A) now, revisit (C) once the phase works. Note (B)/(C) also let
us pass `-s -w -trimpath`, which is worth ~25% of the binary.

### Files, and who owns each one

Beyond `config.json` itself:

| Path | What | Owner |
|------|------|-------|
| `/etc/xray/config.json` | the config, **and the gating artifact** | new `0013-xray_client_service.sh`, generated from the `XRAY_CONFIG` share URL |
| `/etc/systemd/system/xray.service` | daemon; `ConditionPathExists=/etc/xray/config.json`, `AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE`, `ExecStartPost=`/`ExecStopPost=` the policy script, `Restart=always` (see "Hardening" below — `on-failure` misses a clean exit) | new `services/xray/` overlay |
| `/usr/sbin/xraypolicy` | `add`/`del`/`boot` of the rule set **and of the LAN's DNS upstream**; idempotent via `iptables -C`, tolerant of missing rules on `del`; `conntrack -F` on both | new, sibling of `/usr/sbin/netpolicy` |
| `/usr/sbin/xray-health` | probes *through* the tunnel once a minute; restarts `xray`, then fails the LAN open, then restores it — see "Hardening" | new, in the same overlay |
| `/etc/systemd/system/xray-health.{service,timer}` | the timer that runs it; the `.timer` carries the `[Install]` and the same `ConditionPathExists=`, the `.service` has no `[Install]` at all | same overlay |
| `/run/xray-dns.conf` | the LAN's DNS upstream, one `nameserver` line: the `dns-in` inbound while the tunnel is up, `XRAY_DNS_UPSTREAM` while it is down | written by `xraypolicy`, read by `dnsmasq` |
| `/etc/dnsmasq_wlan0.conf`, `/etc/dnsmasq_usb0.conf` | `resolv-file=/run/xray-dns.conf` appended when `XRAY_CLIENT=ON` | base file stays with `0007`/`0010`; `0013` appends (it runs after both, and both rewrite their file from scratch every build) |
| `/etc/systemd/system/modem-time.service`, `/usr/sbin/modem-time` | clock from `AT+CCLK?`; `Before=xray.service` | `quectel_ecm` overlay |
| `/etc/sysctl.d/30-xray.conf` | pins `net.ipv4.conf.all.rp_filter=2` | new; today the board happens to have `all=0`, `default=2`, which already works — this only stops a future default from breaking the reply path |
| `/etc/system.vars` | new `XRAY_CLIENT=OFF` line | `system_v2` overlay + `0013`'s `sed` (the `sed` needs the key to pre-exist) |
| `board/customized/orangepi/orangepi4-test.vars` | the `XRAY_*` block | — |
| `after-preset-check.sh` | `check_feature XRAY_CLIENT` + rule G | — |

### Configuration contract: two vars, one input file

Same two-part shape as OpenVPN (`VPN_CLIENT` + `VPN_CONFIG`), deliberately, so
there is nothing new to learn:

```sh
################ xray vpn client #######################################
# ON generates /etc/xray/config.json from XRAY_CONFIG and lets xray.service start
export XRAY_CLIENT=ON
# Client config to import. A vless:// REALITY share URL, a sing-box JSON
# outbound, or a ready-made xray config.json - 0013 detects which.
export XRAY_CONFIG=/home/denisov/vpn/laptop-singapore/singbox-reality.txt
# Everything below has a working default; set only to override
export XRAY_TPROXY_PORT=12345
# the DNS inbound's own loopback address, on port 53 (see DNS)
export XRAY_DNS_ADDR=127.0.0.2
export XRAY_DNS_UPSTREAM=1.1.1.1
export XRAY_PROBE_PORT=5301
export XRAY_LAN_IFACES="usb0 wlan0"
export XRAY_KILLSWITCH=OFF
```

**No credential is ever a variable.** The `uuid`, `pbk` and `sid` exist only in the
file `XRAY_CONFIG` points at and in the generated `config.json`. Both the vars
files and this document are in git; that file is not. Only `XRAY_CLIENT` is
written into `/etc/system.vars` (by `0013`'s `sed`, which needs the key to
pre-exist in the `system_v2` overlay copy), because that is the file
`after-preset-check.sh` reads and the target can introspect.

`0013-xray_client_service.sh`, on `0008`'s model:

```sh
# 1. always clean up first - output/target/ is not wiped between builds and the
#    overlay rsync has no --delete, so a config from an XRAY_CLIENT=ON build
#    would otherwise survive into an OFF one and re-enable the whole feature
delete_file_silent ${TARGET_DIR}/etc/xray/config.json

# 2. gate
[[ ${XRAY_CLIENT} == OFF ]] && exit 0          # nothing installed, unit condition fails
[[ ${XRAY_CLIENT} != ON  ]] && die "only ON or OFF"
[[ -z ${XRAY_CONFIG}     ]] && die "XRAY_CLIENT=ON but XRAY_CONFIG is not set"
[[ -r ${XRAY_CONFIG}     ]] || die "XRAY_CONFIG=${XRAY_CONFIG} is not readable by $(id -un)"

# 3. detect the input shape by its first bytes and extract the outbound fields
case $(head -c 8 "${XRAY_CONFIG}") in
vless://*) parse_share_url ;;                  # what we have today
'{'*)      parse_json ;;                       # sing-box outbound or xray config
*)         die "unrecognised config format" ;;
esac

# 4. every field the outbound needs must have come out non-empty; a silently
#    dropped sid or flow fails at runtime as a plain timeout with no log line
for v in HOST PORT UUID PBK SID SNI FP FLOW; do
        [[ -n ${!v} ]] || die "could not extract ${v} from ${XRAY_CONFIG}"
done

# 5. render the skeleton below, substituting @HOST@ &co
create_dir ${TARGET_DIR}/etc/xray
sed -e "s|@HOST@|${HOST}|" ... > ${TARGET_DIR}/etc/xray/config.json

# 6. point the LAN resolvers at the DNS inbound (see DNS)
for f in dnsmasq_wlan0.conf dnsmasq_usb0.conf; do ... done
```

Parsing is `sed` and shell parameter expansion — no `jq` on the build host and
none in the image. `parse_share_url` is a `${url#...}`/`${url%%...}` walk over
`vless://<uuid>@<host>:<port>?<query>#<name>` plus one `tr '&' '\n'` over the
query; `parse_json` is a `sed -n 's/.*"key": *"\([^"]*\)".*/\1/p'` per field,
which is ugly but adequate for machine-generated single-level JSON, and it fails
loudly at step 4 rather than quietly if the shape is unexpected.

Field mapping, share URL → Xray outbound (sing-box JSON keys in the third column
for `parse_json`):

| URL param | Xray | sing-box JSON |
|---|---|---|
| userinfo before `@` | `settings.vnext[0].users[0].id` | `uuid` |
| host / port | `settings.vnext[0].address` / `.port` | `server` / `server_port` |
| `type=tcp` | `streamSettings.network` | `transport` absent = tcp |
| `security=reality` | `streamSettings.security` | `tls.reality.enabled` |
| `pbk` | `realitySettings.publicKey` | `tls.reality.public_key` |
| `sid` | `realitySettings.shortId` | `tls.reality.short_id` |
| `sni` | `realitySettings.serverName` | `tls.server_name` |
| `fp` | `realitySettings.fingerprint` | `tls.utls.fingerprint` |
| `flow` | `users[0].flow` | `flow` |
| `encryption=none` | `users[0].encryption` | — (implicit) |
| `#name` | ignored (label only) | `tag` |

`fp` is the one field it would be tempting to drop: it is the uTLS fingerprint,
i.e. half of what makes the handshake look like a browser, so it is in the
required list at step 4. The file being named `singbox-reality.txt` changes
nothing — the URL scheme is protocol-generic and VLESS+REALITY is the same wire
protocol whichever implementation terminates it, so an Xray client against a
sing-box inbound is fine.

Nothing writable is needed at runtime: Xray logs to stderr (journal) and keeps no
state, so the read-only rootfs is fine and `/media/data` stays out of it. If
selective routing is ever wanted, `geoip.dat`/`geosite.dat` go to
`/media/data/xray` with `Environment=XRAY_LOCATION_ASSET=/media/data/xray`.

### The rule set

Two inbounds in `config.json`: a `dokodemo-door` on `0.0.0.0:12345` with
`followRedirect: true` and `sockopt.tproxy: "tproxy"` (both TCP and UDP), and a
second `dokodemo-door` on `127.0.0.1:5353` for DNS. One `vless` outbound to the
server, one `freedom` outbound, and no routing rules — the default outbound is the
proxy, so everything that reaches an inbound goes into the tunnel, which is the
requirement. `@…@` are substituted by `0013` from the share URL:

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "tproxy", "listen": "0.0.0.0", "port": 12345, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy", "mark": 255 } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] } },
    { "tag": "dns-in", "listen": "127.0.0.1", "port": 5353, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "address": "1.1.1.1", "port": 53 } }
  ],
  "outbounds": [
    { "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [ { "address": "@HOST@", "port": @PORT@,
        "users": [ { "id": "@UUID@", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "@SNI@", "fingerprint": "@FP@",
          "publicKey": "@PBK@", "shortId": "@SID@" } } },
    { "tag": "direct", "protocol": "freedom" }
  ]
}
```

`sockopt.mark: 255` is the convention every TPROXY recipe carries, and it is worth
keeping for the day someone adds `OUTPUT` interception — that is where the
companion `-m mark --mark 0xff -j RETURN` rule stops the proxy from proxying
itself. With this phase's `PREROUTING`-only rule set it is **not** load-bearing:
Xray's replies and its connection to the server are locally generated, they never
enter `PREROUTING`, they carry no fwmark 1, and so the `ip rule` and table 100
never see them. The loop this guards against cannot happen here.

Sniffing is on because with `destOverride` the tunnel carries hostnames rather
than the IP the client resolved, which is what makes the server's own DNS view
authoritative and keeps SNI consistent with the request. It is also the piece that
makes `quic` traffic identifiable rather than opaque UDP.

DNS needs no `"dns"` block: the second inbound rewrites every query it receives to
`1.1.1.1:53` and hands it to the proxy outbound, so resolution happens from the
server's side of the tunnel. The board's own resolver stays `/etc/resolv.conf` →
`1.1.1.1` direct, which is what lets Xray resolve `@HOST@` before a tunnel exists
(here it is a literal address, so even that is moot).

`/usr/sbin/xraypolicy add`:

```sh
ip rule add fwmark 0x1 lookup 100
ip route add local default dev lo table 100

iptables -t mangle -N XRAY
iptables -t mangle -A XRAY -m addrtype --dst-type LOCAL -j RETURN   # the box itself
iptables -t mangle -A XRAY -d 127.0.0.0/8   -j RETURN
iptables -t mangle -A XRAY -d 10.0.0.0/8    -j RETURN               # LAN-to-LAN,
iptables -t mangle -A XRAY -d 172.16.0.0/12 -j RETURN               # and the modem's
iptables -t mangle -A XRAY -d 192.168.0.0/16 -j RETURN              # own 192.168.43/24
iptables -t mangle -A XRAY -d 224.0.0.0/4   -j RETURN
iptables -t mangle -A XRAY -d 255.255.255.255/32 -j RETURN
iptables -t mangle -A XRAY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 0x1
iptables -t mangle -A XRAY -p udp -j TPROXY --on-port 12345 --tproxy-mark 0x1

for i in ${XRAY_LAN_IFACES}; do
        iptables -t mangle -A PREROUTING -i "$i" -j XRAY
done
conntrack -F
```

Keyed on `-i <lan iface>` for the same reason `netpolicy` is keyed on `-s <lan
subnet>`: `iptables` evaluates it at packet time, so the rules can be installed
before any interface exists, they are inert while the AP or the gadget is down,
and restarting `hostapd` or re-plugging the gadget cannot disturb them. No uplink
appears anywhere in the set — there is no list to keep in sync.

The RFC1918 `RETURN`s are what keep LAN-to-LAN traffic and management traffic out
of the tunnel; `--dst-type LOCAL` is what keeps my SSH session alive. Note this
also means a LAN client cannot reach an RFC1918 address *behind the server* — if
the server is a site-to-site peer rather than an exit node, those subnets need an
explicit `-j XRAY`-side exception ahead of the `RETURN`s.

### Triggers — what adds and removes the rules

| Event | Effect | Mechanism |
|---|---|---|
| boot, `XRAY_CLIENT=ON` | Xray starts, rules go in | `multi-user.target.wants` (from `preset-all`) + `ConditionPathExists=/etc/xray/config.json` + `ExecStartPost=/usr/sbin/xraypolicy add` |
| boot, `XRAY_CLIENT=OFF` | nothing happens at all | the condition fails; no config file, no rules |
| `systemctl stop xray` / crash / shutdown | rules come out, LAN falls back to direct NAT **and to a direct resolver** via `netpolicy`/`xraypolicy del` | `ExecStopPost=/usr/sbin/xraypolicy del` — `ExecStopPost` runs on *every* exit path, including failure |
| Xray restart (`Restart=always`) | brief direct window, bounded by `RestartSec` | deliberate; see fail-open below |
| tunnel alive but carrying nothing | probe fails 3× → restart; still failing → rules out, LAN direct; probe answers → rules back | `xray-health` on a 60s timer; see "Hardening" |
| AP or USB gadget toggled | nothing to do | rules match interface names, inert without an address |
| uplink change (`wwan0` ↔ `eth0` ↔ `wlan1`) | nothing to do | Xray's outbound follows the metric ladder; the tunnel redials |
| tunnel up or down | stale flows dropped so clients repath immediately | `conntrack -F` in both `add` and `del` |
| OTA update | nothing special | config is in the image; no runtime state |

**Fail-open is the default and it is a choice.** With the rules owned by the
daemon's own unit, a dead Xray means LAN traffic goes out directly — clients keep
working, and they keep working *unprotected*. The alternative is one rule, added
by `netpolicy` when `XRAY_KILLSWITCH=ON` and removed by `xraypolicy add`:

```
iptables -I FORWARD -i usb0 ! -o usb0 -j REJECT --reject-with icmp-port-unreachable
```

Default OFF, because locking the LAN out of the network on a test box that is
reached *through* that LAN is a worse first failure than a leak. Flip it once the
phase is proven.

Why not `tun2socks` on a TUN device (`CONFIG_TUN=y` already): it needs no kernel
rebuild, but it puts a routed interface back in the picture — default-route
juggling against the metric ladder, MTU/MSS handling, and a second userspace hop.
TPROXY keeps the routing model exactly as Phases 1–4 left it. Keep it as the
fallback if the UDP TPROXY path misbehaves; the TCP-only degradation (TPROXY for
TCP, DNS through the `dokodemo-door`, and `-p udp --dport 443 -j DROP` so
browsers give up on QUIC) is simpler and worth knowing about.

### DNS

Untouched, LAN clients leak DNS: `dnsmasq` on `wlan0`/`usb0` has no `server=`
line, so it forwards to `/etc/resolv.conf` (`nameserver 1.1.1.1`) as *locally
generated* traffic — which `PREROUTING` never sees. On this SIM UDP/53 is one of
the few things that works, so it would resolve perfectly and quietly, out of band.

Fix without touching the resolver the board itself uses: point both dnsmasq configs
at the `dns-in` inbound shown above. Requests to it are ordinary local sockets, so
no TPROXY is involved on this path, and the board's own lookups keep going to
`1.1.1.1` directly.

**Indirectly, through a file, and not with a `server=` line** — that was the first
implementation (`no-resolv` + `server=127.0.0.1#5300`) and it is wrong, because the
upstream has to follow the routing. When Xray dies the rules come out and the LAN
falls back to direct NAT, but a hard-wired `server=` keeps pointing at an inbound
that is gone: traffic fails open onto a path that cannot resolve a name. So:

```
# /etc/dnsmasq_{wlan0,usb0}.conf, appended by 0013
resolv-file=/run/xray-dns.conf
# written by xraypolicy: "nameserver 127.0.0.2" on add, "nameserver 1.1.1.1" on del
```

`dnsmasq` polls a `resolv-file` and re-reads it (plus flushes its cache) on
`SIGHUP`, which `xraypolicy` sends; it never re-reads its *config* file, which is
why the upstream has to be expressible as a plain `nameserver` line. That means no
port, which is why the DNS inbound gets an address of its own (`XRAY_DNS_ADDR`,
default `127.0.0.2`) on port 53 instead of a port on `127.0.0.1`. `no-resolv` must
not be present — it makes `dnsmasq` ignore every resolv-file — and `0013` strips it,
`after-preset-check` rule G refuses a build that still has it.

With `XRAY_KILLSWITCH=ON` the down state writes *no* nameserver at all: a LAN that
cannot leave the box must not be able to resolve either.

Worth noting what this does *not* fix: a LAN client that ignores the DHCP
nameserver and talks to `8.8.8.8` itself is still forwarded, so it is caught by
`PREROUTING` and goes through the tunnel anyway — correct, just by a different
route. And DoH clients (every modern browser) never use dnsmasq at all; their
`:443` goes into the tunnel like any other TCP. The dnsmasq change matters for the
plain-`resolv.conf` clients, which is most embedded things.

### Build-time assertions (`after-preset-check.sh` rule G)

Same principle as rule F: the failure mode is silent, so check the artifact, not
the intention.

- `check_feature XRAY_CLIENT "${XRAY_CLIENT:-OFF}" "xray.service xray-health.timer
  xray-health.service" "/etc/xray/config.json"` — covers "ON but no config", "OFF
  but config still shipped" and "one of the three units' `ConditionPathExists=`
  points somewhere else".
- With `XRAY_CLIENT=ON`: `/usr/bin/xray`, `/usr/sbin/xraypolicy` and
  `/usr/sbin/xray-health` exist, and so does an `nc` — without one the probe can
  never succeed and the health check would restart Xray forever.
- `xray-health.timer` is linked into `timers.target.wants`. Same silent failure as
  rule F's device-unit links, and rule A does not walk that directory: without the
  link the image boots, Xray runs, and nothing ever notices a dead tunnel.
- `/usr/sbin/ip` is **not** a busybox symlink (`readlink` empty / ELF), because if
  busybox wins that path the policy-routing commands fail silently and, worse,
  `ip route add … table 100` lands in `main`.
- With `XRAY_CLIENT=ON`: the dnsmasq configs that exist contain
  `resolv-file=/run/xray-dns.conf` and do **not** contain `no-resolv`, so an
  appended line lost to a reordering of the createfs scripts — or a leftover
  `no-resolv` that silences the resolv-file — is caught at build time instead of as
  a DNS leak in the field.

### Step order

1. Kernel fragment + `linux-rebuild`; verify the six symbols in
   `/proc/config.gz` and that `ip rule add` stops returning `EOPNOTSUPP`.
2. `BR2_PACKAGE_IPROUTE2=y` (+ `ca-certificates`); verify `ip -V` says iproute2
   on target.
3. `modem-time`; verify `date` is right on a cold boot with only `wwan0`.
4. `package/xray` (option A) — nothing wired up yet; verify `xray version` runs.
5. `services/xray` + `0013` + vars, `XRAY_CLIENT=OFF` first: the build must be
   byte-for-byte uneventful and `after-preset-check` must pass.
6. Turn it on: `XRAY_CLIENT=ON`,
   `XRAY_CONFIG=/home/denisov/vpn/laptop-singapore/singbox-reality.txt`,
   `XRAY_KILLSWITCH=OFF`. Diff the generated `/etc/xray/config.json` against the
   share URL field by field before booting it — a wrong `sid` or a dropped `flow`
   fails as a timeout, with nothing useful in the log.
7. Only then the dnsmasq `resolv-file=` lines.
8. Kill switch, if wanted.
9. Hardening: `Restart=always`, DNS through `/run/xray-dns.conf`, `xray-health`.
   Added after the first working boot, for the failure modes in "Hardening" below.

Steps 1–2 are the only ones that need a full `linux-rebuild`+image cycle, and
steps 5–8 are overlay/script-only.

### Verification on hardware

- `zcat /proc/config.gz | grep -E 'TPROXY|MULTIPLE_TABLES'` — all present;
  `lsmod` shows `xt_TPROXY` after the first packet.
- `ip rule` lists the fwmark rule; `ip route show table 100` shows exactly
  `local default dev lo`; **`ip route`** (main) shows *no* `local default`.
- `iptables -t mangle -S` matches the set above; `iptables -t mangle -L XRAY -vn`
  counters climb while a LAN client browses, and the `RETURN` counters climb for
  LAN-to-LAN.
- From a `wlan0` client: `curl https://ifconfig.me` returns the **server's**
  address; `tcpdump -i wwan0 'udp port 53'` stays silent while the client
  resolves; a UDP-only application works (that is the TPROXY UDP path).
  `usb0` clients need `dhcp-option=3` reconsidered or a manual route — the usb0
  dnsmasq deliberately pushes no default gateway today.
- SSH into `192.168.100.1` survives `xraypolicy add` (the `--dst-type LOCAL`
  `RETURN`), and survives a reboot with the rules in place.
- `systemctl stop xray` → `iptables -t mangle -S PREROUTING` is empty again and
  clients still reach the internet (fail-open working as documented).
- Modem reset (`AT+CFUN=1,1`): `wwan0` cycles, Xray redials on its own, LAN
  traffic resumes without touching a rule. Compare against the 24s recovery
  measured in Phase 1.
- Before blaming Xray for anything, re-run the two probes that isolate the link
  from the config: `: < /dev/tcp/170.205.36.149/443` (a bare connect, `$?` = 0) and
  `curl -k --resolve www.cloudflare.com:443:170.205.36.149 https://www.cloudflare.com/`.
  Both pass today; if they stop passing, the SIM or the server changed, not us.
  Note the connect test is bash's, not `nc`'s: this target's netcat does not bound
  a read with `-w` (see the hardening section), so `nc -w 8 host 443` can sit there
  indefinitely and prove nothing either way.

#### Results, measured on the board after the three fixes above

Everything below was run over the `usb0` gadget link against the deployed image
(slot 1). What is *not* verified is stated at the end, unverified.

- Kernel: all six symbols present in `/proc/config.gz`; `lsmod` shows `xt_TPROXY`
  with `nf_tproxy_ipv4`/`nf_tproxy_ipv6` bound to it.
- `ip rule show` → `32765: from all fwmark 0x1 lookup 100`.
  `ip route show table 100` → `local default dev lo scope host`, one line.
  `ip route show table main` → the two expected defaults (`wwan0` metric 700,
  `usb0` metric 2000) and **no** `local` route. The black-hole hazard that
  motivated the iproute2 dependency does not reproduce.
- `iptables -t mangle -S` matches the designed set exactly: two `PREROUTING -i`
  jumps, seven `RETURN`s, two `TPROXY` rules. Counters after ~10 minutes of
  uptime: `--dst-type LOCAL` 590 packets (that is the SSH session and the DHCP
  traffic being spared), `224.0.0.0/4` 55, `255.255.255.255` 3.
- `xray` listens on `*:12345` (tcp+udp) and `127.0.0.1:5300` (tcp+udp); two
  `ESTAB` sockets from `192.168.43.100` (the modem's address) to
  `170.205.36.149:443`. So REALITY authenticates with the corrected clock.
- DNS goes through the tunnel and does not leak: `nslookup <unique>.wikipedia.org
  192.168.100.1` from a LAN client returned an authoritative NXDOMAIN, while
  `tcpdump -i wwan0 -A 'port 53'` captured **zero** packets across the whole
  exchange. The log shows `accepted udp:1.1.1.1:53 [dns-in >> proxy]`.
- `systemctl stop xray` → `PREROUTING` jumps gone, `XRAY` chain deleted, fwmark
  rule gone, table 100 empty, and the two `MASQUERADE` rules still there, i.e.
  fail-open to direct NAT. `FORWARD` is `-P ACCEPT` with no `XRAYKILL`
  (`XRAY_KILLSWITCH=OFF`, as intended). `systemctl start xray` restores both
  rules and the ip rule.
- The SSH session on `usb0` survived `xraypolicy add`, `xraypolicy del`, a stop,
  a start, and two OTA reboots — which is the whole point of the PREROUTING-only
  shape.
- `conntrack -F` now returns *"connection tracking table has been emptied"*,
  rc 0.
- Clock: `Fri Sep 11 14:36:21 UTC 2026` on a board with no RTC, from
  `AT+QLTS=1`, `modem-time.service` `active (exited)`.
- **The TPROXY forwarding path carries real traffic**, measured with an Android
  phone (`192.168.3.92`) associated to the `wlan0` AP and browsing:
  - `XRAY` rule 8 (tcp) 14090 packets / 1442K, rule 9 (udp) 86 / 107K, so both
    halves of the `dokodemo-door` inbound are exercised. The UDP number is QUIC on
    443, which is also the "a UDP-only application works" check.
  - `PREROUTING -i wlan0 -j XRAY` 14268 / 1559K.
  - The log is all `from 192.168.3.92:… accepted tcp:173.194.26.169:443
    [tproxy >> proxy]` and `accepted udp:74.125.103.70:443 [tproxy >> proxy]`,
    with zero occurrences of failed/rejected/timeout/refused in 200 lines.
  - 142 `ESTAB` sockets to `170.205.36.149:443`, `wwan0` at 29.7 MB in / 3.2 MB
    out.
  - **Nothing leaked around the tunnel**: the `192.168.3.0/24` MASQUERADE rule
    caught 7 packets / 588 bytes in total, and `conntrack -L` shows no flow from
    `192.168.3.92` to any non-RFC1918 address. Every RFC1918 `RETURN` in the
    `XRAY` chain is still at 0, i.e. nothing the phone did needed LAN-to-LAN.

Still uncovered, and what it would take:

- **Modem reset recovery.** `AT+CFUN=1,1` on the modem, then watch `wwan0` cycle:
  Xray should redial on its own and LAN traffic resume without a rule changing,
  since nothing in the rule set names an uplink. Compare against the 24s recovery
  measured in Phase 1. Untested because it means dropping the uplink the board is
  currently serving.
- **The kill switch has never been switched on.** `XRAY_KILLSWITCH=ON`, rebuild,
  and check that `XRAYKILL` appears in `FORWARD` from `netpolicy` at boot (before
  `network.target`, so there is no direct window), that `xraypolicy add` removes
  it, that `systemctl stop xray` puts it back, and that LAN-to-LAN and LAN-to-box
  keep working while the way out is closed. It ships OFF deliberately: this board
  is reached through the LAN the switch would close.
- **A `usb0` client has never used the tunnel.** Only `wlan0` has. The `usb0`
  dnsmasq pushes `dhcp-option=3` (no default gateway) on purpose, so a client
  there needs a route added by hand:
  `ip route add 1.1.1.1 via 192.168.100.1 dev <iface>` then
  `curl https://1.1.1.1/cdn-cgi/trace` (`ip=` should be the server's address,
  `loc=SG`). The rule set is per-interface and symmetric, so this is a
  configuration question about `dhcp-option=3`, not a doubt about the mechanism.
- **The `expandfs` `resize_inode` recovery path** still has not run on real
  hardware. Unrelated to Phase 5, carried forward from Phase 0.

### The server side, as far as it is known

The endpoint comes from `/home/denisov/vpn/laptop-singapore/singbox-reality.txt`
(readable by the build user since the ACL was granted). No credential is
reproduced here — this document is in git:

| | |
|---|---|
| protocol | VLESS + REALITY, `flow=xtls-rprx-vision`, `encryption=none` |
| transport | plain TCP (`type=tcp`) — no WS/gRPC/xhttp layer to configure |
| port | 443, **reachable from the board over cellular** (measured above) |
| front | `sni=www.cloudflare.com`, and the server really does relay to it (`HTTP 200`) |
| uTLS | `fp=chrome` → `realitySettings.fingerprint` |
| identity | one UUID per client, issued server-side; the board is just another client |

The same host also offers OpenVPN on 1194/udp (`camradeling_laptop.txt`, full
inline CA/cert/key/tls-crypt), shadowsocks on 8388 and WireGuard on 51820/udp.
Useful as fallbacks and as a cross-check, but REALITY on 443 is the one measured
to work from this SIM, and it is the only one of the four that needs no kernel
module and no interface. WireGuard would be the natural alternative — `AllowedIPs
= 0.0.0.0/0` in that profile also confirms the server is an **exit node**, not a
site-to-site peer, which is what the plan assumes: the RFC1918 `RETURN`s stay, and
`netpolicy`'s `MASQUERADE` set is unaffected.

Still unread: `/home/denisov/progs/vpnsetup` (`claudev:claudev`, mode 770, ACL for
`claudev` and `denisov` only), which is the server implementation itself. Nothing
in Phase 5 blocks on it now; it would only tell us how UUIDs are provisioned and
whether the REALITY inbound enables any of the newer options (post-quantum key
exchange, ML-DSA auth) — which is the one thing that would force the current Xray
build (package option A) over an older tag. `setfacl -R -m u:claudea:rX -m
d:u:claudea:rX /home/denisov/progs/vpnsetup` unblocks it if that comes up.

### As built — where the implementation differs from the plan above

Steps 1–7 are implemented and running on the board with `XRAY_CLIENT=ON`; step 8
(kill switch) is wired but shipped off. Everything the plan specifies is in place;
the list below is only the places where the shape changed while writing it, and
why. What the first boot with `XRAY_CLIENT=ON` actually broke is in
"Field findings: first boot with the tunnel on" below.

- **The Xray package is the prebuilt v26.3.27 release** (option A, as
  recommended): `package/xray/` with `XRAY_SOURCE = Xray-linux-arm64-v8a.zip`,
  `generic-package`, a custom `EXTRACT_CMDS` (`$(UNZIP)`) and an
  `INSTALL_TARGET_CMDS` that installs only `xray` to `/usr/bin/xray` — the
  30 MB of `geoip.dat`/`geosite.dat` in the archive stay out of the image. The
  hash in `xray.hash` is upstream's own `.dgst` value, verified against the
  downloaded file. The binary is static and already stripped. `Config.in`
  `depends on BR2_aarch64`, since the asset is aarch64.
  Caveat worth knowing before a version bump: upstream's asset name carries no
  version and Buildroot names the download after the URL's basename, so
  `dl/xray/Xray-linux-arm64-v8a.zip` is the same path for every version. Bumping
  `XRAY_VERSION` fails the hash check until that file is removed. This is
  written in the `.mk`.
- **`ca-certificates` was not added.** REALITY authenticates the server by `pbk`,
  so nothing in this path needs a CA store, and `/etc/ssl/certs` being empty is
  not a Phase 5 problem.
- **The AT machinery is now a sourced library**,
  `/usr/libexec/quectel/quectel_at.inc`: `find_modem`, `list_ports`, `at_cmd`,
  plus a new `find_at_port` and `with_modem_lock`. `quectel_ecm.sh` lost its
  copies and gained a `source`, `modem-time` uses the same ones. Two scripts
  talking to the same serial port with two copies of the port-discovery loop was
  the alternative.
- **`modem-time.service` has no `Before=xray.service`**, against the table in
  "Files, and who owns each one". It is `WantedBy=` the `wwan0` device unit (the
  level-triggered shape `quectel-ecm-up.service` established), so it is usually
  not in the boot transaction at all: the ordering would apply only sometimes,
  and when it did apply it could hold `xray.service` for the modem-time timeout.
  Xray does not need a correct clock to *start* — it fails handshakes until the
  clock jumps and then works, with no restart — so a sometimes-ordering buys
  nothing and costs a nondeterministic boot delay. The unit says this too.
- **`modem-time` asks for GMT (`AT+QLTS=1`) and refuses implausible clocks.** The
  floor is the script's own mtime less a day (written at build time, so no correct
  time can predate it, and it needs no maintenance), the ceiling is ten years
  later. It polls for up to 120s because the modem answers with garbage until it
  has seen NITZ, dropping the modem lock between attempts so a plug-in mode switch
  is never blocked by it. `AT+CCLK?` is only a fallback, and is taken as UTC — see
  the field findings below for the measurement that forced that.
- **The kill switch is a chain, not one rule.** The plan's
  `-I FORWARD -i usb0 ! -o usb0 -j REJECT` would also kill LAN-to-LAN traffic,
  which the `XRAY` chain's RFC1918 `RETURN`s deliberately keep working. Instead
  `xraypolicy` owns an `XRAYKILL` chain that `RETURN`s for every
  `XRAY_LAN_IFACES` member and rejects the rest, hooked from `FORWARD` per LAN
  interface. `netpolicy` calls `xraypolicy boot` at the end of its run — before
  `network.target`, so there is no direct window between boot and Xray being up, and
  so `/run/xray-dns.conf` exists before `dnsmasq` reads it — and the kill switch
  half is a no-op unless both `XRAY_KILLSWITCH=ON` and `XRAY_CLIENT=ON` (a kill
  switch with no Xray to wait for is just a broken LAN). `xraypolicy add` removes
  it, `del` re-adds it.
- **`/etc/system.vars` carries seven keys, not one**: `XRAY_CLIENT`,
  `XRAY_TPROXY_PORT`, `XRAY_DNS_ADDR`, `XRAY_DNS_UPSTREAM`, `XRAY_PROBE_PORT`,
  `XRAY_LAN_IFACES`, `XRAY_KILLSWITCH`. `xraypolicy` and `xray-health` need the rest
  at runtime, and taking them from the same file `0013` writes is what stops the rule
  set, the resolv-file and the generated `config.json` from disagreeing about a port
  or an address. `XRAY_CONFIG` still never leaves the build host, and no credential
  is written anywhere but `/etc/xray/config.json`.
- **`0013` renders `config.json` from a heredoc**, not by `sed`-substituting a
  template: same output, one file fewer. It also validates every extracted field
  against `^[A-Za-z0-9._:@%~/+-]+$` before it goes into JSON, rejects a share URL
  whose `security`/`type` is not `reality`/`tcp` (the skeleton cannot express
  anything else), and installs a full xray `config.json` verbatim if that is what
  `XRAY_CONFIG` points at — in which case it asserts that the file has inbounds on
  `XRAY_TPROXY_PORT`, on `XRAY_DNS_ADDR` and on `XRAY_PROBE_PORT`, so `xraypolicy`
  cannot end up TPROXY'ing the LAN into nothing, `dnsmasq` cannot be pointed at a
  resolver that does not exist, and `xray-health` cannot restart Xray forever over a
  probe that never had anywhere to go. The dnsmasq lines (`resolv-file=`, and the
  older `server=`/`no-resolv` pair) are stripped unconditionally at the top and
  re-added only when `ON`.
- **`xraypolicy` checks `ip -V` at runtime** on top of the build-time assertion.
  The failure it guards against is the one already measured on this board — a
  busybox `ip` silently dropping `table 100` and installing a black-hole default
  route in `main` — and the cost of the check is one process.
- **`30-xray.conf` sets `default.rp_filter=2` as well as `all`**, so an interface
  that appears later cannot inherit a strict value.
- **Rule G, as specified, plus one more in rule F**: `modem-time.service` must be
  linked into `sys-subsystem-net-devices-wwan0.device.wants` when
  `QUECTEL_ECM=ON`, for the same reason `quectel-ecm-up.service` is checked there
  — without the link the board runs two years in the past and nothing says so.
  The new `QUECTEL_ECM` artifacts (`quectel_at.inc`, `modem-time`,
  `modem-time.service`) are in that feature's artifact list, so an `OFF` build
  that still ships them fails.
- `xray run -c <file>`, not `-config`: `{{.Exec}} run [-c config.json] [-confdir
  dir]` is the usage string in the binary.

### Field findings: first boot with the tunnel on

The `XRAY_CLIENT=ON` image built clean, passed every build-time assertion, and
then did not work at all on the board. Three separate defects, none of which any
amount of offline checking would have found. All three are fixed; they are written
down because each one is a class of mistake this design invites again.

#### 1. `XRAY_DNS_PORT=5353` collides with `systemd-resolved` (fixed)

`xray` never started:

```
Failed to start: listen udp 127.0.0.1:5353: bind: address already in use
xray.service: Scheduled restart job, restart counter is at 13.
```

5353 is the mDNS port, and `systemd-resolved` — enabled in this image, and the
owner of `127.0.0.53:53` — binds `0.0.0.0:5353` for its mDNS stub. A wildcard bind
there is a conflict for `127.0.0.1:5353`, and `xray` treats a failed inbound bind
as fatal, so the unit restart-looped forever. The LAN had no uplink because of a
port number, and the plan's own DNS section had picked 5353 precisely because it
looks like a spare DNS port.

The immediate fix was to default the port to 5300 and **fail the build** on 5353,
naming the reason. The hardening pass then removed the port entirely: the DNS
inbound now listens on `XRAY_DNS_ADDR:53` (default `127.0.0.2`) because `dnsmasq`
reaches it through a resolv-file, and the build refuses `127.0.0.53`/`127.0.0.54`
(systemd-resolved's) and any address outside `127/8`. Same lesson, wider guard.
`ss -lntup` on the target is the way to check the next one; the build cannot see the
running system, so guards on the known collisions are all there is.

#### 2. `conntrack -F` segfaults: the kernel had no netfilter netlink (fixed)

Every `xraypolicy add`/`del` logged:

```
xraypolicy: line 179: 1656 Segmentation fault (core dumped) conntrack -F
```

`conntrack -V` alone reproduced it: `mnl_socket_open: Protocol not supported`,
then a crash. `CONFIG_NF_CT_NETLINK` was `is not set` in `linux_zero3.config`, so
there is no `NETLINK_NETFILTER` socket for conntrack-tools to open — and 1.4.7
does not exit cleanly when the open fails. With `xray` restart-looping this dumped
four cores per cycle.

`CONFIG_NF_CT_NETLINK=m` and `CONFIG_NETFILTER_NETLINK=m` are now in the kernel
config, so the flush actually happens — without it, LAN clients would have kept
their pre-tunnel flows until the connections ended, which is the behaviour the
call exists to prevent. `xraypolicy` also wraps it in `flush_conntrack`, which
logs a warning instead of crashing on a kernel built without the option. Note the
`sh -c 'conntrack -F; exit $?'` in that function: the "Segmentation fault"
notice comes from the *parent* shell, so redirecting the command's own stderr does
not suppress it, and a single command would be `exec`'d rather than forked.

#### 3. This modem keeps UTC in `AT+CCLK?` (fixed)

`modem-time` rejected a correct reading and failed after its 180s timeout:

```
attempt 3/12: modem reports 2026-09-11 14:19:15 +32, outside the plausible window
```

Measured on the EC25 against a known-good UTC clock (real UTC was `14:22:2x`):

| command | reply |
|---|---|
| `AT+CCLK?` | `+CCLK: "26/09/11,14:22:23+32"` |
| `AT+QLTS=1` | `+QLTS: "2026/09/11,14:22:25+32,0"` |
| `AT+QLTS=2` | `+QLTS: "2026/09/11,22:22:28+32,0"` |

So `CCLK` holds **UTC** and reports `+32` (UTC+8) as nothing more than the zone
the network told it about, while the AT spec says `CCLK` is local time. Subtracting
the offset — the spec-correct thing, which is what the first implementation did —
produced a clock 8 hours behind. The plausibility window caught it, which is the
one part of this that worked as designed: an 8-hour error would have failed every
REALITY handshake with nothing in the log but timeouts.

`AT+QLTS=1` is the only one of the three that says which zone it means, so it is
now the primary source and no offset arithmetic is done at all. `AT+CCLK?` remains
a fallback for firmware without `QLTS`, taken as UTC. The floor also gained a day
of slack, because a bound tight enough to reject a correct clock is a worse bug
than the pre-NITZ garbage it exists to reject (`+CCLK: "04/01/01,..."` is still
rejected — it is 22 years low).

## Hardening: what happens when Xray dies, or stops working without dying

Asked of the working image, answered by reading the units and `systemctl show`
rather than by guessing. Four gaps, three fixes, all three implemented and measured
on the board (slot 2) — and then a fourth fix, because the third of them shipped
with a bug that made it worse than nothing on the first real outage it met. That
one has its own section below; it is the more useful half of this story.

### The four failure modes, as they were

| Failure | Before | Why |
|---|---|---|
| process killed / crashes | recovers in ~5s, LAN direct in the meantime | `ExecStopPost=xraypolicy del` runs on every exit path, `Restart=` brings it back |
| process exits **0** | never comes back | `Restart=on-failure` does not cover a clean exit, and Xray exits 0 on some fatal conditions |
| uplink lost / modem cycles | self-healing, nothing to do | Xray dials per connection; no rule names an uplink |
| **process alive, tunnel dead** | **undetected, forever** | `WatchdogUSec=0`, no health check, no `routing` block; a blackholed LAN while a working direct path sits next to it |
| DNS, whenever the tunnel is down | **failed closed** | `no-resolv` + a single `server=127.0.0.1#5300`: traffic failed open onto a path that could not resolve a name |

The last two are the interesting ones. A restart loop on a permanently broken Xray
also flaps forever rather than giving up — `RestartSec=5s` against
`StartLimitBurst=5`/`StartLimitIntervalUSec=10s` never trips the limit, and the
restart counter was observed at 13 during the 5353 episode. That is the right
behaviour here (each attempt runs the whole `del`/`add` cycle, so it either recovers
or fails open) but it is worth knowing it is unbounded.

### 1. `Restart=always`

One line. `on-failure` leaves a clean-exit death dead forever, and "the proxy
stopped" is a LAN with no uplink whatever the exit code was.

### 2. DNS follows the routing

`resolv-file=/run/xray-dns.conf` + `xraypolicy` writing it — the design is in the
DNS section above. The point of the change: "fail open" now means open for names as
well as for packets.

### 3. `xray-health`, a probe *through* the tunnel

`config.json` gained a third `dokodemo-door` inbound, `127.0.0.1:5301` with a fixed
destination of `1.1.1.1:80`, and `/usr/sbin/xray-health` runs once a minute from
`xray-health.timer`:

```sh
exec 3<>/dev/tcp/${host}/${port}                 # bash, not nc - see below
printf 'HEAD / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' ${host} >&3
IFS= read -t 5 -r line <&3                       # rc 0 = a line, 1 = EOF, 142 = timeout
case "${line}" in HTTP/1.[01]\ *) : ;; esac      # only rc 0 with this can be a live path
```

A bare connect on that port proves nothing — Xray accepts the local socket before
it dials anything — so the probe has to be a request with a reply, and one HTTP
`HEAD` exercises the inbound, the outbound, the REALITY handshake, the server and
its exit. Cloudflare answers `:80` with a 301, which is proof enough. `HTTP/1.0`
with `Connection: close`, so the far end hangs up and the read cannot block on a
connection nobody will say anything more on.

**Why bash and not `nc`, which is what this first shipped as.** The target has no
`timeout(1)`, and GNU netcat 0.7.1's `-w` bounds the *connect*, not the *read* —
measured on the live board with the tunnel's egress blackholed: `printf ... | nc -w
5 127.0.0.1 5301` was still running after 25 s with zero bytes read. See the
outage below; `read -t 5` returns 142 in exactly five seconds on the same
connection. Rule G therefore asserts on `/bin/bash` and on the `/dev/tcp/*/*`
literal inside it, since network redirections are a build-time bash option
(`--enable-net-redirections`) whose absence is invisible until the probe can never
succeed and the box restarts Xray forever. `BR2_PACKAGE_NETCAT=y` stays in the
defconfig — nothing in the image depends on it now, but it is worth having by hand
on a board with no `telnet`; just do not build a timeout out of it.

It is a reconciler, not a one-shot, with its state in `/run/xray-health/`:

- **preconditions** — `XRAY_CLIENT=ON` and `xray.service` active. Nothing else:
  "is the uplink up" is asked by probing, not by looking at the routing table. The
  original check here was "does a default route exist", which is worthless on this
  board — `usb0` carries a static default at metric 2000, so one always exists,
  carrier or no carrier. It is replaced by a second probe, `1.1.1.1:80` **direct**,
  run only on a tick whose tunnel probe already failed: if the direct path is dead
  too, the counter is reset and the tick logs "the uplink is down, so this is not
  the tunnel's fault". That is the honest form of the question, and it costs one
  `HEAD` on a tick that was already going to report a failure.
- 3 consecutive failures (≈3 min) → **restart `xray.service`**, at most once per
  `COOLDOWN` (300s), because a restart drops every live connection through the
  tunnel.
- still failing after that restart → **`xraypolicy del`**: the TPROXY rules come
  out and the LAN uses the direct path that demonstrably works. With
  `XRAY_KILLSWITCH=ON` the same call closes the LAN instead, which is the same
  promise kept the other way.
- probe answers again → **`xraypolicy add`**, and the LAN goes back on the tunnel.
- while it is down, a restart is retried every `COOLDOWN`; if the state is already
  `down` the rules are taken out again immediately after the restart, so a
  server that is unreachable for an hour does not blackhole the LAN for three
  minutes out of every five.

Thresholds are script constants overridable from the environment
(`XRAY_HEALTH_FAILS`, `XRAY_HEALTH_COOLDOWN`); they are deliberately *not*
`/etc/system.vars` keys, because nothing else needs to agree with them. A successful
probe logs nothing — a per-minute timer that logs is a journal that nobody reads.

### The health check became the outage (fixed)

Found while diagnosing field finding 5 above, in code written the day before, on
the same board. From 16:28:00 to 16:35:01 the journal has one line per minute and
it is always the same one:

```
systemd[1]: xray-health.service: start operation timed out. Terminating.
systemd[1]: xray-health.service: Failed with result 'timeout'.
```

Zero `xray-health` lines. The tunnel was genuinely dead (the modem's data call was
unbound, so nothing reached the carrier), the LAN was blackholed, and the one thing
that existed to notice that was being killed at `TimeoutStartSec=60` every single
tick — because `nc -w 5` does not bound a read, so the probe hung and the counter
in `/run/xray-health/fails` never advanced past its initial value. The escalation
was never reached, not once in seven minutes.

Reproduced deterministically afterwards with
`iptables -I OUTPUT -o wwan0 -p tcp -j DROP`: the `nc` was still running after 25 s
having read nothing. Three changes came out of it, and the second two matter more
than the first:

1. the probe is bash's `/dev/tcp` + `read -t` (above), which is bounded by
   construction;
2. **the failure is recorded before the probe runs**, so a process that does not
   survive its own probe still counted;
3. **escalation is driven from the state file, before this tick probes anything.**
   A probe that wedges anyway — a blocking connect, a signal, an OOM kill — must
   not be able to stall the escalation forever, which is exactly what happened.
   The recorded state is the input; this tick's measurement only updates it.

`TimeoutStartSec=60` stays as the backstop it should always have been, not as the
thing standing between a dead tunnel and the LAN.

### Measured on the board

Deployed to slot 2, then re-measured end to end after the probe rewrite. The first
round faked the tunnel dead with
`iptables -I OUTPUT -d <server> -p tcp --dport 443 -j REJECT`, which leaves the
process healthy and every connection through it broken — exactly the mode nothing
used to notice.

The rewrite was validated against the sharper case, twice, with the timer running
at its real 60 s and its real thresholds: `-o wwan0 -p tcp --dport 443 -j DROP`, so
the tunnel is dead *and the direct `:80` probe still answers* — a dead server
behind a live carrier, which is the only shape in which escalating is correct. The
full ladder ran, one tick per minute, each tick finishing in 5–6 s:

```
xray-health: no HTTP reply through the tunnel, the direct path answers (1/3)
xray-health: no HTTP reply through the tunnel, the direct path answers (2/3)
xray-health: no HTTP reply through the tunnel after 3 probes, restarting xray.service
xraypolicy:  LAN DNS upstream: 1.1.1.1          <- ExecStopPost
xraypolicy:  TPROXY policy removed
xraypolicy:  LAN DNS upstream: 127.0.0.2        <- ExecStartPost, 1s later
xraypolicy:  LAN (usb0 wlan0) is TPROXY'd to 127.0.0.1:12345 via fwmark 0x1/table 100
xray-health: no HTTP reply through the tunnel, the direct path answers (1/3)
xray-health: no HTTP reply through the tunnel, the direct path answers (2/3)
xray-health: the tunnel is still dead after a restart, taking the TPROXY rules out so the LAN uses the direct path
xraypolicy:  LAN DNS upstream: 1.1.1.1
xraypolicy:  TPROXY policy removed
xray-health: the tunnel answers again after 3 failed probes, putting the LAN back on it
xraypolicy:  LAN DNS upstream: 127.0.0.2
xraypolicy:  LAN (usb0 wlan0) is TPROXY'd to 127.0.0.1:12345 via fwmark 0x1/table 100
```

Counted rather than eyeballed: `mangle PREROUTING` TPROXY jumps 2 → 0 across the
fall-open and back to 2 on recovery, `state` = `down` then `up`, `fails` = 0 at the
end. With the block left on and the direct path killed too
(`-o wwan0 -p tcp -j DROP`), the same tick instead logs *"the uplink is down, so
this is not the tunnel's fault"* and resets the counter — no restart, no repathing.

One wart the escalate-before-probe order created and how it is handled: on the tick
where the block is lifted, escalation runs first with nothing left to do, so it
would have logged "the tunnel is still dead" one second before "the tunnel answers
again". `escalate()` now sets an `ACTED` flag and its no-op branch is silent; the
caller emits the "still dead" line only when it has a failed probe of its own to
say it about. Re-verified live.

- After the escalation: `mangle PREROUTING` empty, no `fwmark` rule, `/run/xray-dns.conf`
  = `nameserver 1.1.1.1` — and `nslookup debian.org 192.168.100.1` from a LAN client
  answered. That is the fix for the old DNS behaviour, verified with a name that had
  never been cached.
- After the block was removed and one more probe ran: rules back, fwmark rule back,
  `nameserver 127.0.0.2`, state `up`.
- Steady state: `xray` listens on `*:12345`, `127.0.0.2:53` and `127.0.0.1:5301`;
  the probe returns `HTTP/1.1 301 Moved Permanently`; `xray-health.service`
  `Result=success`, `/run/xray-health/fails` = 0; `xray-health.timer` next elapse
  60s out with `AccuracySec=5s`.
- DNS through the tunnel, re-verified after the move to `127.0.0.2:53`: three
  `nslookup`s from a LAN client all answered while `tcpdump -ni wwan0 'port 53'`
  captured **zero** packets.
- `Restart=always` in effect: `kill -9 $(pidof xray)` → within 2s the rules were out
  and the resolv-file said `1.1.1.1`; 8s later `active`, `NRestarts=1`, rules back,
  `nameserver 127.0.0.2`, probe answering. No cores, and `journalctl -b | grep -c
  'segfault\|core dumped'` = 0.
- `after-preset-check` passed with the three new assertions, and `preset-all` created
  `timers.target.wants/xray-health.timer` as designed.

Not covered by this: a `dnsmasq` that dies (its own `Restart=` handles that), and the
kill-switch interaction — with `XRAY_KILLSWITCH=ON`, `xray-health`'s escalation
closes the LAN instead of opening it, which is intended but has never been run on
hardware because the switch has never been on.

## Verification

Per phase, on target:

- `ip route show default` — exactly the expected metrics, one line per live uplink.
- `iptables -t nat -S POSTROUTING` — one `MASQUERADE` per uplink, present before
  any interface comes up, unchanged across `systemctl restart hostapd`.
- Unplug/replug the modem: `wwan0` config disappears and returns, no stale
  `ifstate`, no duplicate dhclient.
- Boot with no modem: no 20s stall — compare `systemd-analyze blame` for
  `rc-local.service` before/after Phase 1.
- AP client traffic reaches the internet with only `wwan0` up (proves the NAT set
  is uplink-agnostic).
- With `VPN_CLIENT=ON` and a config without `route-nopull`: `0.0.0.0/1` +
  `128.0.0.0/1` present, AP clients egress the tunnel.

Phase 4, verified on a real `./build.sh testbot4` (vars: `WIFI_AP=ON`,
`WIFI_CLIENT=OFF`, `USB_RNDIS=ON`, `QUECTEL_ECM=ON`, `VPN_CLIENT=OFF`):

- `after-preset-check.sh` ran inside the fakeroot and passed.
- In `rootfs.ext2`: `wpa_supplicant_wlan1.conf` **gone**; `openvpn@client.service`
  and `openvpn@server.service` **gone** from both `/etc/systemd/system` and
  `multi-user.target.wants`, replaced by the untouched `openvpn@.service`
  template; `hostapd.conf` / `dnsmasq_wlan0.conf` / `dnsmasq_usb0.conf` present;
  all six gated units carry their `ConditionPathExists=`; `system.vars` carries
  `VPN_CLIENT=OFF`.
- The assertion pass was exercised against synthetic trees for: the current
  WIFI_CLIENT=OFF-but-config-present bug (caught), an ungated new unit (caught),
  a stale enabled `openvpn@server.service` (caught), `VPN_CLIENT=ON` with no link
  (caught), a typo'd `ConditionPathExists` (caught), and the correct
  `VPN_CLIENT=ON` layout (passes).

Note: the real client config (`/home/denisov/vpn/officehub.conf`) is not readable
by the build user in the current session, so the VPN leg cannot be built or
tested from here.
