#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

## /etc/wireguard/wg0.conf is both the config and the switch: wg-client.service
## and wg-health.timer carry ConditionPathExists= on it, because preset-all enables
## them after this script has run (see CLAUDE.md, "Optional services").
WG_DIR="${TARGET_DIR}/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
## The LAN resolvers' upstream while WG_LAN_ROUTE=ON. Static: the query goes to
## the same address on either path, and wgpolicy's "to WG_DNS lookup 200" rule is
## what decides which path that is.
WG_RESOLV="/etc/wireguard/dns.conf"
DNSMASQ_CONFS="etc/dnsmasq_usb0.conf etc/dnsmasq_wlan0.conf"

LAN_ROUTE=${WG_LAN_ROUTE:-OFF}
LAN_IFACES=${WG_LAN_IFACES:-usb0 wlan0}
PROBE_ADDR=${WG_PROBE_ADDR:-1.1.1.1}
## Seconds between keepalives, OFF for none. The vars file wins over the
## config's PersistentKeepalive: how long the carrier keeps an idle UDP flow is a
## property of this board's uplink, not of the server's client profile.
KEEPALIVE=${WG_KEEPALIVE:-25}

fail()
{
	print_red "ERROR: $*"
	exit 1
}

is_ipv4()
{
	[[ "${1}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	local o
	for o in "${BASH_REMATCH[@]:1}"; do
		[[ ${o} -le 255 ]] || return 1
	done
}

set_var()
{
	sed -i -E "s|export ${1}=.*|export ${1}=${2}|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
}

#####################################################################
## 1. clean up unconditionally
#####################################################################
## output/target/ is not wiped between builds, so without this a config from a
## WG_CLIENT=ON build survives into an OFF one and re-enables the feature.
delete_file_silent ${WG_CONF}
delete_file_silent ${TARGET_DIR}${WG_RESOLV}
for f in ${DNSMASQ_CONFS}; do
	[[ -f "${TARGET_DIR}/${f}" ]] || continue
	sed -i -E "\|^resolv-file=${WG_RESOLV}\$|d" ${TARGET_DIR}/${f}
done

set_var WG_CLIENT "${WG_CLIENT:-OFF}"
print_green "WG_CLIENT=${WG_CLIENT:-OFF}"

if [[ -z "${WG_CLIENT}" ]] || [[ "${WG_CLIENT}" == "OFF" ]]; then
	print_green "INFO: WG_CLIENT is OFF, no wg0.conf in the image"
	exit 0
elif [[ "${WG_CLIENT}" != "ON" ]]; then
	fail "WG_CLIENT=${WG_CLIENT}, only ON or OFF"
fi

[[ "${LAN_ROUTE}" == "ON" || "${LAN_ROUTE}" == "OFF" ]] || fail "WG_LAN_ROUTE=${LAN_ROUTE}, only ON or OFF"
## Xray TPROXYs the LAN in mangle PREROUTING, before any routing decision, so
## with both on the LAN would never reach wg0's rules at all - and the two would
## fight over the dnsmasq upstream. One owner of the LAN's way out.
if [[ "${LAN_ROUTE}" == "ON" ]] && [[ "${XRAY_CLIENT:-OFF}" == "ON" ]]; then
	fail "WG_LAN_ROUTE=ON and XRAY_CLIENT=ON: both want to be the LAN's uplink." \
		"Set XRAY_CLIENT=OFF, or WG_LAN_ROUTE=OFF to only bring wg0 up"
fi
is_ipv4 "${PROBE_ADDR}" || fail "WG_PROBE_ADDR=${PROBE_ADDR} is not an IPv4 address"
if [[ "${KEEPALIVE}" != "OFF" ]]; then
	[[ "${KEEPALIVE}" =~ ^[0-9]+$ ]] && [[ ${KEEPALIVE} -ge 1 ]] && [[ ${KEEPALIVE} -le 65535 ]] \
		|| fail "WG_KEEPALIVE=${KEEPALIVE}, only OFF or 1..65535 seconds"
fi

if [[ -z "${WG_CONFIG}" ]]; then
	fail "WG_CLIENT is ON but WG_CONFIG is not set"
elif [[ ! -r "${WG_CONFIG}" ]]; then
	fail "WG_CONFIG=${WG_CONFIG}: not found or not readable by $(id -un)"
fi

#####################################################################
## 2. split a wg-quick config into wg(8) fields and interface settings
#####################################################################
## wg setconf rejects the wg-quick-only keys (Address, DNS, MTU, ...), so they are
## taken out here and handed to wgpolicy through system.vars. Anything this
## script does not understand fails the build: a silently ignored PostUp= or
## Table= is a config that does something different on the board than on the
## machine it was written for.
ADDRESS="" DNS="" MTU="" ENDPOINT="" SECTION="" NPEERS=0 HAVE_KEY=0 DEFAULT_ROUTE=0
OUT=""

while IFS= read -r line || [[ -n "${line}" ]]; do
	line=${line%%#*}
	line=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "${line//$'\r'/}")
	[[ -n "${line}" ]] || continue

	case "${line,,}" in
	'[interface]')
		SECTION=interface
		OUT+="[Interface]"$'\n'
		continue
		;;
	'[peer]')
		SECTION=peer
		NPEERS=$(( NPEERS + 1 ))
		OUT+=$'\n'"[Peer]"$'\n'
		continue
		;;
	esac

	[[ "${line}" == *=* ]] || fail "WG_CONFIG: cannot parse line '${line%%=*}...'"
	key=$(sed -E 's/[[:space:]]*$//' <<< "${line%%=*}")
	val=$(sed -E 's/^[[:space:]]*//' <<< "${line#*=}")

	case "${SECTION}:${key,,}" in
	interface:privatekey)
		HAVE_KEY=1
		OUT+="PrivateKey = ${val}"$'\n'
		;;
	interface:listenport|interface:fwmark)
		OUT+="${key} = ${val}"$'\n'
		;;
	interface:address)
		## The first IPv4 address; IPv6 is a module on this kernel and the
		## LAN is IPv4-only, so v6 addresses are dropped with a note.
		for a in ${val//,/ }; do
			if [[ -z "${ADDRESS}" ]] && is_ipv4 "${a%/*}"; then
				ADDRESS=${a}
				[[ "${ADDRESS}" == */* ]] || ADDRESS="${ADDRESS}/32"
			elif ! is_ipv4 "${a%/*}"; then
				print_yellow "INFO: WG_CONFIG: ignoring non-IPv4 address ${a}"
			fi
		done
		;;
	interface:dns)
		for a in ${val//,/ }; do
			if [[ -z "${DNS}" ]] && is_ipv4 "${a}"; then
				DNS=${a}
			fi
		done
		;;
	interface:mtu)
		MTU=${val}
		;;
	peer:publickey|peer:presharedkey|peer:allowedips)
		OUT+="${key} = ${val}"$'\n'
		if [[ "${key,,}" == "allowedips" ]] && [[ "${val}" =~ (^|[ ,])0\.0\.0\.0/0($|[ ,]) ]]; then
			DEFAULT_ROUTE=1
		fi
		;;
	peer:endpoint)
		## An IP literal only. wg setconf resolves a hostname once, at boot,
		## through the board's own resolver - i.e. over wwan0, where this
		## carrier forges DNS answers - and before the modem has a lease.
		is_ipv4 "${val%:*}" && [[ "${val##*:}" =~ ^[0-9]+$ ]] \
			|| fail "WG_CONFIG: Endpoint must be <IPv4>:<port>, not a hostname"
		[[ -n "${ENDPOINT}" ]] || ENDPOINT=${val%:*}
		OUT+="Endpoint = ${val}"$'\n'
		;;
	peer:persistentkeepalive)
		## replaced by WG_KEEPALIVE below
		;;
	*)
		fail "WG_CONFIG: '${key}' in [${SECTION:-no section}] is not supported by this image"
		;;
	esac

	## The keepalive goes right after each peer's PublicKey so every peer gets one.
	if [[ "${SECTION}:${key,,}" == "peer:publickey" ]] && [[ "${KEEPALIVE}" != "OFF" ]]; then
		OUT+="PersistentKeepalive = ${KEEPALIVE}"$'\n'
	fi
done < "${WG_CONFIG}"

[[ ${HAVE_KEY} -eq 1 ]] || fail "WG_CONFIG has no [Interface] PrivateKey"
[[ ${NPEERS} -ge 1 ]] || fail "WG_CONFIG has no [Peer]"
[[ -n "${ENDPOINT}" ]] || fail "WG_CONFIG has no peer with an Endpoint - this is a client, it has to dial out"
[[ -n "${ADDRESS}" ]] || fail "WG_CONFIG has no IPv4 Address"
[[ "${ADDRESS##*/}" =~ ^[0-9]+$ ]] && [[ ${ADDRESS##*/} -le 32 ]] || fail "WG_CONFIG: bad Address prefix in ${ADDRESS}"
[[ "${LAN_IFACES}" =~ ^[A-Za-z0-9._\ -]+$ ]] || fail "WG_LAN_IFACES='${LAN_IFACES}' is not a list of interface names"
MTU=${WG_MTU:-${MTU:-1420}}
[[ "${MTU}" =~ ^[0-9]+$ ]] && [[ ${MTU} -ge 1280 ]] && [[ ${MTU} -le 1500 ]] \
	|| fail "WireGuard MTU ${MTU}, only 1280..1500"
DNS=${WG_DNS:-${DNS:-1.1.1.1}}
is_ipv4 "${DNS}" || fail "WG_DNS=${DNS} is not an IPv4 address"
## Cryptokey routing drops anything not in AllowedIPs, so a LAN routed into a
## peer that only allows its own subnet is a blackhole with a working handshake.
if [[ "${LAN_ROUTE}" == "ON" ]] && [[ ${DEFAULT_ROUTE} -eq 0 ]]; then
	fail "WG_LAN_ROUTE=ON but no peer has AllowedIPs 0.0.0.0/0, so wg0 would drop the LAN's traffic"
fi

#####################################################################
## 3. install
#####################################################################
create_dir ${WG_DIR}
printf '%s' "${OUT}" > ${WG_CONF}
[[ -s "${WG_CONF}" ]] || fail "could not write ${WG_CONF}"
## It holds the private key.
set_chmod 0600 ${WG_CONF}

set_var WG_ADDRESS "${ADDRESS}"
set_var WG_MTU "${MTU}"
set_var WG_DNS "${DNS}"
set_var WG_ENDPOINT "${ENDPOINT}"
set_var WG_PROBE_ADDR "${PROBE_ADDR}"
set_var WG_LAN_ROUTE "${LAN_ROUTE}"
set_var WG_LAN_IFACES "\"${LAN_IFACES}\""

## Deliberately no key material in the build log.
print_green "INFO: /etc/wireguard/wg0.conf generated: ${ADDRESS} -> ${ENDPOINT}, ${NPEERS} peer(s)," \
	"mtu ${MTU}, keepalive ${KEEPALIVE}, LAN route ${LAN_ROUTE}"

#####################################################################
## 4. the LAN resolvers, when the LAN goes through the tunnel
#####################################################################
## dnsmasq otherwise forwards to /etc/resolv.conf, which on this board may hold
## the carrier's resolvers from the modem lease - and those are answered, or
## forged, on the carrier's side whichever way the query is routed.
if [[ "${LAN_ROUTE}" == "ON" ]]; then
	printf '# Generated by 0014-wireguard_client_service.sh, read by dnsmasq (resolv-file=).\nnameserver %s\n' \
		"${DNS}" > ${TARGET_DIR}${WG_RESOLV}
	for f in ${DNSMASQ_CONFS}; do
		[[ -f "${TARGET_DIR}/${f}" ]] || continue
		sed -i -E '/^no-resolv$/d' ${TARGET_DIR}/${f}
		echo "resolv-file=${WG_RESOLV}" >> ${TARGET_DIR}/${f}
		print_green "INFO: ${f} resolves through ${DNS} (routed into wg0 while the tunnel is up)"
	done
fi

exit 0
