#!/bin/sh
# On tokyoserv: send one OpenVPN client's internet traffic through another
# client (the testbot) instead of out eth0.
#
#   client CLIENT_IP -> tun0 -> ip rule "from CLIENT_IP iif tun0"
#     -> table TABLE: default via GW_IP dev tun0 -> testbot (its tun9 address)
#
# Two pieces, because the server runs without DCO and OpenVPN itself picks the
# client for every packet the kernel hands to tun0:
#   1. kernel policy routing (ip rule + table), toggled here instantly
#   2. iroute 0/1 + 128/1 in ccd/GW_CN, so OpenVPN hands those packets to the
#      testbot and accepts the internet-sourced replies coming back from it.
#      ccd is read only when a client connects: after on/off, the testbot's
#      OpenVPN must reconnect (systemctl restart icmpvpn-openvpn on the box).
#
# The testbot half is tools/vpn-gw-testbot.sh (forwarding + NAT to its uplink).
# If the testbot is offline while this is on, CLIENT_IP has no internet.
#
# Not persistent across a server reboot (the ip rule is); the ccd lines are.
#
# Usage: vpn-gw-tokyoserv.sh on|off|status
#
# Site values (client addresses, the testbot's CN, server paths) live in
# vpn-gw-tokyoserv.env next to this script, or in $VPN_GW_ENV. That file is not
# in git: copy vpn-gw-tokyoserv.env.template and fill it in.

ENV_FILE="${VPN_GW_ENV:-$(dirname "$(readlink -f "$0")")/vpn-gw-tokyoserv.env}"
if [ -f "${ENV_FILE}" ]; then
	. "${ENV_FILE}"
else
	echo "$0: ${ENV_FILE} missing - copy vpn-gw-tokyoserv.env.template and fill it in" >&2
	exit 2
fi
need() {
	for _v in "$@"; do
		eval "[ -n \"\${${_v}:-}\" ]" || { echo "$0: ${_v} is not set in ${ENV_FILE}" >&2; exit 2; }
	done
}
need CLIENT_IP OTHER_IP GW_IP GW_CN VPN_NET CCD_DIR STATUS_LOG

DEV="${DEV:-tun0}"
TABLE="${TABLE:-1254}"
PREF="${PREF:-1254}"
CCD="${CCD_DIR}/${GW_CN}"
MARK="# vpn-gw-tokyoserv"

ccd_on() {
	grep -q "${MARK}" "${CCD}" 2>/dev/null && return
	cat >> "${CCD}" <<EOF
iroute 0.0.0.0 128.0.0.0 ${MARK}
iroute 128.0.0.0 128.0.0.0 ${MARK}
EOF
	chmod 644 "${CCD}"
}

ccd_off() {
	[ -f "${CCD}" ] || return
	sed -i "/${MARK}/d" "${CCD}"
	[ -s "${CCD}" ] || rm -f "${CCD}"
}

routes_on() {
	ip route replace "${VPN_NET}" dev "${DEV}" table "${TABLE}"
	ip route replace default via "${GW_IP}" dev "${DEV}" onlink table "${TABLE}"
	ip rule show pref "${PREF}" | grep -q . ||
		ip rule add pref "${PREF}" from "${CLIENT_IP}" iif "${DEV}" lookup "${TABLE}"
}

routes_off() {
	while ip rule del pref "${PREF}" 2>/dev/null; do :; done
	ip route flush table "${TABLE}" 2>/dev/null
}

status() {
	echo "rule:  $(ip rule show pref "${PREF}" | head -1)"
	echo "table: $(ip route show table "${TABLE}" 2>/dev/null | tr '\n' ';')"
	echo "ccd ${CCD}:"
	grep "${MARK}" "${CCD}" 2>/dev/null | sed 's/^/  /' || echo "  (no iroute)"
	## CLIENT_IP must go via GW_IP, every other client must still go out eth0
	echo "path ${CLIENT_IP}: $(ip route get 1.1.1.1 from "${CLIENT_IP}" iif "${DEV}" 2>&1 | head -1)"
	echo "path ${OTHER_IP} (any other client): $(ip route get 1.1.1.1 from "${OTHER_IP}" iif "${DEV}" 2>&1 | head -1)"
	if grep -q "^${GW_CN}," "${STATUS_LOG}" 2>/dev/null; then
		echo "gw:    ${GW_CN} connected"
	else
		echo "gw:    ${GW_CN} NOT connected"
	fi
}

case "${1:-status}" in
on)
	ccd_on
	routes_on
	logger -t vpn-gw "on: ${CLIENT_IP} -> ${GW_IP} (${GW_CN})"
	status
	echo "reconnect ${GW_CN} for the iroute to apply"
	;;
off)
	routes_off
	ccd_off
	logger -t vpn-gw "off: ${CLIENT_IP} back to eth0"
	status
	echo "reconnect ${GW_CN} to drop the iroute"
	;;
status)
	status
	;;
*)
	echo "usage: $0 on|off|status" >&2
	exit 2
	;;
esac
