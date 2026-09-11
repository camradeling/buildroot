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
| 5 | *Optional, later:* reachability-based failover watcher; non-OpenVPN protocols | new |

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
while chasing "wwan0 is up but no internet". Four separate defects, in the order
they were found. The first three are fixed; the fourth is the case for Phase 1.

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
  metric`, `ip rule` and named tables do work (already used in `usbstart.sh` and
  `rc.local`).
- Sizing: ~50-line probe loop, `Restart=always` unit or a timer, plus optionally
  `conntrack -F` on uplink change (`conntrack-tools` is already in the image).
- On uplink failover an active OpenVPN tunnel dies until it reconnects, because
  the host route to the server via the old gateway goes stale. OpenVPN recovers
  on its own via keepalive/ping-restart; tuning that is part of Phase 5, not
  earlier.

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
