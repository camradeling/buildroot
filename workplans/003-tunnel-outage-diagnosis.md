# 003 — Claude Code outages through testbot4: diagnosis so far

Status: **2026-09-30: testbot4 switched to a WireGuard uplink** (see the last section); the TCP findings below are why.

## Topology

```
host 192.168.3.13 ──wlan──> testbot4 wlan0 192.168.3.1
    ──TPROXY──> xray (VLESS+REALITY, one TCP conn per proxied flow, no mux)
    ──wwan0 192.168.43.100──> EC200A modem (NAT, gw 192.168.43.1)
    ──carrier (public NAT IP <carrier-nat-ip>)──>
    server <server-ip>:443 (xray server) ──> destination
```

REALITY: `serverName` / `dest` = `<sni>` (client fingerprint `chrome`).
No `routing` section on the board, so *all* LAN TCP/UDP to the internet goes through
the tunnel. Direct traffic from the board is carrier-filtered even when healthy, so it is
**not** a usable control.

## Method

Captures (headers only), clocks compared (board ≈ 2.34 s behind the server, which is NTP-synced):

| where | unit | file |
|---|---|---|
| testbot4 wlan0 (host .13, no ssh) | `cap-wlan0` | `/media/data/cap/wlan0.pcapNN` |
| testbot4 wwan0 (all) | `cap-wwan0` | `/media/data/cap/wwan0.pcapNN` |
| testbot4 1/s ICMP gw + srv, 56 B | `cap-ping` (`/run/pinglog.sh`) | `/media/data/cap/ping.log` |
| testbot4 1/s ICMP srv, 1372 B | `cap-bigping` (`/run/bigping.sh`) | `/media/data/cap/bigping.log` |
| the server eth0, tcp/443 + icmp | `cap-eth0` | `/var/tmp/cap/eth0.pcapNN` (60×50 MB ring ≈ 11 h) |
| host, HTTPS to api.anthropic.com every 5 s | `/tmp/cap/probe.sh` | `/tmp/cap/probe.log` |

All captures were stopped on 2026-09-27 and cleared from the board and the server. They are
archived on the host in `~/captures/2026-09-27-tunnel/`:
`testbot/` (`wlan0.pcap0*`, `wwan0.pcap0*`, `ping.log`, `bigping.log`), `server/`
(`eth0.pcap0*.gz`), and `host/` (`probe.log`, `probe.sh`, analysis scripts). Each
remote dir has an `MD5SUMS` file, and all files were verified. To re-run the scripts, copy
or symlink the pcaps to the names they expect (`/tmp/cap/b_wwan0.pcap*`,
`/tmp/cap/srv_eth0.pcap*`, gunzipped).

The capture units lived in `/run` on the board (`/run/pinglog.sh` and `/run/bigping.sh`,
now deleted); recreate them from the table above.

Analysis scripts (plain-python pcap parsing; no tshark on the host):
`ana.py` (per-bucket SYN/retransmit counts), `corr.py` (flow matching),
`loss.py` / `inj2.py` (per-direction byte loss), `inj.py` (forged RST detection).

- Flows are matched across the carrier NAT by **client ISN**; this was verified on
  healthy traffic (25/25 in-window flows matched).
- Loss must be computed by **byte-range coverage**, not packet-by-packet:
  the server's capture sees GSO super-segments, the board sees MSS-sized ones, so naive
  packet matching reports a bogus 50–90 % downstream loss.
- Copying pcaps off the server goes *through the tunnel* and stalls during outages:
  filter on the server first (`tcpdump -r … -w x "host <NAT-IP> or icmp"`), gzip, then
  `rsync --partial` in a retry loop.

## Findings

Outages observed (probe log): 09:11:40–09:20:20, 13:44–13:53 (flapping), 14:05–14:20
(flapping), 14:35–? UTC.

### 1. Loss is on the path, not on WiFi and not on the server

- WiFi leg is clean throughout: every host SYN answered, ~0 host retransmits, 1/s ICMP 60/60.
- the server is idle (load 0.00), with 0 NIC / softnet / listen / backlog / rcvq drops.
  The board's packets are *missing from the server's capture*, so they were lost in transit.

### 2. Upstream (board → server) TCP loss during outages

Byte coverage, board-sent vs server-received:

| window | upstream lost | downstream lost |
|---|---|---|
| 13:49–13:53 (outage) | 22–75 % | ~0 % |
| 13:55–14:04 (healthy) | 0–7 % | ~0 % |
| 14:05–14:11 (outage) | 6–60 % | 0–7 % |

During these windows, small (56 B) ICMP to the same server lost **0**. That is suggestive
of TCP-selective dropping but not proof, because the pings were small. `cap-bigping` was
started afterwards to cover full-size packets. Board sockets mid-outage showed cwnd 1,
backoff 5–9, and many with `bytes_acked:1` (handshake OK, not one data byte acked).

### 3. Forged RSTs kill any tunnel connection idle for ~30 s (always, not only in outages)

- 454 RST+ACK arrived at the board that the server **never sent**. All had **TTL 127 and
  IP ID 10003**. Genuine server packets arrive with TTL 48–49; the modem gw's own replies
  have TTL 128, so the injector is the modem's NAT or the carrier node right behind it.
- Timing: 30.3 / 31.4 / 32.6 s (p10/50/90) after the flow's previous packet; in 414/447
  cases the board had sent last.
- ~~On 332/400 hit flows the server keeps sending afterwards, so only the board side dies.~~
  Wrong: `inj.py` counted client packets seen at the server. See finding 6.
- A handful of RSTs with TTL 111 reached the server unsent by the board (128−17 hops,
  consistent with the same injector).
- Effect: any Claude connection idle for > 30 s (pooled keep-alive, slow response) is
  silently cut on the board side.

### 4. The 14:35 outage was congestion

ICMP loss ~25 % at *all* sizes, RTT to the server 600–870 ms (normally ~100), gw RTT
0.9 → 11 ms. wwan0 was carrying ~6 Mbit/s downstream continuously, mostly bulk downloads
by the host itself from `99.86.18.x` (CloudFront) and `<ip>` (one flow at 120 MB).
Origin of those downloads not yet identified.

### 5. Same SIM + same VPS in an Android phone works (2026-09-28)

Phone: Xiaomi 220333QNY, Android 13, AmneziaVPN. Its xray config is the board's in all
that matters: VLESS + REALITY, `xtls-rprx-vision`, fp `chrome`, SNI `<sni>`,
the same server and port, one TCP connection per flow, no mux, no `sockopt`. APN `cmnet`
IPV4V6, carrier IP directly on `rmnet_data2` (no NAT on the phone). LTE RSRP -100,
RSRQ -4, SNR 19.

- **The forged RSTs are the carrier's, not the EC200A's.** A first look (phone
  sockets idle 180 s still ESTAB) suggested the modem, but the capture proves the
  opposite. The phone (no NAT of its own) received 261 RST+ACK that the server never
  sent, with **TTL 127, IP ID 10003, 30.2–32.0 s after the last packet**, the same
  fingerprint as on the board. Most carry an inexact sequence number, so Android's kernel
  ignores them (RFC 5961) and the flow survives. About 10 % are exact and kill it.
- **The same outage signature on the phone path** (15:13–15:22 UTC, 2026-09-28):
  - Upstream: 22–50 % of the phone's data segments never reached the server.
  - Downstream: 0.4–3.7 % lost.
  - ICMP to the same server, 56 B and 1372 B: 1.2 % lost.
  - Phone sockets: `cwnd:1`, `backoff:7–8`, `bytes_acked:1`.
  - So this is **TCP-selective upstream dropping on the carrier path**, common to
    both devices. The board just hits it far more often.
  - Data: `/tmp/cap3` (`ph.py`, `rst.py`).
- The phone runs `tcp_mtu_probing=2` (MSS 1036, some sockets dropped to 512). A
  size-dependent black hole was tested on the 09-27 captures and **refuted**. Outage
  upstream loss is 34–38 % for 1–536 B segments and 25 % for 1301–1400 B (healthy:
  3 % / 1 %). `/tmp/cap/sizeloss.py` has been copied into the archive's `host/`.
- Not yet excluded: cell or band choice (the phone's cell ID/EARFCN is redacted in
  dumpsys; read it from `*#*#4636#*#*`), module-IMEI policy, EC200A uplink radio or
  antenna, and the EC200A data-call-unbind after a re-attach (see the band-steering notes).

### 6. The EC200A NAT does not react to the forged RSTs (refuted 2026-09-29)

The hypothesis: the EC200A conntrack drops its mapping on a forged RST, even one the
board's kernel ignores. It was tested on the 09-27 board captures and the 09-28 phone captures
(`host/natrst.py board|phone`), taking the first forged RST per flow and following
the flow for 60 s at both ends.

| | board | phone |
|---|---|---|
| flows hit | 1198 | 255 |
| exact seq (kills the flow) | 9 % | 10 % |
| inexact RST, flow fine both ways | ~61 % | ~69 % |
| inexact RST, client kept sending, server saw nothing | 231 / 1092 | 26 / 229 |

- Almost all inexact RSTs have a seq behind `rcv_nxt`, on both devices. Both kernels
  drop them silently.
- The dead flows cluster in outage windows. On the board, 64 % died at 13:40, 29 % at
  14:10 and 48 % at 14:40, against 0 % in the healthy windows. The phone shows 27 % in
  its outage and 0–1 % outside it.
- No post-RST packets appeared at the server on a new NAT port.

So the NAT is not the difference. The flows die from the carrier's upstream TCP loss
during outages. Caveat: the server capture covers only 13:40–15:15 on 09-27.

## Hypotheses considered

- **xray server load:** ruled out (see 1).
- **Switching to UDP** (Hysteria2 / mKCP / WireGuard; the server already runs `wg0`):
  it would remove the forged-RST problem, but keepalive does that more cheaply. It *might*
  escape selective TCP dropping, but on this carrier UDP is often throttled harder. It does
  nothing for congestion (aggressive-retransmit protocols make that worse). It also gives
  up REALITY's camouflage, since REALITY is TCP-only. Measure before switching.
- **Changing SNI to a domestic domain:** likely worse. A domestic domain routed to a
  foreign VPS IP is a glaring SNI↔IP anomaly, and probe traffic would be proxied to a
  domestic site from abroad. The current SNI is itself weak (its CDN's
  IP ranges are well known, so SNI/IP mismatch is trivial to detect). Better: a TLS 1.3 +
  H2 site in the VPS's own ASN or /24 (find one with `RealiTLScanner` on the server), or
  our own domain. It won't affect finding 3 in any case.

## Next steps

1. **Keepalive fix (finding 3):** set TCP keepalive < 30 s on the board's `proxy`
   outbound (`streamSettings.sockopt.tcpKeepAliveIdle` ≈ 15–20, `tcpKeepAliveInterval`
   ≈ 10), in the xray overlay. Verify that the TTL-127 / IPID-10003 RSTs disappear.
2. **Discriminating probes at the next outage**, all from the board to <server-ip>,
   logged 1/s next to `ping.log` / `bigping.log`:
   - TCP/443 with the current SNI,
   - TCP/443 with a different SNI (REALITY forwards it to `dest`, so the handshake still completes),
   - plain TCP/22 on the same IP,
   - UDP echo (full-size) to a small echo server on the server.

   If only the current SNI suffers, change the SNI. If port 22 and UDP suffer equally, it
   is IP-level or the link: consider a new server IP or transport. If UDP survives where
   TCP doesn't, a UDP transport is worth trying.
3. Identify the bulk downloader on the host (CloudFront / <ip>), or shape it,
   to separate congestion outages from the rest.
4. Unrelated, already fixed: `inot.sh` respawn spam (commit `11ce0a7d81`; the running board
   was patched in `/etc`, which only lasts until the next reboot).

## Automated outage tests (from 2026-09-28 23:44 UTC)

`~/outage-test/watch.sh` runs detached on the host. It watches
`/tmp/cap2/probe.log` and, at each outage, runs `phone_test.sh` on the phone over USB
adb, from `rmnet_data2` directly. Probes to the server:
- 443 with the REALITY SNI,
- 443 with an alternative SNI,
- raw TCP 8443 64 KiB upload (`probe-sink` unit on the server, `/opt/probe/sink.py`),
- TCP 22 banner,
- UDP 8443 echo, 1300 B,
- ICMP, 1372 B.

Controls: github.com over IPv4 (flaky even when healthy, so ignore it) and a domestic site. Results go to `results.log`. Stop with `kill $(cat watch.pid)`.

First clean outage, 2026-09-29 04:31 UTC:
- **Every TCP probe failed or stalled**, including **a domestic site**: the server
  443 probes with either SNI, TCP 8443, and github.
- **UDP 20/20 and ICMP 0 % loss** throughout.
- TCP 22 (handshake plus a small downstream banner) mostly passed.

So this is a **TCP-wide impairment on the carrier path**. It is not blocking
targeted at the server, its SNI or its port. It fits a stateful carrier TCP middlebox,
the same one that forges the 30 s RSTs. The obvious fix to try is a UDP transport
(AmneziaWG / WireGuard; the server already runs `wg0`). Rounds right after a host resume
(06:34) show radio or congestion loss, so exclude them.

## WireGuard uplink (deployed 2026-09-30)

Commit `94f8c6744c`: testbot4 runs `WG_LAN_ROUTE=ON`, `XRAY_CLIENT=OFF`. The peer is
the server `10.66.67.3`, endpoint `<server-ip>:51820`, keepalive 25 s. The xray
keepalive (`8fc4adfb0f`) is still in the image for when xray is switched back on.

- **The MTU has to match the server.** the server's wg0 has an MTU of 1392. With the board
  at the default 1420, every TLS handshake took 5–6 s: TCP connected in about 150 ms,
  then the certificate flight waited on PMTU recovery. At `WG_MTU=1392`, TLS takes about
  0.3 s, a request to `api.anthropic.com` takes 0.4–0.7 s, and a download ran at about 6 Mbit/s.
- **Not yet measured:** whether WireGuard also avoids the outages. Watch for an outage
  on the host probe with wg0 carrying the LAN (`journalctl -t wg-health` on the board).
  The phone-based watcher in `~/outage-test/` still runs the phone rounds and
  should be repointed at the board or stopped.
