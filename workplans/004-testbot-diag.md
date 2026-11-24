# 004 — testbot-diag: uplink diagnostics from the AP side

Status: **2026-10-31: `tools/testbot-diag.sh` written and tested against the live
testbot4** (all layers OK, ~26 s with the AT round, ~14 s with `--no-at`). **The
host service in the last section is built** (`tools/testbot-probe.sh`,
`tools/systemd/`) and tested with a scratch state directory and a simulated
outage. It is not installed yet, because that needs root once:
`sudo tools/systemd/install.sh --user <user>`.

Background: [003](003-tunnel-outage-diagnosis.md). The session on this host runs
host wlan0 → board AP → xray TPROXY → VLESS/REALITY → server, so when anything on
the board's uplink breaks, the session hangs and the AP link is the only path left
to ask the board what happened.

## What the script does now

Runs on the host, then runs one bash script on the board over SSH (`bash -c
"$(cat)"`, so nothing on the board can eat the script from stdin). Checks go
bottom-up, so the first FAIL is the likely cause and later ones are usually
consequences of it. Exit code: 0 OK, 1 warnings, 2 FAIL.

| section | checks |
|---|---|
| host | Wi-Fi association/signal, ping and SSH to the board |
| system | uptime/slot, clock skew vs. host, OOM kills, conntrack fill, failed units |
| ap | hostapd, dnsmasq_wlan0, this host in `hostapd_cli list_sta` |
| modem | USB presence, re-enumerations after the first 10 min, ttyUSB ports, wwan0 driver/state/carrier, dhclient, lease, ping to the modem's gateway; AT (under the shared `quectel_at.inc` lock): SIM, CSQ/RSRP, CEREG, COPS, QNETDEVCTL data call, carrier IP; modem-datacall |
| uplink | ping and HTTP out of wwan0 around every tunnel, TCP connect to the xray server |
| xray | unit/restarts/RSS, listeners, the probe inbound (same probe as xray-health), TPROXY rules vs. fallen open, xray-health state, xray restarts in the last hour, singtun0, the board's own DNS and HTTPS |
| icmpvpn | openvpn unit, xray relay port, tun9 and table 2030, ping to Google through it |
| e2e | DNS through the board and HTTPS to api.anthropic.com from this host |

Journals of a section are printed when it has a FAIL, or always with `-v`.
`--watch SEC` prints one line per run and appends the full reports to a log.

Local values (board address, SSH user and key, the AP's SSID, the end-to-end
host, the watch log) are in `tools/testbot-diag.conf`, which is git-ignored;
`tools/testbot-diag.conf.template` is the tracked copy. The board-side ports come
from the board's own `/etc/system.vars`, the icmpvpn ping target from
`/usr/sbin/icmpvpn`, and the xray server from `/etc/xray/config.json`, so none of
them is repeated in the script.

Board-side constraints found while writing it: no `timeout(1)` (own `tmo()`),
no `getent` (`resolvectl query`), and the Wi-Fi driver has no station dump and
reports signal 0 for every station (`hostapd_cli`, signal measured on the host only).

## Suggested additions

In rough priority order.

1. **WireGuard.** `WG_CLIENT`/`WG_LAN_ROUTE` is the other uplink (003 ran on it
   from 2026-09-30). With `XRAY_CLIENT=OFF` the script currently checks nothing
   in the tunnel layer. Add: `wg-client.service`, `wg show wg0 latest-handshakes`
   (handshake age > 3 min = FAIL), transfer counters moving, `wg-health` state and
   journal, ping `WG_PROBE_ADDR` through wg0, and the wg0 MTU against `WG_MTU`.
2. **MTU / PMTU.** 003 showed a wrong MTU looks like a slow session, not a dead
   one: TCP connected in about 150 ms while TLS took 5–6 s. Every check here
   sends small packets. Add a DF ping of 1372 bytes through the tunnel and from
   the host, plus the split between TLS time and connect time from
   `curl -w '%{time_connect} %{time_appconnect}'`. Warn when TLS takes more than
   about 10× as long as the connect.
3. **Forged RSTs and idle connections.** 003 finding 3: a tunnel connection that
   sits idle for ~30 s gets reset. The probes here are all short, so they never
   see it. Add an optional slow check: open a TCP connection through the probe
   inbound, stay silent for 45 s, then send a request. This should run only in
   watch/service mode, because it adds a minute.
4. **Loss and latency, not just reachable/unreachable.** Use 10–20 pings and
   report loss/avg/max on the gateway, 1.1.1.1 and the server. Congestion was one
   of the outage types in 003 (finding 4), and 3 pings cannot tell it apart from
   a healthy link.
5. **Board history that survives a reboot.** `/var` is tmpfs, so a board that
   reboots during an outage loses its journal. Options: `Storage=persistent` with
   a size cap on `/media/data`, or ship `journalctl -b -1` excerpts. Until then,
   the script should flag a short uptime (< 15 min) as "the board rebooted;
   earlier logs are gone".
6. **Modem detail.** Add `AT+QENG="servingcell"` parsing for RSRQ/SINR and cell
   ID. A cell ID that changes between runs means a handover, which is worth
   logging. Add `AT+CGDCONT?` for the APN, and the `+CEREG` reject cause
   (`AT+CEER`) when registration fails.
7. **Machine-readable output.** Add `--format=json` or a single key=value line,
   so the service below can keep a history and detect transitions without
   parsing colored text.
8. **Host-side VPN.** GlobalProtect's UDP 4501 runs through xray as TPROXY'd UDP.
   Check that `tun0` actually passes traffic (ping its gateway, or a known
   internal host given as an option), not only that the interface is up.
9. **Two shorter items:** `-v` should also dump `ip rule`, the mangle table and
   `ss -s`. The script should be committed, and the new `*.vars` variables it
   reads should be listed in CLAUDE.md.

## Host service: a run every 5 minutes

### Goal

Without anyone watching, keep a record of which layer broke, when it broke and
when it recovered. Then an outage that killed the session can be read back
afterwards instead of being guessed at.

### Shape

Two tiers, because five minutes is too coarse for the outages in 003, which
often lasted 1–3 minutes:

| unit | interval | does |
|---|---|---|
| `testbot-diag.timer` → `testbot-diag.service` | 5 min | full run including the AT round, report to the journal |
| `testbot-probe.timer` → `testbot-probe.service` | 30 s | host-only: `curl https://${E2E_HOST}`, ping `BOARD_ADDR`; on an OK→FAIL transition starts `testbot-diag.service` right away |

The quick probe takes under a second and catches short outages. The full
diagnosis then runs while the outage is still in progress, not up to 5 min
later when it may already be over.

### Units: system units with `User=<user>`

The user that runs Claude Code here has no lingering and no user bus
(`loginctl show-user <user>` fails), so `systemctl --user` timers would run only
while a session is open. That leaves system units, which need root once to install.

| file | |
|---|---|
| `tools/systemd/testbot-diag.{service,timer}` | `testbot-diag.sh --log-state ${STATE_DIRECTORY}`; `OnUnitInactiveSec=5min`, so the 5 min count from the end of the previous run and a slow run is never followed straight away by another; exit 1/2 are `SuccessExitStatus` |
| `tools/systemd/testbot-probe.{service,timer}` | `testbot-probe.sh ${STATE_DIRECTORY}`, every 30 s |
| `tools/systemd/install.sh` | fills in `@USER@`/`@REPO@`, checks as that user that the scripts run and the config is readable, installs to `/etc/systemd/system`, enables both timers; `--uninstall` removes them and keeps the state |

Both services share `StateDirectory=testbot-diag` (`/var/lib/testbot-diag`, owned
by the service user). Both have `ExecCondition=testbot-probe.sh --check-ap`: when
this host is not on `AP_SSID`, the run is skipped instead of logging a
wrong-network FAIL every 5 minutes. The SSID comes from the config, so the unit
files hold nothing that is not in git.

### State

`testbot-diag.sh --log-state DIR`:

- `last.txt`: the latest full report. `history.log`: one line per run, with
  time, seconds taken and the verdict.
- `reports/<time>.txt`: the full report, saved only when the verdict key changed
  or the run FAILed. Deleted after 30 days. A quiet day leaves 288 one-liners
  in `history.log`, not 288 reports.
- The verdict key is the level plus the first check's name (`FAIL modem/datacall`).
  The message is not part of the key, because it carries timings and would make
  every run a change. A change of key goes to the journal at warning priority:
  `OK -> FAIL modem/datacall: ... (after 42m of OK)`.
- The run takes a lock with `flock -n` on `DIR/lock`, so a run that overlaps
  another one is skipped.

`testbot-probe.sh DIR` pings the board and fetches `https://${E2E_HOST}`. It
writes `probe.state`, and one line in `probe.log` plus a journal warning per
transition (`uplink lost: ... curl exit 28, board ping ok`, `uplink back after
2m10s`). On OK→FAIL it runs the full diagnosis inline. When nothing changes, it
writes nothing.

`notify-send` was left out: a system unit has no session bus to send to.

### Reading it afterwards

```bash
journalctl -t testbot-diag -t testbot-probe -p warning --since yesterday  # transitions only
cat /var/lib/testbot-diag/probe.log                        # outages and their length
tail -50 /var/lib/testbot-diag/history.log                 # one line per full run
ls /var/lib/testbot-diag/reports/                          # full reports of bad runs
```

### Found while testing

- **The carrier filters the direct probes intermittently.** On 2026-10-31,
  1.1.1.1 was dropped outright (ICMP and TCP/80), and HTTP to 9.9.9.9 timed out,
  while 8.8.8.8 and the xray server answered. A few minutes later 1.1.1.1 answered
  again. The script now uses the TCP connect to the xray server as its
  carrier check, and a failing public probe is only a WARN when that connect works.
- **The same filtering blinds xray-health.** Its `probe_direct` is exactly
  `http://1.1.1.1/`. While the carrier drops that, a dead tunnel is logged as "the
  uplink is down, so this is not the tunnel's fault": the fail counter is reset,
  and xray is never restarted. The script warns when it sees this. The board-side
  fix is to probe the xray server's TCP port instead, or as well. Not done yet.

### Open points

- The AT round every 5 min holds the modem port for ~15 s, while `modem-datacall`
  polls every 15 s. They share a lock, so this costs modem-datacall at most one
  delayed poll. Use `--no-at` in the service if that turns out to matter.
- Should the quick probe also run board-side, inside the xray-health timer, so the
  board's own journal records the same outages? It sees them from the other end.
- Store the history in the repo's `~/captures/`-style archive, or only locally?
