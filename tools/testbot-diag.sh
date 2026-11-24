#!/bin/bash
# Where is testbot4's uplink broken? Run from a host on the board's Wi-Fi AP.
#
# A session on this host goes host wlan0 -> board AP -> xray TPROXY -> VLESS/
# REALITY -> xray server -> internet, and the board's own uplink is the Quectel
# modem on wwan0. When any of those breaks the session just hangs, and the AP
# link is the one path left to ask the board what happened. This walks the stack
# bottom-up and reports every layer, so the first FAIL is the likely cause:
#
#   host     Wi-Fi association, ping and SSH to the board
#   system   uptime, clock skew (REALITY needs it), OOM, conntrack, failed units
#   ap       hostapd/dnsmasq, this host as a station seen from the board
#   modem    USB presence and re-enumerations, cdc_ether/wwan0, DHCP lease from
#            the modem, AT: SIM, signal, registration, data call, carrier IP
#   uplink   the board's direct path: ping/HTTP out of wwan0, TCP to the xray server
#   xray     unit, listeners, the probe inbound, TPROXY rules (or fallen open),
#            xray-health state, the board's own HTTPS and DNS through singtun0
#   icmpvpn  openvpn over the xray relay, tun9, its routes, a ping through it
#   e2e      from this host: DNS through the board, HTTPS to api.anthropic.com
#
# The AT round shares the modem's serial port with modem-datacall and takes the
# same lock (quectel_at.inc), so it waits its turn rather than garbling replies.
# It adds ~15s; --no-at skips it.
#
# Usage: testbot-diag.sh [-c conf] [-H host] [-u user] [-k key] [--no-at] [-v]
#                        [--watch SEC [--log FILE] | --log-state DIR]
#
#   -c FILE      config, default testbot-diag.conf next to this script (or
#                $TESTBOT_DIAG_CONF); copy testbot-diag.conf.template to start.
#                -H/-u/-k override what it sets
#   --watch SEC  repeat every SEC seconds, one summary line per run on the
#                console, every full report appended to the log - run it in tmux
#                before the session dies and read the log afterwards
#   --log-state DIR  for testbot-diag.service: one run, kept in DIR (see
#                log_state below); a run already in progress makes this one a
#                no-op
#
# Exit status: 0 all OK, 1 warnings only, 2 at least one FAIL.

CONF=${TESTBOT_DIAG_CONF:-$(dirname "$(readlink -f "$0")")/testbot-diag.conf}
DO_AT=ON
VERBOSE=OFF
WATCH=""
SSH_TIMEOUT=120

usage()
{
	sed -n '/^# Usage:/,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	-c|--config)	CONF=$2; shift ;;
	-H|--host)	OPT_ADDR=$2; shift ;;
	-u|--user)	OPT_USER=$2; shift ;;
	-k|--key)	OPT_KEY=$2; shift ;;
	--no-at)	DO_AT=OFF ;;
	-v|--verbose)	VERBOSE=ON ;;
	--watch)	WATCH=$2; shift ;;
	--log)		OPT_LOG=$2; shift ;;
	--log-state)	STATE_DIR=$2; shift ;;
	-h|--help)	usage 0 ;;
	*)		echo "unknown option: $1" >&2; usage 1 >&2 ;;
	esac
	shift
done

## Addresses, key and SSID live in the config, not here: this file is in git,
## the config is not (.gitignore)
if [ -f "${CONF}" ]; then
	source "${CONF}"
elif [ -z "${OPT_ADDR}" ]; then
	echo "no config at ${CONF} - copy $(dirname "$(readlink -f "$0")")/testbot-diag.conf.template there, or pass -H" >&2
	exit 2
fi
BOARD=${OPT_ADDR:-${BOARD_ADDR}}
SSH_USER=${OPT_USER:-${BOARD_SSH_USER:-root}}
KEY=${OPT_KEY:-${BOARD_SSH_KEY}}
KEY=${KEY/#\~/${HOME}}
LOG=${OPT_LOG:-${WATCH_LOG}}
E2E_HOST=${E2E_HOST:-api.anthropic.com}
if [ -z "${BOARD}" ]; then
	echo "BOARD_ADDR is not set in ${CONF}" >&2
	exit 2
fi

#####################################################################
## the board side: runs as one bash script over SSH
#####################################################################
## Emits "S|section", "R|LEVEL|check|message" and "D|detail" lines; the host
## side renders them. No timeout(1) on the board, hence tmo().
read -r -d '' REMOTE <<'REMOTE_EOF'
source /etc/system.vars 2>/dev/null

S() { echo "S|$*"; }
R() { echo "R|$1|$2|$3"; [ "$1" = FAIL ] && BAD=1; return 0; }
D() { sed 's/^/D|    /'; }
## show the journal of a section that went wrong, or always with -v
J() { [ -n "${BAD}" ] || [ "${VERBOSE}" = ON ] && journalctl --no-pager -o short "$@" 2>/dev/null | D; }

## tmo SECONDS cmd... - kill cmd if it outlives SECONDS
tmo()
{
	local t=$1 p w rc
	shift
	"$@" &
	p=$!
	( sleep ${t}; kill ${p} ) > /dev/null 2>&1 &
	w=$!
	wait ${p}
	rc=$?
	kill ${w} 2>/dev/null
	return ${rc}
}

tcp_probe()
{
	python3 - "$1" "$2" <<'PY'
import socket, sys, time
t = time.time()
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close()
    print("%.0fms" % ((time.time() - t) * 1000))
except Exception as e:
    print(e)
    sys.exit(1)
PY
}

## "3 packets transmitted, 3 packets received, 0% packet loss" -> "0% loss, avg 70ms"
ping_sum()
{
	local out loss avg
	out=$(ping "$@" 2>&1)
	loss=$(echo "${out}" | grep -oE '[0-9.]+% packet loss' | cut -d% -f1)
	avg=$(echo "${out}" | sed -n -E 's|.*= [0-9.]+/([0-9.]+)/.*|\1|p')
	echo "${loss:-100}% loss${avg:+, avg ${avg}ms}"
	[ "${loss:-100}" != 100 ]
}

ago() { local s=$1; [ ${s} -ge 3600 ] && echo "$((s / 3600))h$((s % 3600 / 60))m" || echo "$((s / 60))m$((s % 60))s"; }

UP=$(cut -d. -f1 /proc/uptime)
NOW=$(date +%s)

#####################################################################
S system
BAD=
R INFO uptime "$(ago ${UP}), slot $(cat /media/boot/active 2>/dev/null || echo '?'), load $(cut -d' ' -f1-3 /proc/loadavg)"

SKEW=$((NOW - HOST_EPOCH))
if [ ${SKEW#-} -gt 30 ]; then
	R WARN clock "board is ${SKEW}s off this host ($(date -u '+%F %T') UTC) - REALITY handshakes need a correct clock"
else
	R OK clock "skew ${SKEW}s"
fi

MEM=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
OOM=$(dmesg | grep -ciE 'out of memory|oom-kill')
if [ "${OOM}" -gt 0 ]; then
	R FAIL memory "${MEM}MB available, ${OOM} OOM kill(s) since boot"
	dmesg | grep -iE 'out of memory|oom-kill' | tail -3 | D
else
	R OK memory "${MEM}MB available"
fi

CT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
CTMAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
if [ -n "${CT}" ] && [ $((CT * 100 / CTMAX)) -ge 80 ]; then
	R WARN conntrack "${CT}/${CTMAX} - new connections get dropped when it fills"
elif [ -n "${CT}" ]; then
	R OK conntrack "${CT}/${CTMAX}"
fi

## networkd-wait-online fails on every boot here and means nothing
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v systemd-networkd-wait-online)
if [ -n "${FAILED}" ]; then
	R WARN units "failed: $(echo ${FAILED})"
else
	R OK units "no failed units"
fi

#####################################################################
S ap
BAD=
for u in hostapd dnsmasq_wlan0; do
	if systemctl is-active --quiet ${u}; then
		R OK ${u} "active"
	else
		R FAIL ${u} "$(systemctl is-active ${u})"
	fi
done
## hostapd_cli, not iw: this Wi-Fi driver implements no station dump, and it
## reports signal=0 for everyone, so signal is only measurable on this host's side
NSTA=$(hostapd_cli -i wlan0 list_sta 2>/dev/null | grep -c ':')
STA=$(hostapd_cli -i wlan0 sta "${HOST_MAC}" 2>/dev/null)
if echo "${STA}" | grep -q 'AUTHORIZED'; then
	R OK this-host "${HOST_MAC}: $(echo "${STA}" | awk -F= '/^inactive_msec/ {i=$2} /^connected_time/ {c=$2} END {printf "inactive %sms, connected %ss", i, c}') (${NSTA} station(s))"
else
	R WARN this-host "${HOST_MAC} not in the board's station list (${NSTA} station(s))"
fi

#####################################################################
S modem
BAD=
if [ "${QUECTEL_ECM:-OFF}" != ON ]; then
	R INFO modem "QUECTEL_ECM=${QUECTEL_ECM:-OFF}, not checked"
else
	LOG_TAG=testbot-diag
	AT_OUT=/run/testbot-diag.at
	source /usr/libexec/quectel/quectel_at.inc

	MODEM=$(find_modem)
	if [ -z "${MODEM}" ]; then
		R FAIL usb "no Quectel (${QUECTEL_VID}) on USB - unplugged, unpowered or crashed"
	else
		BUSID=$(basename ${MODEM})
		R OK usb "${BUSID} $(cat ${MODEM}idVendor):$(cat ${MODEM}idProduct) $(cat ${MODEM}product 2>/dev/null)"
	fi

	## Every reset, CFUN cycle or brownout re-enumerates the modem. A few per day
	## are modem-datacall and quectel_ecm doing their jobs, many are a power or
	## firmware problem.
	if [ -n "${BUSID}" ]; then
		ENUMS=$(dmesg | grep -E "usb ${BUSID}: new .*USB device" | sed -n -E 's/^\[ *([0-9]+)\..*/\1/p')
		NENUM=$(echo "${ENUMS}" | grep -c .)
		LAST=$(echo "${ENUMS}" | tail -1)
		## the boot-time ones are quectel_ecm's mode check resetting the modem
		NLATE=$(echo "${ENUMS}" | awk '$1 > 600' | grep -c .)
		if [ ${NLATE} -gt 0 ]; then
			R WARN usb-resets "re-enumerated ${NLATE}x after boot (${NENUM}x in all), last $(ago $((UP - LAST))) ago"
			dmesg | grep -E "usb ${BUSID}(: USB disconnect|: new .*USB device)" | tail -4 | D
		else
			R OK usb-resets "no re-enumeration since boot (${NENUM}x during it)"
		fi
		NPORTS=$(list_ports ${MODEM} | wc -l)
		[ ${NPORTS} -gt 0 ] && R OK serial "${NPORTS} ttyUSB port(s)" || R FAIL serial "no ttyUSB ports - no AT access"
	fi

	if [ ! -e /sys/class/net/wwan0 ]; then
		R FAIL wwan0 "no interface - modem not in ECM mode, or cdc_ether did not bind"
	else
		DRV=$(basename "$(readlink /sys/class/net/wwan0/device/driver)")
		OPER=$(cat /sys/class/net/wwan0/operstate)
		CARRIER=$(cat /sys/class/net/wwan0/carrier 2>/dev/null)
		if [ "${OPER}" = up ] && [ "${CARRIER}" = 1 ]; then
			R OK wwan0 "${DRV}, ${OPER}, carrier ${CARRIER}"
		else
			R FAIL wwan0 "${DRV}, ${OPER}, carrier ${CARRIER:-?}"
		fi
		if systemctl is-active --quiet quectel-ecm-up; then
			R OK dhclient "quectel-ecm-up active, restarts $(systemctl show -p NRestarts --value quectel-ecm-up)"
		else
			R FAIL dhclient "quectel-ecm-up $(systemctl is-active quectel-ecm-up)"
		fi
		ADDR=$(ip -4 -br addr show wwan0 | awk '{print $3}')
		GW=$(ip route show default dev wwan0 | awk '{print $3; exit}')
		if [ -z "${ADDR}" ]; then
			R FAIL lease "wwan0 has no IPv4 address"
		elif [ -z "${GW}" ]; then
			R FAIL lease "${ADDR}, but no default route via wwan0"
		else
			R OK lease "${ADDR}, default via ${GW}"
			## The modem's own DHCP server and router - this proves only the USB
			## link, never the carrier
			if P=$(ping_sum -c2 -W2 -q ${GW}); then
				R OK modem-gw "${GW}: ${P}"
			else
				R FAIL modem-gw "${GW}: ${P} - USB link up but the modem does not answer"
			fi
		fi
	fi

	if [ "${DO_AT}" = ON ] && [ -n "${MODEM}" ]; then
		at_round()
		{
			local p c
			p=$(find_at_port "$(list_ports ${MODEM})") || return 3
			echo "port ${p}" > ${AT_OUT}.all
			for c in 'AT+CPIN?' 'AT+CSQ' 'AT+CEREG?' 'AT+COPS?' 'AT+QNETDEVCTL?' \
				'AT+CGPADDR=1' 'AT+QCSQ' 'AT+QENG="servingcell"'; do
				at_cmd ${p} "${c}" 1 >> ${AT_OUT}.all
			done
		}
		LOCK_WAIT=25
		with_modem_lock at_round
		RC=$?
		A=$(cat ${AT_OUT}.all 2>/dev/null)
		rm -f ${AT_OUT} ${AT_OUT}.all

		if [ ${RC} -eq 111 ]; then
			R WARN at "serial port busy for ${LOCK_WAIT}s (quectel_ecm/modem-time?), AT skipped"
		elif [ ${RC} -eq 3 ]; then
			R FAIL at "no ttyUSB port answers AT - modem firmware hung?"
		else
			field() { echo "${A}" | sed -n -E "$1" | head -1; }
			CPIN=$(field 's/.*\+CPIN: *([A-Z ]+).*/\1/p')
			CSQ=$(field 's/.*\+CSQ: *([0-9]+),.*/\1/p')
			REG=$(field 's/.*\+CEREG: *[0-9]+,([0-9]+).*/\1/p')
			OPER=$(field 's/.*\+COPS: *[0-9]+,[0-9]+,"([^"]*)",([0-9]+).*/\1 act=\2/p')
			CONN=$(field 's/.*\+QNETDEVCTL: *[0-9]+,[0-9]+,[0-9]+,([0-9]+).*/\1/p')
			CIP=$(field 's/.*\+CGPADDR: *1,"?([^",]*)"?.*/\1/p')
			RSRP=$(field 's/.*\+QCSQ: *"LTE",-?[0-9]+,(-[0-9]+),.*/\1/p')

			if [ "${CPIN}" = READY ]; then
				R OK sim "READY"
			else
				R FAIL sim "${CPIN:-no answer} - SIM missing, locked or not seated"
			fi

			if [ -z "${CSQ}" ] || [ "${CSQ}" = 99 ]; then
				R FAIL signal "CSQ ${CSQ:-?} (no signal)"
			else
				SIG="CSQ ${CSQ} ($((-113 + 2 * CSQ)) dBm)${RSRP:+, RSRP ${RSRP} dBm}"
				if [ "${CSQ}" -lt 10 ] || [ "${RSRP:-0}" -lt -110 ]; then
					R WARN signal "${SIG} - weak"
				else
					R OK signal "${SIG}"
				fi
			fi
			echo "${A}" | grep -E '^\+(QENG|QCSQ)' | D

			case "${REG}" in
			1)	R OK registration "home network, ${OPER}" ;;
			5)	R OK registration "roaming, ${OPER}" ;;
			2)	R FAIL registration "searching (CEREG 2)" ;;
			3)	R FAIL registration "denied by the network (CEREG 3) - SIM/plan/APN" ;;
			*)	R FAIL registration "not registered (CEREG ${REG:-?})" ;;
			esac

			if [ "${CONN}" = 1 ]; then
				R OK datacall "connected, carrier IP ${CIP:-?}"
			else
				R FAIL datacall "not connected (QNETDEVCTL 4th field ${CONN:-?}) - modem-datacall redials within ~30s while registered"
			fi
		fi
	elif [ "${DO_AT}" != ON ]; then
		R INFO at "skipped (--no-at)"
	fi
	if systemctl is-active --quiet modem-datacall; then
		R OK modem-datacall "active"
	else
		R WARN modem-datacall "$(systemctl is-active modem-datacall) - nobody redials a dropped data call"
	fi
	J -t modem_datacall -t quectel_ecm -t modem_time -n 6
fi

#####################################################################
S uplink
BAD=
## The xray server first: it is the one destination the carrier has to pass for
## anything to work, and the box's connection to it bypasses singtun0 (rule 9010).
## The public probes below are not proof either way - the carrier filters direct
## traffic even on a healthy link (workplans/003; 1.1.1.1 is dropped outright at
## times while 8.8.8.8 answers) - so they FAIL only when the server is
## unreachable too, and WARN otherwise.
SRV_OK=""
if [ -f /etc/xray/config.json ]; then
	SRV=$(python3 -c '
import json
for o in json.load(open("/etc/xray/config.json")).get("outbounds", []):
    v = o.get("settings", {}).get("vnext") or o.get("settings", {}).get("servers")
    if v:
        print(v[0].get("address"), v[0].get("port")); break' 2>/dev/null)
	SRV_ADDR=${SRV% *}
	SRV_PORT=${SRV#* }
	if [ -n "${SRV}" ]; then
		if T=$(tcp_probe ${SRV_ADDR} ${SRV_PORT}); then
			SRV_OK=1
			R OK xray-server "TCP ${SRV_ADDR}:${SRV_PORT} connects in ${T}"
		else
			R FAIL xray-server "TCP ${SRV_ADDR}:${SRV_PORT}: ${T} - server down or blocked by the carrier"
		fi
	fi
fi
[ -n "${SRV_OK}" ] && MISS=WARN || MISS=FAIL

## Out of wwan0 and around every tunnel: the board's ICMP and 1.1.1.1:80 are
## excepted from singtun0 (xraypolicy rules 9020/9035)
for t in 1.1.1.1 8.8.8.8; do
	if P=$(ping_sum -I wwan0 -c3 -W2 -q ${t}); then
		R OK ping "${t} via wwan0: ${P}"
	else
		R ${MISS} ping "${t} via wwan0: ${P}"
	fi
done
HTTP=$(curl -s -o /dev/null -m 6 --interface wwan0 -w '%{http_code} %{time_total}s' http://1.1.1.1/)
RC=$?
if [ ${RC} -eq 0 ]; then
	R OK http "http://1.1.1.1 via wwan0: ${HTTP}"
elif [ -n "${SRV_OK}" ] && [ "${XRAY_CLIENT:-OFF}" = ON ]; then
	## xray-health's direct probe is exactly this request: while it fails,
	## a dead tunnel gets blamed on the uplink and xray is never restarted
	R WARN http "http://1.1.1.1 via wwan0: curl exit ${RC}, carrier-filtered - xray-health would take a dead tunnel for a dead uplink and not restart xray"
else
	R ${MISS} http "http://1.1.1.1 via wwan0: curl exit ${RC}"
fi

#####################################################################
S xray
BAD=
if [ "${XRAY_CLIENT:-OFF}" != ON ]; then
	R INFO xray "XRAY_CLIENT=${XRAY_CLIENT:-OFF}, not checked"
else
	if systemctl is-active --quiet xray; then
		SINCE=$(systemctl show -p ActiveEnterTimestampMonotonic --value xray)
		RSS=$(awk '/VmRSS/ {print int($2/1024)}' /proc/$(systemctl show -p MainPID --value xray)/status 2>/dev/null)
		R OK service "active for $(ago $((UP - SINCE / 1000000))), restarts $(systemctl show -p NRestarts --value xray), RSS ${RSS}MB"
	else
		R FAIL service "xray $(systemctl is-active xray)"
	fi

	PP=${XRAY_PROBE_PORT:-5301}
	TP=${XRAY_TPROXY_PORT:-12345}
	MISSING=""
	for l in "tcp :${TP}" "tcp 127.0.0.1:${PP}" "udp ${XRAY_DNS_ADDR:-127.0.0.2}:53"; do
		ss -ln${l:0:1}p 2>/dev/null | grep xray | grep -q -- "${l#* }\b" || MISSING="${MISSING} ${l}"
	done
	[ -z "${MISSING}" ] && R OK listeners "tproxy, probe, dns-in" || R FAIL listeners "not listening:${MISSING}"

	## The probe inbound is a dokodemo-door to 1.1.1.1:80: one request there is
	## inbound + outbound + REALITY handshake + server + exit, which is exactly
	## xray-health's check
	HTTP=$(curl -s -o /dev/null -m 8 -H 'Host: 1.1.1.1' -w '%{http_code} %{time_total}s' http://127.0.0.1:${PP}/)
	RC=$?
	if [ ${RC} -eq 0 ] && [ "${HTTP%% *}" != 000 ]; then
		R OK tunnel "probe through the tunnel: HTTP ${HTTP}"
	else
		R FAIL tunnel "probe through the tunnel: curl exit ${RC} - xray is up but nothing gets through (server, REALITY, clock)"
	fi

	NMANGLE=$(iptables -t mangle -S PREROUTING 2>/dev/null | grep -c -- '-j XRAY')
	if ip rule | grep -q 'fwmark 0x1 lookup 100' && [ ${NMANGLE} -gt 0 ]; then
		R OK tproxy "LAN goes through xray (${NMANGLE} PREROUTING rule(s))"
	elif [ "${XRAY_KILLSWITCH:-OFF}" = ON ]; then
		R FAIL tproxy "TPROXY rules out and XRAY_KILLSWITCH=ON - the LAN has no way out"
	else
		R WARN tproxy "TPROXY rules out - the LAN is on the direct path (fallen open)"
	fi

	## direct hosts (WIFI_AP_DIRECT_HOSTS): netpolicy's DIRECT jump must come
	## before XRAY, and their marked packets must leave on the uplink, not a tunnel
	if [ -n "${WIFI_AP_DIRECT_HOSTS}" ]; then
		FIRST=$(iptables -t mangle -S PREROUTING 2>/dev/null | sed -n 2p)
		AP_IF=${WIFI_AP_WLAN_NAME:-wlan0}
		for h in ${WIFI_AP_DIRECT_HOSTS}; do
			## "<mac>,<ip>[,<dscp>]": with a DSCP only that class bypasses
			HIP=$(echo "${h}" | cut -d, -f2)
			HDSCP=$(echo "${h}" | cut -d, -f3)
			if [ -n "${HDSCP}" ] && ! iptables -t mangle -S DIRECT 2>/dev/null | grep -q -- "-s ${HIP}/32 .*--dscp 0x$(printf %02x "${HDSCP}")"; then
				R FAIL direct "${h}: no DSCP ${HDSCP} rule in the DIRECT chain - the marked process is tunnelled"
				continue
			fi
			DEV=$(ip route get 1.1.1.1 from ${HIP} iif ${AP_IF} mark 0x10 2>&1 | sed -n 's/.* dev \([^ ]*\).*/\1/p;q')
			case "${FIRST}" in
			*"-j DIRECT"*) ;;
			*) R FAIL direct "${h}: DIRECT is not the first mangle PREROUTING rule - it is TPROXY'd"; continue ;;
			esac
			if ! ip rule | grep -q '^5100:.*fwmark 0x10/0x10 lookup main'; then
				R FAIL direct "${h}: no pref 5100 rule - a WireGuard or icmpvpn rule can take it"
			elif [ -z "${DEV}" ]; then
				R WARN direct "${h}: no route out (uplink down?)"
			else
				case "${DEV}" in
				singtun*|wg*|tun*) R FAIL direct "${h}: routed into ${DEV}" ;;
				*) R OK direct "${h}: out ${DEV}, bypassing the tunnels" ;;
				esac
			fi
		done
	fi

	HS=/run/xray-health
	HSTATE=$(cat ${HS}/state 2>/dev/null || echo up)
	HFAILS=$(cat ${HS}/fails 2>/dev/null || echo 0)
	HLAST=$(cat ${HS}/last-restart 2>/dev/null)
	HMSG="state ${HSTATE}, ${HFAILS} consecutive failed probe(s)${HLAST:+, last restart $(ago $((NOW - HLAST))) ago}"
	if ! systemctl is-active --quiet xray-health.timer; then
		R WARN xray-health "timer $(systemctl is-active xray-health.timer) - nobody watches the tunnel"
	elif [ "${HSTATE}" = down ] || [ "${HFAILS}" -gt 0 ]; then
		R WARN xray-health "${HMSG}"
	else
		R OK xray-health "${HMSG}"
	fi
	## each restart drops every connection through the tunnel - a long-lived
	## session on the LAN feels these even when the tunnel recovers
	NREST=$(journalctl -t xray-health --since -1h --no-pager 2>/dev/null | grep -c 'restarting xray')
	[ ${NREST} -gt 0 ] && R WARN restarts "xray-health restarted xray ${NREST}x in the last hour"

	if [ "${XRAY_BOARD_TUNNEL:-OFF}" = ON ]; then
		if ip -br link show singtun0 > /dev/null 2>&1 && ip rule | grep -q '^9040:'; then
			R OK singtun0 "up, board traffic routed into it"
		else
			R FAIL singtun0 "missing or not routed - the board's own traffic goes out bare"
		fi
	fi

	## the board's own resolver (resolved through singtun0) and HTTPS through the
	## board tunnel - the same path as this host's session, minus TPROXY
	if NS=$(tmo 8 resolvectl query --cache=no --legend=no ${E2E_HOST} 2>&1); then
		R OK board-dns "${E2E_HOST} -> $(echo "${NS}" | awk 'NR == 1 {print $2, $NF}' | sed 's/ / via /')"
	else
		R FAIL board-dns "board cannot resolve ${E2E_HOST}"
	fi
	HTTP=$(curl -s -o /dev/null -m 10 -w '%{http_code} %{time_total}s' https://${E2E_HOST}/)
	RC=$?
	case ${RC} in
	0)	R OK board-https "https://${E2E_HOST} from the board: HTTP ${HTTP}" ;;
	6)	R FAIL board-https "DNS failure (curl 6)" ;;
	28)	R FAIL board-https "timed out (curl 28)" ;;
	35|60)	R FAIL board-https "TLS failed (curl ${RC})" ;;
	*)	R FAIL board-https "curl exit ${RC}" ;;
	esac
	## xray logs every accepted connection; those say nothing about a failure
	J -u xray -u xray-health -n 200 | grep -v ' accepted ' | tail -8
fi

#####################################################################
S icmpvpn
BAD=
if [ ! -f /etc/icmpvpn/client.conf ]; then
	R INFO icmpvpn "not in this image (ICMPVPN=OFF)"
elif [ ! -f /media/data/icmpvpn.on ]; then
	R INFO icmpvpn "switched off (icmpvpn off), not checked"
else
	U=icmpvpn-openvpn
	if systemctl is-active --quiet ${U}; then
		R OK openvpn "active, restarts $(systemctl show -p NRestarts --value ${U})"
	else
		R FAIL openvpn "${U} $(systemctl is-active ${U})"
	fi
	RELAY=$(sed -n -E 's/^remote +127\.0\.0\.1 +([0-9]+).*/\1/p' /etc/icmpvpn/client.conf)
	if [ -n "${RELAY}" ]; then
		ss -lnup 2>/dev/null | grep xray | grep -q "127.0.0.1:${RELAY}\b" &&
			R OK relay "xray relay 127.0.0.1:${RELAY} listening" ||
			R FAIL relay "xray relay 127.0.0.1:${RELAY} not listening - openvpn has nowhere to dial"
	fi
	T9=$(ip -4 -br addr show tun9 2>/dev/null | awk '{print $3}')
	NR=$(ip route show table 2030 2>/dev/null | wc -l)
	if [ -n "${T9}" ] && [ ${NR} -gt 0 ]; then
		R OK tun9 "${T9}, ${NR} route(s) in table 2030"
	else
		R FAIL tun9 "address ${T9:-none}, ${NR} route(s) in table 2030"
	fi
	## the target icmpvpn status pings, from the script itself rather than a copy
	PT=$(sed -n -E 's/^PING_TARGET=([0-9.]+).*/\1/p' /usr/sbin/icmpvpn)
	if P=$(ping_sum -c3 -W3 -q ${PT}); then
		R OK ping "Google via tun9: ${P}"
	else
		R FAIL ping "Google via tun9: ${P}"
	fi
	J -u ${U} -t icmpvpn -n 6
fi
REMOTE_EOF

#####################################################################
## the host side
#####################################################################
if [ -t 1 ] && [ -z "${WATCH}" ]; then
	C_OK=$'\e[32m' C_WARN=$'\e[33m' C_FAIL=$'\e[31m' C_INFO=$'\e[36m' C_B=$'\e[1m' C_0=$'\e[0m'
fi

FAILS=()
WARNS=()
SECTION=""

section() { SECTION=$1; printf '\n%s== %s%s\n' "${C_B}" "$1" "${C_0}"; }
detail() { printf '%s\n' "$1"; }
result()
{
	local level=$1 name=$2 msg=$3 c
	eval "c=\${C_${level}}"
	printf '  %s%-4s%s %-16s %s\n' "${c}" "${level}" "${C_0}" "${name}" "${msg}"
	case ${level} in
	FAIL)	FAILS+=("${SECTION}/${name}: ${msg}") ;;
	WARN)	WARNS+=("${SECTION}/${name}: ${msg}") ;;
	esac
}

render_remote()
{
	local line rest level name
	while IFS= read -r line; do
		case "${line}" in
		S\|*)	section "${line#S|}" ;;
		R\|*)	rest=${line#R|}
			level=${rest%%|*}; rest=${rest#*|}
			name=${rest%%|*}
			result "${level}" "${name}" "${rest#*|}" ;;
		D\|*)	detail "${line#D|}" ;;
		*)	[ -n "${line}" ] && detail "    ${line}" ;;
		esac
	done
}

run_once()
{
	local dev mac link ssid p rc out http t

	FAILS=()
	WARNS=()
	printf '%stestbot diagnostics, %s, board %s%s\n' "${C_B}" "$(date '+%F %T %Z')" "${BOARD}" "${C_0}"

	section host
	dev=$(ip route get "${BOARD}" 2>/dev/null | sed -n -E 's/.* dev ([^ ]+).*/\1/p')
	mac=$(cat /sys/class/net/${dev}/address 2>/dev/null)
	if [ -z "${dev}" ]; then
		result FAIL route "no route to ${BOARD}"
	elif link=$(iw dev "${dev}" link 2>/dev/null) && echo "${link}" | grep -q '^Connected'; then
		ssid=$(echo "${link}" | sed -n 's/^\s*SSID: //p')
		if [ -n "${AP_SSID}" ] && [ "${ssid}" != "${AP_SSID}" ]; then
			## another network: everything below would be measuring the wrong path
			result FAIL wifi "${dev} is on '${ssid}', not the board's AP_SSID"
		else
			result OK wifi "${dev}: $(echo "${link}" | awk -F': ' '/SSID/ {s=$2} /signal/ {g=$2} /tx bitrate/ {b=$2} END {printf "%s, %s, tx %s", s, g, b}')"
		fi
	elif [ -d /sys/class/net/${dev}/wireless ]; then
		result FAIL wifi "${dev} is not associated"
	else
		result INFO link "${dev} (not Wi-Fi)"
	fi

	p=$(ping -c3 -W1 -q "${BOARD}" 2>&1)
	if echo "${p}" | grep -q ' 0% packet loss'; then
		result OK ping "${BOARD}: $(echo "${p}" | sed -n -E 's|.*= [0-9.]+/([0-9.]+)/.*|avg \1ms|p')"
	elif echo "${p}" | grep -q '100% packet loss'; then
		result FAIL ping "${BOARD} does not answer - AP down, board hung or rebooting"
	else
		result WARN ping "${BOARD}: $(echo "${p}" | grep -oE '[0-9.]+% packet loss')"
	fi

	out=$(printf '%s\n' "${REMOTE}" | timeout ${SSH_TIMEOUT} ssh -o BatchMode=yes \
		-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
		-o StrictHostKeyChecking=no ${KEY:+-i "${KEY}"} "${SSH_USER}@${BOARD}" \
		"HOST_EPOCH=$(date +%s) HOST_MAC=${mac} E2E_HOST=${E2E_HOST} DO_AT=${DO_AT} VERBOSE=${VERBOSE} bash -c \"\$(cat)\" testbot-diag" 2>&1)
	rc=$?
	if [ ${rc} -eq 255 ] && [ -z "$(echo "${out}" | grep '^S|')" ]; then
		result FAIL ssh "${SSH_USER}@${BOARD}: $(echo "${out}" | tail -1)"
	else
		result OK ssh "${SSH_USER}@${BOARD}"
		## not a pipe: render_remote fills FAILS/WARNS, a subshell would lose them
		render_remote <<< "${out}"
		if [ ${rc} -eq 124 ]; then
			result FAIL remote "board-side checks did not finish in ${SSH_TIMEOUT}s, stuck after the last line above"
		fi
	fi

	## The real question: does this host get out, the way its session does
	section e2e
	if [ -n "$(dig +short +time=3 +tries=1 @"${BOARD}" "${E2E_HOST}" A 2>/dev/null | grep -E '^[0-9.]+$')" ]; then
		result OK lan-dns "${BOARD} resolves ${E2E_HOST}"
	else
		result FAIL lan-dns "${BOARD} does not resolve ${E2E_HOST} (dnsmasq -> xray dns-in)"
	fi
	http=$(curl -s -o /dev/null -m 10 -w '%{http_code} %{time_total}s' "https://${E2E_HOST}/")
	rc=$?
	if [ ${rc} -eq 0 ]; then
		result OK https "https://${E2E_HOST} from this host: HTTP ${http}"
	else
		result FAIL https "https://${E2E_HOST} from this host: curl exit ${rc}"
	fi
	for t in $(ls /sys/class/net | grep -E '^(tun|wg|ppp)'); do
		result INFO vpn "${t} $(ip -br link show ${t} | grep -q LOWER_UP && echo up || echo down) on this host - its own carrier runs through the board too"
	done

	section summary
	if [ ${#FAILS[@]} -gt 0 ]; then
		result FAIL verdict "${FAILS[0]}"
		[ ${#FAILS[@]} -gt 1 ] && printf '    (and %d more FAIL, likely consequences of the first)\n' $((${#FAILS[@]} - 1))
		VERDICT="FAIL ${FAILS[0]}"
		VERDICT_KEY="FAIL ${FAILS[0]%%:*}"
		return 2
	elif [ ${#WARNS[@]} -gt 0 ]; then
		result WARN verdict "${#WARNS[@]} warning(s), first: ${WARNS[0]}"
		VERDICT="WARN ${WARNS[0]}"
		VERDICT_KEY="WARN ${WARNS[0]%%:*}"
		return 1
	fi
	result OK verdict "every layer answers"
	VERDICT="OK"
	VERDICT_KEY="OK"
	return 0
}

## One run for the service, kept so an outage can be read back afterwards:
##
##   DIR/last.txt         the latest full report
##   DIR/history.log      one line per run: time, seconds taken, verdict
##   DIR/reports/*.txt    full reports of runs that FAILed or changed the verdict
##   DIR/verdict          the previous verdict key and since when, for transitions
##
## A verdict key is the level and the first check's name ("FAIL modem/datacall"),
## not its message, which carries timings and would make every run a change.
## Transitions also go to the journal at warning priority, so
## "journalctl -t testbot-diag -p warning" is the list of outages. stdout gets the
## full report only when it is saved, one line otherwise.
log_state()
{
	local t0 rc took now prev since report changed=""

	mkdir -p "${STATE_DIR}/reports" || exit 2
	exec 7> "${STATE_DIR}/lock"
	if ! flock -n 7; then
		echo "another run holds ${STATE_DIR}/lock, skipping"
		exit 0
	fi

	t0=$(date +%s)
	## into a file, not $(...): run_once sets VERDICT/VERDICT_KEY, a subshell would lose them
	run_once > "${STATE_DIR}/run.txt" 2>&1
	rc=$?
	report=$(cat "${STATE_DIR}/run.txt")
	rm -f "${STATE_DIR}/run.txt"
	now=$(date +%s)
	took=$((now - t0))

	printf '%s\n' "${report}" > "${STATE_DIR}/last.txt"
	echo "$(date -d @${t0} '+%F %T') ${took}s ${VERDICT}" >> "${STATE_DIR}/history.log"

	[ -f "${STATE_DIR}/verdict" ] && read -r since prev < "${STATE_DIR}/verdict"
	if [ "${prev}" != "${VERDICT_KEY}" ]; then
		changed=1
		if [ -n "${prev}" ]; then
			logger -t testbot-diag -p user.warning \
				"${prev} -> ${VERDICT} (after $(( (now - since) / 60 ))m of ${prev})"
		fi
		echo "${now} ${VERDICT_KEY}" > "${STATE_DIR}/verdict"
	fi

	if [ -n "${changed}" ] || [ ${rc} -eq 2 ]; then
		printf '%s\n' "${report}" > "${STATE_DIR}/reports/$(date -d @${t0} '+%Y%m%d-%H%M%S').txt"
		printf '%s\n' "${report}"
	else
		echo "${VERDICT_KEY} (${took}s)"
	fi
	find "${STATE_DIR}/reports" -name '*.txt' -mtime +30 -delete
	exit ${rc}
}

if [ -n "${STATE_DIR}" ]; then
	log_state
elif [ -z "${WATCH}" ]; then
	run_once
	exit $?
fi

LOG=${LOG:-${HOME}/testbot-diag.log}
: >> "${LOG}" || exit 2
echo "every ${WATCH}s, full reports in ${LOG}"
while true; do
	run_once >> "${LOG}" 2>&1
	echo "$(date '+%F %T') ${VERDICT}"
	echo >> "${LOG}"
	sleep "${WATCH}"
done
