#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

## Set key=value in hostapd.conf whether or not the key is already there. The
## previous "sed /^channel=/a" idiom only ever appended, so it silently did
## nothing when the key existed and left the key absent when the anchor moved.
set_hostapd_var()
{
	local _key=$1 _val=$2
	if grep -qE "^${_key}=" ${HOSTAPD_CONF}; then
		sed -i -E "s/^${_key}=.*/${_key}=${_val}/" ${HOSTAPD_CONF}
	else
		echo "${_key}=${_val}" >> ${HOSTAPD_CONF}
	fi
}

## start
sed -i -E "s/export WIFI_AP=.*/export WIFI_AP=${WIFI_AP}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP=${WIFI_AP}"
sed -i -E "s/export WIFI_AP_ADDR=.*/export WIFI_AP_ADDR=${WIFI_AP_ADDR}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP_ADDR=${WIFI_AP_ADDR}"
sed -i -E "s/export WIFI_AP_NETMASK=.*/export WIFI_AP_NETMASK=${WIFI_AP_NETMASK}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP_NETMASK=${WIFI_AP_NETMASK}"
## WIFI_AP_WAN_IFACE is retired: NAT is no longer keyed on a single uplink, it is
## keyed on the LAN subnet by netpolicy.service. Strip a leftover export from
## system.vars so nothing on the target can still read it.
sed -i -E "/^export WIFI_AP_WAN_IFACE=/d" ${TARGET_DIR}/${SYSTEM_VARS_FILE}

## Direct hosts (workplans/005, 006): "<mac>,<ip>[,<dscp>] ..." of AP clients
## whose traffic bypasses every tunnel - all of it, or with a DSCP field only the
## packets that carry that DSCP value (the rest of the host stays tunnelled).
## Validated and normalised here, before the WIFI_AP=OFF exit, so system.vars
## always says what the image does - an empty list with the AP off - and
## netpolicy never installs rules for a list nothing hands out.
DIRECT_HOSTS=""
if [[ "${WIFI_AP}" == "ON" ]] && [[ -n "${WIFI_AP_DIRECT_HOSTS:-}" ]]; then
	IFS='.' read -r a1 a2 a3 a4 <<< "${WIFI_AP_ADDR}"
	IFS='.' read -r m1 m2 m3 m4 <<< "${WIFI_AP_NETMASK}"
	for _host in ${WIFI_AP_DIRECT_HOSTS}; do
		_host=${_host,,}
		if [[ ! "${_host}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2},([0-9]{1,3}\.){3}[0-9]{1,3}(,[0-9]{1,2})?$ ]]; then
			print_red "ERROR: WIFI_AP_DIRECT_HOSTS entry '${_host}' is not <mac>,<ip>[,<dscp>]"
			exit 1
		fi
		IFS=',' read -r _mac _ip _dscp <<< "${_host}"
		## 0 is every unmarked packet, which would make the whole host direct
		## behind a field that says "only some of it"
		if [[ -n "${_dscp}" ]] && (( 10#${_dscp} < 1 || 10#${_dscp} > 63 )); then
			print_red "ERROR: WIFI_AP_DIRECT_HOSTS: DSCP ${_dscp} in '${_host}' is not 1..63"
			exit 1
		fi
		[[ -n "${_dscp}" ]] && _host="${_mac},${_ip},$((10#${_dscp}))"
		IFS='.' read -r i1 i2 i3 i4 <<< "${_ip}"
		if (( i1 > 255 || i2 > 255 || i3 > 255 || i4 > 255 )) ||
		   (( (i1 & m1) != (a1 & m1) || (i2 & m2) != (a2 & m2) ||
		      (i3 & m3) != (a3 & m3) || (i4 & m4) != (a4 & m4) )); then
			print_red "ERROR: WIFI_AP_DIRECT_HOSTS: ${_ip} is not in ${WIFI_AP_ADDR}/${WIFI_AP_NETMASK}"
			exit 1
		fi
		if [[ "${_ip}" == "${WIFI_AP_ADDR}" ]]; then
			print_red "ERROR: WIFI_AP_DIRECT_HOSTS: ${_ip} is the AP's own address"
			exit 1
		fi
		## One MAC, one IP, one list: a duplicate would give dnsmasq two
		## dhcp-host lines for the same client and leave it to pick one
		for _other in ${DIRECT_HOSTS} ${WIFI_AP_DHCP_HOSTS,,}; do
			IFS=',' read -r _omac _oip _ <<< "${_other}"
			if [[ "${_omac}" == "${_mac}" ]] || [[ "${_oip}" == "${_ip}" ]]; then
				print_red "ERROR: WIFI_AP_DIRECT_HOSTS: ${_host} collides with ${_other}" \
					"(already in WIFI_AP_DIRECT_HOSTS or WIFI_AP_DHCP_HOSTS)"
				exit 1
			fi
		done
		DIRECT_HOSTS="${DIRECT_HOSTS:+${DIRECT_HOSTS} }${_host}"
	done
fi
sed -i -E "s|export WIFI_AP_DIRECT_HOSTS=.*|export WIFI_AP_DIRECT_HOSTS=\"${DIRECT_HOSTS}\"|g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP_DIRECT_HOSTS=\"${DIRECT_HOSTS}\""

## hostapd.service and dnsmasq_wlan0.service are enabled by preset-all no matter
## what WIFI_AP says (preset-all runs after the post-build scripts), so the
## config files are the real switch - both units have ConditionPathExists on them
if [[ "${WIFI_AP}" != "ON" ]]; then
	delete_file_silent ${TARGET_DIR}/etc/hostapd.conf
	delete_file_silent ${TARGET_DIR}/etc/dnsmasq_wlan0.conf
	print_green "INFO: WIFI_AP is OFF, hostapd.conf and dnsmasq_wlan0.conf removed"
	exit 0
fi

## patch hostapd.conf with SSID, PSK and channel
HOSTAPD_CONF="${TARGET_DIR}/etc/hostapd.conf"
if [[ -f "${HOSTAPD_CONF}" ]] && [[ ! -z "${WIFI_AP_SSID}" ]]; then
	sed -i -E "s/^ssid=.*/ssid=${WIFI_AP_SSID}/g" ${HOSTAPD_CONF}
	print_green "WIFI_AP_SSID=${WIFI_AP_SSID}"
	## The PSK comes from the vars file (not in git, see build.sh),
	## and stays out of the build log.
	if [[ -z "${WIFI_AP_PSK}" ]]; then
		print_red "ERROR: WIFI_AP_PSK is not set - set it in the vars file"
		exit 1
	fi
	sed -i -E "s/^wpa_passphrase=.*/wpa_passphrase=${WIFI_AP_PSK}/g" ${HOSTAPD_CONF}
	print_green "WIFI_AP_PSK set (${#WIFI_AP_PSK} characters)"
	if [[ ! -z "${WIFI_AP_CHANNEL}" ]]; then
		sed -i -E "s/^channel=.*/channel=${WIFI_AP_CHANNEL}/g" ${HOSTAPD_CONF}
		if [[ ${WIFI_AP_CHANNEL} -gt 14 ]]; then
			HOSTAPD_HW_MODE=a
		else
			HOSTAPD_HW_MODE=g
		fi
		set_hostapd_var hw_mode "${HOSTAPD_HW_MODE}"
		print_green "WIFI_AP_CHANNEL=${WIFI_AP_CHANNEL} hw_mode=${HOSTAPD_HW_MODE}"
	fi
	## Assert, do not assume. A missing mode line fails nothing and logs nothing -
	## hostapd just falls back to hw_mode=b/ieee80211n=0 and advertises 11b rates.
	## Keep these unconditional so the advertised capabilities stay honest and the
	## config behaves the same on a driver that actually enforces them. Note this
	## did NOT change measured throughput on the H618 board, whose driver
	## negotiates HT MCS 7 either way; see the comment in hostapd.conf.
	set_hostapd_var ieee80211n 1
	set_hostapd_var wmm_enabled 1
	if [[ "${WIFI_AP_BSS_TRANSITION:-OFF}" == "ON" ]]; then
		sed -i -E "s/^bss_transition=.*/bss_transition=1/g" ${HOSTAPD_CONF}
		print_green "WIFI_AP_BSS_TRANSITION=ON"
	fi
fi

## patch dnsmasq_wlan0.conf dhcp-range based on WIFI_AP_ADDR/WIFI_AP_NETMASK
DNSMASQ_CONF="${TARGET_DIR}/etc/dnsmasq_wlan0.conf"
if [[ -f "${DNSMASQ_CONF}" ]] && [[ ! -z "${WIFI_AP_ADDR}" ]] && [[ ! -z "${WIFI_AP_NETMASK}" ]]; then
	IFS='.' read -r a1 a2 a3 a4 <<< "${WIFI_AP_ADDR}"
	IFS='.' read -r m1 m2 m3 m4 <<< "${WIFI_AP_NETMASK}"
	RANGE_START="$(( a1 & m1 )).$(( a2 & m2 )).$(( a3 & m3 )).$(( (a4 & m4) + 2 ))"
	RANGE_END="$(( (a1 & m1) | (255 - m1) )).$(( (a2 & m2) | (255 - m2) )).$(( (a3 & m3) | (255 - m3) )).$(( (a4 & m4) | (255 - m4) - 1 ))"
	sed -i -E "s|^listen-address=.*|listen-address=${WIFI_AP_ADDR}|g" ${DNSMASQ_CONF}
	sed -i -E "s|^dhcp-range=.*|dhcp-range=${RANGE_START},${RANGE_END},12h|g" ${DNSMASQ_CONF}
	print_green "dnsmasq listen-address=${WIFI_AP_ADDR} dhcp-range=${RANGE_START},${RANGE_END},12h"
fi

## Sticky client addresses (off unless a vars file asks). /var is on the tmpfs
## overlay, so the default lease file dies with each boot and a returning client
## can land on a different address; keep it on the data partition instead.
## dhcp-authoritative: dnsmasq is the only DHCP server on this segment, so it may
## grant a client the address it asks for even without a lease on record.
if [[ -f "${DNSMASQ_CONF}" ]] && [[ "${WIFI_AP_STICKY_LEASES:-OFF}" == "ON" ]]; then
	echo "dhcp-leasefile=/media/data/dnsmasq_wlan0.leases" >> ${DNSMASQ_CONF}
	echo "dhcp-authoritative" >> ${DNSMASQ_CONF}
	print_green "WIFI_AP_STICKY_LEASES=ON (leases on /media/data, authoritative)"
fi

## fixed addresses: WIFI_AP_DHCP_HOSTS="<mac>,<ip> [<mac>,<ip> ...]"
if [[ -f "${DNSMASQ_CONF}" ]] && [[ ! -z "${WIFI_AP_DHCP_HOSTS}" ]]; then
	for _host in ${WIFI_AP_DHCP_HOSTS}; do
		if [[ ! "${_host}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2},([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
			print_red "ERROR: WIFI_AP_DHCP_HOSTS entry '${_host}' is not <mac>,<ip>"
			exit 1
		fi
		echo "dhcp-host=${_host}" >> ${DNSMASQ_CONF}
		print_green "dnsmasq dhcp-host=${_host}"
	done
fi

## Direct hosts: a fixed address. Fully direct ones are tagged so that they - and
## only they - are told to resolve directly rather than through this dnsmasq,
## whose upstream is the tunnel. DSCP hosts are tunnelled apart from their marked
## packets, so they keep this dnsmasq (their lookups come from the system
## resolver, which does not carry the process's mark anyway). The routing half is
## netpolicy's (the DIRECT chain, keyed on MAC+IP[+DSCP]); after-preset-check.sh
## checks these lines against the list.
if [[ -f "${DNSMASQ_CONF}" ]] && [[ -n "${DIRECT_HOSTS}" ]]; then
	_full=0
	for _host in ${DIRECT_HOSTS}; do
		IFS=',' read -r _mac _ip _dscp <<< "${_host}"
		if [[ -n "${_dscp}" ]]; then
			echo "dhcp-host=${_mac},${_ip}" >> ${DNSMASQ_CONF}
			print_green "dnsmasq dhcp-host=${_mac},${_ip} (tunnelled, DSCP ${_dscp} goes direct)"
		else
			echo "dhcp-host=${_mac},set:direct,${_ip}" >> ${DNSMASQ_CONF}
			print_green "dnsmasq dhcp-host=${_mac},set:direct,${_ip} (direct, no tunnel)"
			_full=1
		fi
	done
	if (( _full )); then
		echo "dhcp-option=tag:direct,option:dns-server,${WIFI_AP_DIRECT_DNS:-1.1.1.1}" >> ${DNSMASQ_CONF}
		print_green "dnsmasq: direct hosts resolve through ${WIFI_AP_DIRECT_DNS:-1.1.1.1}"
	fi
fi

exit 0
