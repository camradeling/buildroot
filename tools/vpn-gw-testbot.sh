#!/bin/sh
# Let OpenVPN peers of tokyoserv use this box as their internet gateway.
#
#   peer (CLIENT_IP in vpn-gw-tokyoserv.env) -> tokyoserv tun0 -> tun9 on this box
#     -> forwarded out ${OUT_IF} (the Quectel LTE uplink), masqueraded
#
# The server half (policy rule + iroute for this box's CN) is
# tools/vpn-gw-tokyoserv.sh, run on tokyoserv. This half only opens the path:
# forwarding tun9 <-> uplink, NAT, and MSS clamping (tun9 rides OpenVPN inside
# VLESS, the path MTU is well under 1500).
#
# Not persistent: the rules are gone after a reboot. Run "on" again.
#
# Usage: vpn-gw-testbot.sh on|off|status
#
# Site values live in vpn-gw-testbot.env next to this script, or in
# $VPN_GW_ENV. That file is not in git: copy vpn-gw-testbot.env.template.

ENV_FILE="${VPN_GW_ENV:-$(dirname "$(readlink -f "$0")")/vpn-gw-testbot.env}"
if [ -f "${ENV_FILE}" ]; then
	. "${ENV_FILE}"
else
	echo "$0: ${ENV_FILE} missing - copy vpn-gw-testbot.env.template and fill it in" >&2
	exit 2
fi
if [ -z "${VPN_NET:-}" ]; then
	echo "$0: VPN_NET is not set in ${ENV_FILE}" >&2
	exit 2
fi

VPN_IF="${VPN_IF:-tun9}"
OUT_IF="${OUT_IF:-wwan0}"

# One line per rule: "<table> <chain> <match...>". Order matters only for display.
rules() {
	cat <<EOF
filter FORWARD -s ${VPN_NET} -i ${VPN_IF} -o ${OUT_IF} -j ACCEPT
filter FORWARD -d ${VPN_NET} -i ${OUT_IF} -o ${VPN_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
mangle FORWARD -i ${VPN_IF} -o ${OUT_IF} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
mangle FORWARD -i ${OUT_IF} -o ${VPN_IF} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
nat POSTROUTING -s ${VPN_NET} -o ${OUT_IF} -j MASQUERADE
EOF
}

rules_on() {
	rules | while read -r table chain spec; do
		# shellcheck disable=SC2086
		iptables -t "${table}" -C "${chain}" ${spec} 2>/dev/null ||
			iptables -t "${table}" -A "${chain}" ${spec}
	done
}

rules_off() {
	rules | while read -r table chain spec; do
		# shellcheck disable=SC2086
		while iptables -t "${table}" -D "${chain}" ${spec} 2>/dev/null; do :; done
	done
}

status() {
	n=0; t=0
	rules | {
		while read -r table chain spec; do
			t=$((t + 1))
			# shellcheck disable=SC2086
			if iptables -t "${table}" -C "${chain}" ${spec} 2>/dev/null; then
				n=$((n + 1)); echo "  [on ] ${table} ${chain} ${spec}"
			else
				echo "  [off] ${table} ${chain} ${spec}"
			fi
		done
		echo "rules: ${n}/${t} present"
	}
	echo "ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
	echo "${VPN_IF}: $(ip -br addr show "${VPN_IF}" 2>/dev/null || echo missing)"
	echo "uplink:  $(ip route show default dev "${OUT_IF}" 2>/dev/null | head -1)"
}

case "${1:-status}" in
on)
	ip link show "${OUT_IF}" >/dev/null 2>&1 || echo "warning: ${OUT_IF} is not up, rules added anyway" >&2
	echo 1 > /proc/sys/net/ipv4/ip_forward
	rules_on
	logger -t vpn-gw "on: ${VPN_NET} via ${VPN_IF} -> ${OUT_IF}"
	status
	;;
off)
	rules_off
	logger -t vpn-gw "off"
	status
	;;
status)
	status
	;;
*)
	echo "usage: $0 on|off|status" >&2
	exit 2
	;;
esac
