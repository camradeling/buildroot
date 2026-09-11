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
## Deliberately not 5353. That is the mDNS port, systemd-resolved is enabled in
## this image and binds 0.0.0.0:5353 for its mDNS stub, and xray treats a failed
## inbound bind as fatal: "Failed to start: listen udp 127.0.0.1:5353: bind:
## address already in use", then the unit restart-loops forever. Measured on the
## board; the LAN had no uplink at all because of a port number.
DNS_PORT=${XRAY_DNS_PORT:-5300}
LAN_IFACES=${XRAY_LAN_IFACES:-usb0 wlan0}
KILLSWITCH=${XRAY_KILLSWITCH:-OFF}

## The LAN resolvers. Both files are re-copied from their overlays on every build,
## so appending to them here is not cumulative - but the lines are stripped first
## anyway, because an image built with XRAY_CLIENT=OFF must not keep a
## server=127.0.0.1#5353 pointing at a daemon that is not there.
DNSMASQ_CONFS="etc/dnsmasq_usb0.conf etc/dnsmasq_wlan0.conf"

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
	sed -i -E "/^server=127\.0\.0\.1#/d;/^no-resolv\$/d" ${TARGET_DIR}/${f}
done

#####################################################################
## 2. record the state the target can introspect, then gate
#####################################################################
## Only these go into /etc/system.vars: XRAY_CLIENT because that is what
## after-preset-check.sh reads, and the other three because xraypolicy needs them
## at runtime and must not be able to disagree with the config.json generated
## here. XRAY_CONFIG never does - it is a path on the build host - and no
## credential from it does either. The keys have to pre-exist in the system_v2
## overlay copy for these seds to have something to replace.
sed -i -E "s|export XRAY_CLIENT=.*|export XRAY_CLIENT=${XRAY_CLIENT:-OFF}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
sed -i -E "s|export XRAY_TPROXY_PORT=.*|export XRAY_TPROXY_PORT=${TPROXY_PORT}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
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

## systemd-resolved is enabled in this image and its mDNS stub owns 0.0.0.0:5353,
## so a DNS inbound there is a service that restart-loops forever on a bind error.
## Refuse the value instead of shipping that; if resolved is ever dropped from the
## defconfig this check is the thing to delete.
if [[ "${DNS_PORT}" == "5353" ]]; then
	fail "XRAY_DNS_PORT=5353 collides with systemd-resolved's mDNS stub (0.0.0.0:5353)," \
		"which makes xray exit on 'bind: address already in use' - use 5300"
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
	## Two dokodemo-door inbounds: the TPROXY one the LAN's packets are handed
	## to, and a DNS one on loopback for the LAN resolvers (see step 6). No
	## routing rules on purpose - the first outbound is the default, so
	## everything that reaches an inbound goes into the tunnel, which is the
	## requirement.
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
    { "tag": "dns-in", "listen": "127.0.0.1", "port": ${DNS_PORT}, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "address": "1.1.1.1", "port": 53 } }
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
## go to 1.1.1.1 directly, which is what lets Xray resolve its server address
## before a tunnel exists.
for f in ${DNSMASQ_CONFS}; do
	[[ -f "${TARGET_DIR}/${f}" ]] || continue
	echo "no-resolv" >> ${TARGET_DIR}/${f}
	echo "server=127.0.0.1#${DNS_PORT}" >> ${TARGET_DIR}/${f}
	print_green "INFO: ${f} resolves through 127.0.0.1#${DNS_PORT}"
done

exit 0
