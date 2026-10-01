#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

## /etc/xray/config.json is both the config and the switch: xray.service carries
## ConditionPathExists= on it, because preset-all enables every unit with an
## [Install] section after this script has run (see CLAUDE.md, "Optional
## services"). So the only thing that makes XRAY_CLIENT=OFF mean off is this file
## not being in the image.
XRAY_DIR="${TARGET_DIR}/etc/xray"
XRAY_CONF="${XRAY_DIR}/config.json"

TPROXY_PORT=${XRAY_TPROXY_PORT:-12345}
## The DNS inbound gets an address of its own rather than a port of its own,
## because dnsmasq is pointed at it through resolv-file= (step 6) and a resolv.conf
## nameserver line cannot carry a port. 127.0.0.0/8 is entirely local, so any
## address in it binds without being configured on lo.
##
## Not 127.0.0.53 or 127.0.0.54 - systemd-resolved owns those - and deliberately
## never port 5353 either: that is mDNS, resolved binds 0.0.0.0:5353 for its stub,
## and xray treats a failed inbound bind as fatal ("bind: address already in use")
## and then restart-loops forever. Measured on the board; the LAN had no uplink at
## all because of a port number.
DNS_ADDR=${XRAY_DNS_ADDR:-127.0.0.2}
## Where DNS actually goes: through the tunnel while it is up (the dns-in inbound
## below dials it), directly from the box while it is down (xraypolicy writes it
## into the resolv-file). One value, so the two paths cannot answer differently.
DNS_UPSTREAM=${XRAY_DNS_UPSTREAM:-1.1.1.1}
## The TUN inbound for the box's own DNS (step 5). Fixed, and repeated in
## overlays/services/xray/usr/sbin/xraypolicy - keep the two in step.
TUN_IFACE=singtun0
TUN_ADDR=172.19.0.1/30
TUN_DNS=172.19.0.2
## With the tunnel up the box's own lookups go to resolved's stub, and resolved
## sends them into the TUN; with it down, to ${DNS_UPSTREAM} directly - this
## drop-in is that down state, so it is the same resolver either way.
RESOLVED_DROPIN="${TARGET_DIR}/etc/systemd/resolved.conf.d/xray.conf"
## The health check's probe inbound (see xray-health). Loopback only.
PROBE_PORT=${XRAY_PROBE_PORT:-5301}
LAN_IFACES=${XRAY_LAN_IFACES:-usb0 wlan0}
KILLSWITCH=${XRAY_KILLSWITCH:-OFF}
## TCP keepalive on the tunnel's own connections to the server, in seconds of
## idle before the first probe. Unset or OFF leaves xray's default, which is not
## short enough for every path: measured on testbot4's carrier (a
## phone on the same SIM gets the same packets), a middlebox forges an RST+ACK
## (TTL 127, IP ID 10003, never sent by the server) into any tunnel connection
## that has been silent for ~30 s, and live tunnel sockets there had keepalive
## timers with up to 43 s still to run. About one in ten of those RSTs carries an
## exact sequence number and kills the connection, and whatever LAN client was
## riding it sees it cut for no visible reason.
KEEPALIVE=${XRAY_TCP_KEEPALIVE:-OFF}

## The LAN resolvers. Both files are re-copied from their overlays on every build,
## so appending to them here is not cumulative - but the lines are stripped first
## anyway, because an image built with XRAY_CLIENT=OFF must not keep a
## resolv-file= pointing at a file that nothing will ever write.
DNSMASQ_CONFS="etc/dnsmasq_usb0.conf etc/dnsmasq_wlan0.conf"

## Written by xraypolicy, read by dnsmasq. The path is repeated in
## overlays/services/xray/usr/sbin/xraypolicy - keep the two in step.
RESOLV_FILE="/run/xray-dns.conf"

fail()
{
	print_red "ERROR: $*"
	exit 1
}

## Everything that ends up inside the generated JSON is checked against this
## first: output/target is not a trusted path, and an unescaped quote in a field
## would produce a config.json that xray refuses to parse at boot with no clue
## why.
sane_field()
{
	[[ "${2}" =~ ^[A-Za-z0-9._:@%~/+-]+$ ]] || fail "${1}='${2}' contains characters that do not belong in a config field"
}

#####################################################################
## 1. clean up unconditionally
#####################################################################
## output/target/ is not wiped between builds and neither the overlay rsync nor
## the createfs copies use --delete, so without this a config from an
## XRAY_CLIENT=ON build survives into an OFF one and re-enables the whole feature.
delete_file_silent ${XRAY_CONF}
delete_file_silent ${RESOLVED_DROPIN}

for f in ${DNSMASQ_CONFS}; do
	[[ -f "${TARGET_DIR}/${f}" ]] || continue
	## The first two forms are what earlier images used (no-resolv plus an explicit
	## server=127.0.0.1#<port>); they have to go on an upgrade as well as on OFF,
	## because no-resolv is what would make the new resolv-file= line do nothing.
	sed -i -E "/^server=127\.0\.0\.1#/d;/^no-resolv\$/d;\|^resolv-file=${RESOLV_FILE}\$|d" ${TARGET_DIR}/${f}
done

#####################################################################
## 2. record the state the target can introspect, then gate
#####################################################################
## Only these go into /etc/system.vars: XRAY_CLIENT because that is what
## after-preset-check.sh reads, and the rest because xraypolicy and xray-health
## need them at runtime and must not be able to disagree with the config.json
## generated here. XRAY_CONFIG never does - it is a path on the build host - and no
## credential from it does either. The keys have to pre-exist in the system_v2
## overlay copy for these seds to have something to replace.
sed -i -E "s|export XRAY_CLIENT=.*|export XRAY_CLIENT=${XRAY_CLIENT:-OFF}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
sed -i -E "s|export XRAY_TPROXY_PORT=.*|export XRAY_TPROXY_PORT=${TPROXY_PORT}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
sed -i -E "s|export XRAY_DNS_ADDR=.*|export XRAY_DNS_ADDR=${DNS_ADDR}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
sed -i -E "s|export XRAY_DNS_UPSTREAM=.*|export XRAY_DNS_UPSTREAM=${DNS_UPSTREAM}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
sed -i -E "s|export XRAY_PROBE_PORT=.*|export XRAY_PROBE_PORT=${PROBE_PORT}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
sed -i -E "s|export XRAY_LAN_IFACES=.*|export XRAY_LAN_IFACES=\"${LAN_IFACES}\"|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
sed -i -E "s|export XRAY_KILLSWITCH=.*|export XRAY_KILLSWITCH=${KILLSWITCH}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "XRAY_CLIENT=${XRAY_CLIENT:-OFF}"

if [[ -z "${XRAY_CLIENT}" ]]; then
	print_green "INFO: variable XRAY_CLIENT is not set"
	exit 0
elif [[ "${XRAY_CLIENT}" == "OFF" ]]; then
	print_green "INFO: XRAY_CLIENT is OFF, no config.json in the image"
	exit 0
elif [[ "${XRAY_CLIENT}" != "ON" ]]; then
	fail "XRAY_CLIENT=${XRAY_CLIENT}, only ON or OFF"
fi

## The DNS inbound listens on port 53 of DNS_ADDR, so the address is the only thing
## that keeps it away from anything else on the box. A bind clash is not a
## degradation here: xray exits and the unit restart-loops forever, which is how
## the LAN ends up with no uplink at all. So refuse the two addresses
## systemd-resolved owns, and refuse anything outside 127/8 - a DNS resolver that
## answers on a LAN or uplink address is an open resolver.
case "${DNS_ADDR}" in
127.0.0.53|127.0.0.54)
	fail "XRAY_DNS_ADDR=${DNS_ADDR} is systemd-resolved's (stub/proxy listener)," \
		"and xray exits on 'bind: address already in use' - use 127.0.0.2"
	;;
127.*)
	;;
*)
	fail "XRAY_DNS_ADDR=${DNS_ADDR} is not a loopback address - the DNS inbound has" \
		"no authentication, so it must not be reachable from the LAN"
	;;
esac
sane_field XRAY_DNS_ADDR "${DNS_ADDR}"
sane_field XRAY_DNS_UPSTREAM "${DNS_UPSTREAM}"
[[ "${PROBE_PORT}" =~ ^[0-9]+$ ]] || fail "XRAY_PROBE_PORT=${PROBE_PORT} is not a number"

## One value for both idle and interval. On Linux an answered probe re-arms the
## timer from the idle threshold, so on a healthy silent connection the probe
## cadence is the idle value; the interval only matters once probes go unanswered,
## and there is nothing to gain by making that different.
KEEPALIVE_SOCKOPT=""
if [[ "${KEEPALIVE}" != "OFF" ]]; then
	[[ "${KEEPALIVE}" =~ ^[0-9]+$ ]] && [[ ${KEEPALIVE} -ge 1 ]] && [[ ${KEEPALIVE} -le 7200 ]] \
		|| fail "XRAY_TCP_KEEPALIVE=${KEEPALIVE}, only OFF or 1..7200 seconds"
	KEEPALIVE_SOCKOPT="\"sockopt\": { \"tcpKeepAliveIdle\": ${KEEPALIVE}, \"tcpKeepAliveInterval\": ${KEEPALIVE} },"
fi

if [[ -z "${XRAY_CONFIG}" ]]; then
	fail "XRAY_CLIENT is ON but XRAY_CONFIG is not set"
elif [[ ! -f "${XRAY_CONFIG}" ]]; then
	fail "XRAY_CONFIG=${XRAY_CONFIG}: file not found"
elif [[ ! -r "${XRAY_CONFIG}" ]]; then
	## The build runs as whoever invoked build.sh, and these files usually live in
	## someone's home directory with mode 700 - say so instead of failing later on
	## an empty field.
	fail "XRAY_CONFIG=${XRAY_CONFIG} is not readable by $(id -un)"
fi

#####################################################################
## 3. work out what kind of file it is and pull the outbound out of it
#####################################################################
HOST="" PORT="" UUID="" PBK="" SID="" SNI="" FP="" FLOW=""

## vless://<uuid>@<host>:<port>?<params>#<label>
parse_share_url()
{
	local url body userinfo rest hostport query k v security network

	url=$(grep -m1 '^vless://' "${XRAY_CONFIG}" | tr -d ' \t\r')
	body=${url#vless://}
	body=${body%%#*}
	userinfo=${body%%@*}
	rest=${body#*@}
	hostport=${rest%%\?*}
	query=${rest#*\?}

	UUID=${userinfo}
	HOST=${hostport%%:*}
	PORT=${hostport##*:}

	while IFS='=' read -r k v; do
		case "${k}" in
		pbk)		PBK=${v} ;;
		sid)		SID=${v} ;;
		sni)		SNI=${v} ;;
		fp)		FP=${v} ;;
		flow)		FLOW=${v} ;;
		security)	security=${v} ;;
		type)		network=${v} ;;
		esac
	done < <(tr '&' '\n' <<< "${query}")

	## The skeleton below is tcp+reality and nothing else. A share URL for
	## ws/grpc/xtls would parse cleanly and then produce a config that cannot
	## work, so refuse it here where the message can say why.
	[[ "${security}" == "reality" ]] || fail "XRAY_CONFIG has security=${security:-<none>}, only reality is supported"
	[[ "${network}" == "tcp" ]] || fail "XRAY_CONFIG has type=${network:-<none>}, only tcp is supported"
}

## One key per line out of machine-generated JSON. Ugly, adequate for the shape
## sing-box exports, and every field is checked for emptiness at step 4, so a
## miss fails the build instead of the handshake.
json_str()
{
	sed -n -E 's/.*"'"${1}"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "${XRAY_CONFIG}" | head -1
}

json_num()
{
	sed -n -E 's/.*"'"${1}"'"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "${XRAY_CONFIG}" | head -1
}

## A sing-box outbound: uuid/server/server_port plus tls.reality.*
parse_json()
{
	UUID=$(json_str uuid)
	HOST=$(json_str server)
	PORT=$(json_num server_port)
	PBK=$(json_str public_key)
	SID=$(json_str short_id)
	SNI=$(json_str server_name)
	FP=$(json_str fingerprint)
	FLOW=$(json_str flow)
}

FIRST=$(head -c 8 "${XRAY_CONFIG}")
case "${FIRST}" in
vless://*)
	parse_share_url
	;;
'{'*|$'\n'*|' '*)
	## A ready-made xray config goes in as it is: it already describes its own
	## inbounds, and second-guessing them here would only mean two owners.
	if grep -q '"inbounds"' "${XRAY_CONFIG}"; then
		create_dir ${XRAY_DIR}
		copy_file "${XRAY_CONFIG}" "${XRAY_CONF}"
		[[ -f "${XRAY_CONF}" ]] || fail "could not install ${XRAY_CONFIG} as ${XRAY_CONF}"
		set_chmod 0644 ${XRAY_CONF}
		if ! grep -q "\"port\"[[:space:]]*:[[:space:]]*${TPROXY_PORT}" "${XRAY_CONF}"; then
			fail "${XRAY_CONFIG} is a full xray config but has no inbound on port ${TPROXY_PORT}," \
				"so xraypolicy would TPROXY the LAN into nothing"
		fi
		## Same argument for the other two loopback inbounds this image depends on:
		## step 6 points dnsmasq at DNS_ADDR and xray-health probes PROBE_PORT, and
		## both of those are silent failures - a LAN that resolves nothing, and a
		## health check that restarts xray forever because its probe never had
		## anywhere to go.
		if ! grep -q "\"${DNS_ADDR}\"" "${XRAY_CONF}"; then
			fail "${XRAY_CONFIG} is a full xray config but has no inbound on ${DNS_ADDR}," \
				"which is where the LAN resolvers are pointed - give it a dokodemo-door" \
				"inbound on ${DNS_ADDR}:53 forwarding to ${DNS_UPSTREAM}:53"
		fi
		if ! grep -q "\"port\"[[:space:]]*:[[:space:]]*${PROBE_PORT}" "${XRAY_CONF}"; then
			fail "${XRAY_CONFIG} is a full xray config but has no inbound on port ${PROBE_PORT}," \
				"which is what xray-health probes - give it a dokodemo-door inbound on" \
				"127.0.0.1:${PROBE_PORT} forwarding to 1.1.1.1:80"
		fi
		## Warn, deliberately do NOT fail. A verbatim config is someone's considered
		## artefact and this build has no standing to veto what is in it - the three
		## checks above are different, because without those inbounds the image is
		## structurally broken (no LAN uplink, no DNS, a health check that
		## restart-loops xray forever). This one is a judgement call that belongs to
		## whoever wrote the config.
		##
		## It is still worth a banner, because it is the setting in an xray config
		## most likely to break real traffic while looking like someone else's fault.
		## destOverride replaces each connection's destination with the hostname
		## sniffed from the client, throwing away the address the client actually
		## dialled. Any peer handed a session-pinned address out of band - a media
		## relay, a sticky pool member - is silently reconnected to a different host
		## that holds no session for it. The victim gets a clean TCP and TLS
		## handshake and then silence, i.e. a network fault that is not one. That is
		## not hypothetical; see the comment above the generated config below for the
		## Arlo cameras this cost days on.
		##
		## Counted per block, not per file, because a config may have several
		## sniffing inbounds and only some of them routeOnly. Whitespace is stripped
		## first since a hand-written config is formatted however its author liked.
		## A block with "enabled": false would also trip this, which is why the
		## message states what was matched rather than asserting an effect.
		if ! grep -q "\"${TUN_IFACE}\"" "${XRAY_CONF}"; then
			print_yellow "WARNING: ${XRAY_CONFIG} has no tun inbound named ${TUN_IFACE}, so the"
			print_yellow "  box's own DNS keeps going out directly (and gets forged answers)."
		fi
		XRAY_FLAT=$(tr -d ' \t\n' < "${XRAY_CONF}")
		N_OVERRIDE=$(grep -o '"destOverride"' <<< "${XRAY_FLAT}" | wc -l)
		N_ROUTEONLY=$(grep -o '"routeOnly":true' <<< "${XRAY_FLAT}" | wc -l)
		if [[ ${N_OVERRIDE} -gt 0 ]] && [[ ${N_ROUTEONLY} -lt ${N_OVERRIDE} ]] \
			&& grep -q '"enabled":true' <<< "${XRAY_FLAT}"; then
			print_yellow "##############################################################"
			print_yellow "WARNING: sniffing destOverride without routeOnly"
			print_yellow "  ${XRAY_CONFIG}"
			print_yellow "  has ${N_OVERRIDE} \"destOverride\" block(s), ${N_ROUTEONLY} of them \"routeOnly\": true."
			print_yellow "  xray will REPLACE the destination of a sniffed connection with"
			print_yellow "  the hostname in its SNI/Host header and re-resolve it at the"
			print_yellow "  exit, discarding the address the client dialled. A peer that"
			print_yellow "  was given a session-pinned address out of band then lands on"
			print_yellow "  the wrong host and its connection dies after a successful"
			print_yellow "  handshake, which reads as a network fault and is not one."
			print_yellow "  Add \"routeOnly\": true to the sniffing block(s) unless every"
			print_yellow "  destination on this LAN is genuinely name-addressed."
			print_yellow "  Building anyway: this is your config, not the build's."
			print_yellow "##############################################################"
		fi
		## Same standing as the warning above: not the build's config to edit.
		if [[ -n "${KEEPALIVE_SOCKOPT}" ]]; then
			print_yellow "WARNING: XRAY_TCP_KEEPALIVE=${KEEPALIVE} is NOT applied to a verbatim config;"
			print_yellow "  put tcpKeepAliveIdle/tcpKeepAliveInterval in the outbound's sockopt yourself."
		fi
		print_green "INFO: installed ${XRAY_CONFIG} verbatim as /etc/xray/config.json"
		XRAY_VERBATIM=ON
	else
		parse_json
	fi
	;;
*)
	fail "unrecognised XRAY_CONFIG format: expected a vless:// share URL or JSON"
	;;
esac

#####################################################################
## 4. every field the outbound needs, or nothing
#####################################################################
if [[ "${XRAY_VERBATIM:-OFF}" != "ON" ]]; then
	for v in HOST PORT UUID PBK SID SNI FP FLOW; do
		## A silently dropped sid or flow does not fail at boot - it fails as a
		## plain connection timeout with nothing in the log.
		[[ -n "${!v}" ]] || fail "could not extract ${v} from ${XRAY_CONFIG}"
		sane_field "${v}" "${!v}"
	done
	[[ "${PORT}" =~ ^[0-9]+$ ]] || fail "port '${PORT}' from ${XRAY_CONFIG} is not a number"

	#####################################################################
	## 5. render the config
	#####################################################################
	## Three dokodemo-door inbounds: the TPROXY one the LAN's packets are handed
	## to, a DNS one on loopback for the LAN resolvers (see step 6), and the
	## health check's probe (see xray-health). The routing rules touch none of
	## them - the first outbound is the default, so everything that reaches those
	## goes into the tunnel, which is the requirement.
	##
	## Plus a TUN inbound, ${TUN_IFACE}, for the box's *own* DNS - the same
	## interface and addresses as the sing-box client on the laptop. xraypolicy
	## points systemd-resolved at its far end, ${TUN_DNS}, exclusively; port 53
	## there is redirected to ${DNS_UPSTREAM} and dialled through the proxy
	## (dialerProxy - freedom's redirect alone would dial it directly), anything
	## else that reaches the TUN is dropped. Only the /30 is routed into it, so
	## nothing else can. Without it the box resolves over plain UDP on wwan0 and
	## gets the carrier's forged answers: resolved's opportunistic DoT silently
	## downgrades, and strict DoT is no better, as 853 is not reliably reachable.
	##
	## The probe inbound is the only way to ask "is the tunnel actually working"
	## from a box with nothing but busybox on it: a connection to it is a real
	## connection through REALITY to a real server on the internet, so an HTTP
	## reply from 1.1.1.1:80 proves the whole path. Nothing else does - the
	## outbound has no health notion, xray's local sockets are accepted before it
	## dials anything, and the box's own traffic never goes through the tunnel.
	##
	## Sniffing is routeOnly, i.e. the sniffed hostname is available for routing
	## decisions but the destination stays the address the client actually dialled.
	##
	## It used to be a plain destOverride, on the reasoning that carrying hostnames
	## instead of IPs keeps SNI consistent with the request and makes the server's
	## DNS view authoritative. That reasoning does not hold here and the setting
	## broke real traffic:
	##
	##   - It is redundant. The LAN's DNS already resolves through the tunnel (step
	##     6 points the resolvers at dns-in), and a client that ignores the resolver
	##     and hardcodes its own is still TPROXY'd, so the exit's DNS view is
	##     already the one the LAN gets. Measured: answers are byte-identical
	##     resolved directly and through the tunnel.
	##   - It is actively wrong for any peer that is handed a session-pinned
	##     address out of band. destOverride throws that address away and reconnects
	##     to whatever the sniffed name resolves to *from the exit*, which for a
	##     pool of per-session servers is a different member that holds no session
	##     for this client. It answers a bare TLS probe perfectly and then closes on
	##     the real client, so it looks like a network fault and is not one.
	##
	## That is not hypothetical: Arlo cameras on the AP could never start a stream.
	## They are given a media relay IP in-band (no DNS query for it at all) and
	## upload to it over TCP/443; destOverride redirected them to a different
	## instance of the same relay pool and the upload was silently closed every
	## time. Demonstrated directly - dialling an IP with an unrelated SNI landed on
	## the SNI's host with destOverride on, and on the requested IP with routeOnly.
	##
	## sockopt.mark is the convention every TPROXY recipe carries. With this
	## PREROUTING-only rule set it is not load-bearing: Xray's own traffic is
	## locally generated, never enters PREROUTING and never gets fwmark 1. It is
	## here for the day someone adds OUTPUT interception, where the companion
	## "-m mark --mark 0xff -j RETURN" is what stops the proxy proxying itself.
	create_dir ${XRAY_DIR}
	cat > ${XRAY_CONF} <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "tproxy", "listen": "0.0.0.0", "port": ${TPROXY_PORT}, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy", "mark": 255 } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true } },
    { "tag": "dns-in", "listen": "${DNS_ADDR}", "port": 53, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "address": "${DNS_UPSTREAM}", "port": 53 } },
    { "tag": "probe", "listen": "127.0.0.1", "port": ${PROBE_PORT}, "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "address": "1.1.1.1", "port": 80 } },
    { "tag": "tun", "protocol": "tun",
      "settings": { "name": "${TUN_IFACE}", "mtu": 1400, "gateway": ["${TUN_ADDR}"] } }
  ],
  "outbounds": [
    { "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [ { "address": "${HOST}", "port": ${PORT},
        "users": [ { "id": "${UUID}", "encryption": "none", "flow": "${FLOW}" } ] } ] },
      "streamSettings": { ${KEEPALIVE_SOCKOPT} "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "${SNI}", "fingerprint": "${FP}",
          "publicKey": "${PBK}", "shortId": "${SID}" } } },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "tun-dns", "protocol": "freedom", "settings": { "redirect": "${DNS_UPSTREAM}:53" },
      "streamSettings": { "sockopt": { "dialerProxy": "proxy" } } },
    { "tag": "tun-drop", "protocol": "blackhole" }
  ],
  "routing": { "rules": [
    { "inboundTag": ["tun"], "port": "53", "outboundTag": "tun-dns" },
    { "inboundTag": ["tun"], "outboundTag": "tun-drop" }
  ] }
}
EOF
	if [[ ! -f "${XRAY_CONF}" ]]; then
		fail "could not write ${XRAY_CONF}"
	fi
	set_chmod 0644 ${XRAY_CONF}
	## Deliberately no uuid/pbk/sid in the build log: it is kept and shared.
	print_green "INFO: /etc/xray/config.json generated for ${HOST}:${PORT} (sni=${SNI} fp=${FP} flow=${FLOW} keepalive=${KEEPALIVE})"
fi

#####################################################################
## 6. point the LAN resolvers at the DNS inbound
#####################################################################
## Without this the LAN leaks DNS: dnsmasq forwards to /etc/resolv.conf as
## locally generated traffic, which PREROUTING never sees, so queries go out
## around the tunnel. With it, they are ordinary local sockets to the dns-in
## inbound and get resolved from the server's side. The board's own lookups are
## step 7's.
##
## Indirectly, through a resolv-file, rather than a "server=" line naming the
## inbound, because the upstream has to follow the routing: with a hard-wired
## server= the LAN's DNS dies with xray while its traffic falls back to direct NAT,
## i.e. a fail-open path nobody can use. xraypolicy owns the file - the dns-in
## address while the tunnel is up, ${DNS_UPSTREAM} while it is down.
##
## dnsmasq re-reads a resolv-file at runtime (it polls it, and re-reads it on
## SIGHUP) but never re-reads its config file, which is why the upstream must be
## expressible as a plain "nameserver" line: no port, hence port 53 on an address
## of its own. no-resolv must not be here - it would turn this off.
for f in ${DNSMASQ_CONFS}; do
	[[ -f "${TARGET_DIR}/${f}" ]] || continue
	echo "resolv-file=${RESOLV_FILE}" >> ${TARGET_DIR}/${f}
	print_green "INFO: ${f} resolves through ${RESOLV_FILE} (${DNS_ADDR}:53 while the tunnel is up)"
done


#####################################################################
## 7. the box's own resolver: systemd-resolved, never a nameserver directly
#####################################################################
## singtun0 only helps what asks systemd-resolved. NSS does ("resolve" is first
## in nsswitch.conf), but anything that reads /etc/resolv.conf itself - busybox
## nslookup, for one - would still go to 0002's nameserver over plain UDP. So
## /etc/resolv.conf points at resolved's stub instead, overriding 0002 (which
## rewrites it on every build, so an OFF build gets its nameserver back).
create_dir "$(dirname "${RESOLVED_DROPIN}")"
printf '# Generated by 0013-xray_client_service.sh: the down-state upstream.\n[Resolve]\nDNS=%s\n' \
	"${DNS_UPSTREAM}" > "${RESOLVED_DROPIN}"
printf '# Generated by 0013-xray_client_service.sh: systemd-resolved, which\n# xraypolicy points through the tunnel (singtun0) while it is up.\nnameserver 127.0.0.53\n' \
	> "${TARGET_DIR}/etc/resolv.conf"
print_green "INFO: /etc/resolv.conf -> 127.0.0.53, resolved's direct upstream ${DNS_UPSTREAM}"

exit 0
