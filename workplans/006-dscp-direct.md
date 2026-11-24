# 006 — DSCP direct hosts: one process on a client bypasses the tunnels

Status: **implemented and running on testbot4** (2026-11-20). Board side checked
(DIRECT rules, xt_dscp, rule 5100); a laptop process run through the script
gets a direct MQTT connection to the Bambu cloud out wwan0 while the rest of the
laptop stays tunnelled. The `curl ifconfig.me` comparison is still to do.

Extends 005 (direct hosts). There, a client is either fully tunnelled or fully
direct. Here, a client stays tunnelled except for the traffic of chosen
processes, which the client itself marks with a DSCP value.

## Why DSCP

The board cannot see processes. The only thing it can match is the packet, so
the client has to tag the traffic. DSCP sits in the IP header, the client can
set it per socket, and it survives the hop over Wi-Fi. It needs no tunnel, no
second address and no change to the application.

## Configuration (vars file)

The existing list gets an optional third field:

```bash
# "<mac>,<ip>"         fully direct (005)
# "<mac>,<ip>,<dscp>"  tunnelled, except packets carrying DSCP <dscp> (1..63)
export WIFI_AP_DIRECT_HOSTS="e4:1f:d5:28:20:03,192.168.3.13,7"
```

DSCP 0 is rejected because every unmarked packet carries it. A MAC or IP may
appear only once across `WIFI_AP_DIRECT_HOSTS` and `WIFI_AP_DHCP_HOSTS`.

Picking the value: **7** (TOS 0x1c). The value must be one that no program sets
by itself, because every packet carrying it from that host bypasses the
tunnel. The first default, 4, failed exactly this way: DSCP 4 is TOS 0x10, the
old "lowdelay" bit that OpenSSH sets on every connection (`IPQoS lowdelay
throughput`). The laptop's SSH to GitHub went direct, and when ssh switched the
socket to "throughput" (0x08, DSCP 2) for `git push`, the packets fell into
xray's TPROXY halfway through. xray had never seen the connection, so the board
reset it. 7 sets all three RFC 1349 TOS bits at once, a combination that has no
defined meaning and that no program uses. It sits in precedence 0, so Wi-Fi
(cfg80211, RFC 8325) keeps it in best effort. Avoid 1-6 (the legacy TOS bits),
8 (CS1, background), 10/18/26/34 (the AF classes ssh and VoIP use) and 46 (EF).

## Board side

| Piece | DSCP host |
|---|---|
| `0010` | validates and normalises the field; writes `dhcp-host=<mac>,<ip>` (fixed address, **no** `set:direct`, so DNS stays on dnsmasq and is tunnelled) |
| `netpolicy` | `-A DIRECT -s <ip> -m mac --mac-source <mac> -m dscp --dscp <n> -j MARK --set-xmark 0x10/0x10`; from there it's identical to 005: ACCEPT ahead of XRAY, ip rule 5100 → main → wwan0, the kill switch RETURNs the mark |
| kernel | `CONFIG_NETFILTER_XT_MATCH_DSCP=m` (`xt_dscp.ko`); iptables already ships `libxt_dscp.so` |
| `after-preset-check.sh` | checks the dhcp-host line, that no `tag:direct` lines remain when there are only DSCP hosts, and that `xt_dscp.ko` and `libxt_dscp.so` are present |
| `testbot-diag.sh` | checks that the DIRECT chain has the host's DSCP rule, then runs the 005 route check |

Unmarked packets from the host fall through to XRAY, so they are tunnelled
exactly like any other client.

## Client side: `tools/dscp-direct-run.sh`

```bash
sudo tools/dscp-direct-run.sh [-d 7] [-u user] -- <command> [args]
sudo tools/dscp-direct-run.sh stop
tools/dscp-direct-run.sh status
```

The script creates the cgroup v2 group `/sys/fs/cgroup/dscp-direct` and the nft
table `inet dscp_direct`, which runs
`socket cgroupv2 level 1 "dscp-direct" ip/ip6 dscp set <n>` in the output hook
at mangle priority. It then moves itself into the group and execs the command,
running as the sudo user. Children inherit the group. The mark is per socket,
so every packet of a flow carries it, the SYN included, and no flow changes
path halfway through.

Requires cgroup v2, nftables, and kernel 5.13 or later (nft socket cgroupv2).
The rule was checked in an unprivileged user+net namespace: a UDP socket in the
matched cgroup sends DSCP 7 whatever TOS the program set, and a socket
outside it that sets TOS 0x1c itself is cleared to DSCP 0.

## Limits

- **DNS**: the system resolver (systemd-resolved) is outside the cgroup, so
  lookups stay unmarked and tunnelled. The process's own traffic is direct, but
  the addresses it resolves come from the tunnel's view. A CDN may hand it an
  exit-country node that it then reaches directly.
- **Exclusive mark**: the client table first clears the DSCP from every
  packet and only then sets it for the group, so a program outside the group
  cannot carry it, even by accident. Root on the client can still bypass. The board identifies the device by MAC+IP, and the client's own
  configuration decides which of its traffic goes direct.
- **Conntrack**: there is no CONNMARK; each packet is matched on its own. That
  is fine because the client sets the mark on every packet of the group's
  sockets, overriding the program's own TOS (an ssh run inside the group
  stays direct for its whole connection). Kernel-made
  packets with no full socket behind them (a TIME_WAIT ACK, an RST for a closed
  port) are unmarked and go into the tunnel, where they are harmless.
- The cgroup path is resolved when the nft rule loads, so a run always reloads
  the table. Use `stop` rather than deleting the group by hand.

## Test plan (testbot4 + the client)

1. OTA the build. On the board, `iptables -t mangle -S DIRECT` shows
   `--dscp 0x07` on the host's rule, and `testbot-diag` reports `direct ... OK`.
2. On the client: `curl ifconfig.me` shows the exit server's IP (tunnelled).
3. `sudo tools/dscp-direct-run.sh -- curl ifconfig.me` shows the carrier's IP,
   and a plain `ssh -T git@github.com` / `git push` still works (tunnelled).
4. `iptables -t mangle -L DIRECT -v -n` on the board: the counters grow only
   during step 3.
5. With `XRAY_KILLSWITCH=ON` and xray stopped, the marked process still gets
   out and the rest of the client is rejected.
