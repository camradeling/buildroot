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
## The health check's probe inbound (see xray-health). Loopback only.
PROBE_PORT=${XRAY_PROBE_PORT:-5301}
LAN_IFACES=${XRAY_LAN_IFACES:-usb0 wlan0}
KILLSWITCH=${XRAY_KILLSWITCH:-OFF}

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
	## health check's probe (see xray-health). No routing rules on purpose - the
	## first outbound is the default, so everything that reaches an inbound goes
	## into the tunnel, which is the requirement.
	##
	## The probe inbound is the only way to ask "is the tunnel actually working"
	## from a box with nothing but busybox on it: a connection to it is a real
	## connection through REALITY to a real server on the internet, so an HTTP
	## reply from 1.1.1.1:80 proves the whole path. Nothing else does - the
	## outbound has no health notion, xray's local sockets are accepted before it
	## dials anything, and the box's own traffic never goes through the tunnel.
	##
	## Sniffing with destOverride makes the tunnel carry hostnames instead of the
	## IP the client resolved, which keeps SNI consistent with the request and
	## makes the server's DNS view the authoritative one.
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
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] } },
    { "tag": "dns-in", "listen": "${DNS_ADDR}", "port": 53, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "address": "${DNS_UPSTREAM}", "port": 53 } },
    { "tag": "probe", "listen": "127.0.0.1", "port": ${PROBE_PORT}, "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "address": "1.1.1.1", "port": 80 } }
  ],
  "outbounds": [
    { "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [ { "address": "${HOST}", "port": ${PORT},
        "users": [ { "id": "${UUID}", "encryption": "none", "flow": "${FLOW}" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "${SNI}", "fingerprint": "${FP}",
          "publicKey": "${PBK}", "shortId": "${SID}" } } },
    { "tag": "direct", "protocol": "freedom" }
  ]
}
EOF
	if [[ ! -f "${XRAY_CONF}" ]]; then
		fail "could not write ${XRAY_CONF}"
	fi
	set_chmod 0644 ${XRAY_CONF}
	## Deliberately no uuid/pbk/sid in the build log: it is kept and shared.
	print_green "INFO: /etc/xray/config.json generated for ${HOST}:${PORT} (sni=${SNI} fp=${FP} flow=${FLOW})"
fi

#####################################################################
## 6. point the LAN resolvers at the DNS inbound
#####################################################################
## Without this the LAN leaks DNS: dnsmasq forwards to /etc/resolv.conf as
## locally generated traffic, which PREROUTING never sees, so queries go out
## around the tunnel. With it, they are ordinary local sockets to the dns-in
## inbound and get resolved from the server's side. The board's own lookups still
## go to /etc/resolv.conf directly, which is what lets Xray resolve its server
## address before a tunnel exists.
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

exit 0
