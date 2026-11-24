# 005 — Direct hosts: AP clients that bypass every tunnel

Status: **implemented, not yet built or tested on the board** (2026-11-15).
`0010` was dry-run against a scratch target: valid lists produce the dhcp-host
and dns-server lines, and malformed, out-of-subnet, AP-address and duplicate
entries fail the build.

## Goal

Some devices on the testbot4 AP (wlan0) should use the board as a plain NAT
router: no xray TPROXY, no tunnelled DNS, no icmpvpn, no WireGuard, and no kill
switch. Each one is identified by MAC, always gets the same address, and
everything from that address goes out the main table (wwan0 today) with the
same MASQUERADE as the rest of the LAN.

## Configuration

One new variable in the vars file, plus an optional DNS override:

```bash
################ direct (untunnelled) AP clients ######################
# "<mac>,<ip> ..." - each device gets <ip> from dnsmasq, and everything
# it sends goes straight out the uplink: no xray, no tunnelled DNS, no icmpvpn,
# no WireGuard, and the kill switch does not apply to it. The bypass needs both
# the MAC and the IP to match, so another client that sets the same IP by hand
# is still tunnelled. Turn off MAC randomisation ("private address") for this
# SSID on the device, or it will not match.
export WIFI_AP_DIRECT_HOSTS=""
# DNS server handed to direct hosts by DHCP and reached directly. Note that the
# carrier forges plain DNS answers; this is the device's own uplink.
export WIFI_AP_DIRECT_DNS=1.1.1.1
```

`WIFI_AP_DIRECT_HOSTS` uses the same `<mac>,<ip>` format as the existing
`WIFI_AP_DHCP_HOSTS`, so a device is listed in one of the two, never both.

## Where each tunnel picks up traffic, and how a direct host avoids it

| Mechanism | Where it hooks | How the bypass avoids it |
|---|---|---|
| xray TPROXY | `mangle PREROUTING -i wlan0 -j XRAY` (appended by `xraypolicy add`) | A `DIRECT` chain sits **first** in mangle PREROUTING: it marks the packet `0x10/0x10` and `ACCEPT`s, so the packet never reaches `XRAY` |
| Tunnelled LAN DNS | dnsmasq → `/run/xray-dns.conf` → xray dns-in | DHCP gives the device `WIFI_AP_DIRECT_DNS` instead of the AP address (`dhcp-option=tag:direct,...`), and the queries go out direct because of the mark |
| icmpvpn | `ip rule pref 8990 iif wlan0 ipproto icmp lookup 2030` | `ip rule pref 5100 fwmark 0x10/0x10 lookup main`, ahead of every other rule |
| WireGuard LAN route | `ip rule pref 5200/5220 iif wlan0 ...` | the same pref 5100 rule (it comes first) |
| Kill switch | `filter FORWARD -i wlan0 -j XRAYKILL` | `XRAYKILL` begins with `-m mark --mark 0x10/0x10 -j RETURN` |
| Board tunnel (9000–9040) | `iif lo` only | not affected: forwarded traffic never matches |
| NAT | netpolicy `-s <ap subnet> ! -o wlan0 -j MASQUERADE` | already covers it, nothing to add |

Return traffic needs nothing extra. It comes in on wwan0 and conntrack
de-NATs it; pref 8990/5220 match only `iif wlan0` and the TPROXY rules only
`-i <lan>`, so main delivers it to wlan0.

Why a mark rather than `from <ip>` rules: one key (MAC+IP, checked once in
PREROUTING) serves the mangle, routing and filter layers. Without it every
layer would need its own match, and routing cannot match MAC at all.
`0x10/0x10` does not collide with TPROXY's `0x1`: rule `fwmark 0x1 lookup 100`
compares the full mark, and marked packets never reach TPROXY anyway.

## Runtime rules (all keyed on `-i wlan0`, installed once at boot)

```sh
# mangle: identify, mark, skip the rest of PREROUTING (i.e. XRAY)
iptables -t mangle -N DIRECT
iptables -t mangle -A DIRECT -s 192.168.3.50 -m mac --mac-source aa:bb:cc:dd:ee:ff \
         -j MARK --set-xmark 0x10/0x10
iptables -t mangle -A DIRECT -m mark --mark 0x10/0x10 -j ACCEPT
iptables -t mangle -I PREROUTING 1 -i wlan0 -j DIRECT

# routing: marked packets use the main table, ahead of wg (5200) and icmpvpn (8990)
ip rule add pref 5100 fwmark 0x10/0x10 lookup main
```

The kill switch exemption is added in `xraypolicy killswitch_add`, as the
first rule of `XRAYKILL`, because that function flushes and rebuilds the chain:

```sh
iptables -A XRAYKILL -m mark --mark 0x10/0x10 -j RETURN
```

Ordering: `hook_chain` in xraypolicy **appends** to PREROUTING and netpolicy
**inserts** at position 1 before xray starts, so DIRECT stays ahead of XRAY.
xraypolicy, wgpolicy and icmpvpn each delete only their own prefs (9000–9040,
5200–5230, 8990/8995), so pref 5100 survives their add/del cycles. The rules do
nothing until the device associates, the same as the rest of netpolicy.

## Changes

1. **`board/customized/orangepi/linux_zero3.config`**: `CONFIG_NETFILTER_XT_MATCH_MAC=m`.
   It is off in the current testbot4 kernel. `CONFIG_NETFILTER_XT_MARK=m`
   is already on and provides both the MARK target and the mark match. Check
   that the iptables package ships `libxt_mac.so` (it builds every extension by
   default).
2. **`createfs-scripts/0010-wifi_ap_service.sh`**: for each entry:
   - check the format, using the same regex as `WIFI_AP_DHCP_HOSTS`. Also check
     that the IP is inside `WIFI_AP_ADDR/WIFI_AP_NETMASK`, is not the AP address
     itself, and is listed in neither `WIFI_AP_DHCP_HOSTS` nor twice in this list;
   - write `dhcp-host=<mac>,set:direct,<ip>`;
   - once, if the list is non-empty: `dhcp-option=tag:direct,option:dns-server,${WIFI_AP_DIRECT_DNS:-1.1.1.1}`;
   - write `WIFI_AP_DIRECT_HOSTS` into `system.vars` with the same `sed`
     pattern as the other WIFI_AP vars. An empty value is written when the
     feature is unused, so a stale list cannot stay on the target.
3. **`overlays/filesystems/system_v2/etc/system.vars`**: add
   `export WIFI_AP_DIRECT_HOSTS=""`.
4. **`overlays/services/netpolicy/usr/sbin/netpolicy`**: new `direct_hosts()`
   that installs the mangle chain, the PREROUTING jump and the pref 5100 rule
   above, idempotently (`-N` then `-F`, `-C` before `-I`, delete pref 5100
   until none is left before adding). It runs before the `xraypolicy boot` call,
   so that `killswitch_add` already has marked traffic to exempt, and it needs
   iproute2 (the same `require_iproute2` check as xraypolicy).
5. **`overlays/services/xray/usr/sbin/xraypolicy`**: in `killswitch_add`, the
   mark RETURN as the first rule of `XRAYKILL`. The rule is harmless when the
   list is empty.
6. **`after-preset-check.sh`**: when `WIFI_AP_DIRECT_HOSTS` is set, assert that
   `dnsmasq_wlan0.conf` has a `set:direct` dhcp-host line for every entry and
   the `tag:direct` dns-server option. When it is empty, assert that it has
   neither.
7. **Templates**: add the block above to `orangepi4-test.vars.template` (and
   to the other templates with `WIFI_AP`, empty by default). Put the real MAC
   only in the untracked `.vars`.
8. **`tools/testbot-diag.sh`** (optional): in the xray section, for each
   direct host, run
   `ip route get 1.1.1.1 from <ip> iif wlan0 mark 0x10` and expect `dev wwan0`
   (the uplink). Also check that the DIRECT jump is rule 1 of mangle
   PREROUTING.

No new unit, so `preset-all` and `ALWAYS_ON` do not change.

## Behaviour and caveats

- **Fixed IP**: dnsmasq reserves `<ip>` for that MAC. An address inside the
  dynamic range is fine, because dnsmasq never leases a reserved address to
  anyone else. With `WIFI_AP_STICKY_LEASES=ON` the reservation still wins.
- **DNS is direct on purpose**: plain UDP/53 on the carrier, which forges
  answers for some names. A device that does its own DoH/DoT is unaffected. If
  plain DNS turns out to be unusable, the fallback is to leave the device on
  dnsmasq and accept tunnelled DNS (drop the `dhcp-option` line).
- **ICMP to Google ranges** gets the carrier's treatment (dropped), as that is
  the point of bypassing icmpvpn.
- **Conntrack**: rules are installed at boot, before any client, so no flow
  needs flushing. If the list ever becomes runtime-editable, flush the
  device's flows (`conntrack -D -s <ip>`) after changing it.
- **Spoofing**: someone on the AP who clones both the MAC and the IP gets the
  bypass. The AP is WPA2-PSK, so that is someone who already has the PSK.
- **Scope**: wlan0 only, as asked. Extending it to usb0 means one more
  `-i usb0 -j DIRECT` jump and a dnsmasq_usb0 counterpart. Nothing else in the
  design depends on the interface.

## Test plan (on testbot4)

1. Build, flash/OTA, then associate the device (private MAC off).
2. `cat /media/data/dnsmasq_wlan0.leases` (or `/var/lib/misc/...`) shows the
   device on its fixed IP; on the device, DNS server = `WIFI_AP_DIRECT_DNS`.
3. `iptables -t mangle -L PREROUTING -v -n --line-numbers`: DIRECT is line 1
   and its counters grow while the device is busy; the XRAY counters do not grow
   for its traffic.
4. `ip rule | head`: pref 5100 is present. Then run `icmpvpn on` and
   `xraypolicy del`/`add` and check the rule is still there.
5. On the device: `curl ifconfig.me` shows the **carrier's** IP, while a
   tunnelled client shows the exit server's IP. Ping to a Google range fails;
   ping to 1.1.1.1 works.
6. With `XRAY_KILLSWITCH=ON` and `systemctl stop xray`: the direct host still
   reaches the internet and other clients get REJECT.
