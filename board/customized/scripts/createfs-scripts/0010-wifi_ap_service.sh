#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

## start
sed -i -E "s/export WIFI_AP=.*/export WIFI_AP=${WIFI_AP}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP=${WIFI_AP}"
sed -i -E "s/export WIFI_AP_ADDR=.*/export WIFI_AP_ADDR=${WIFI_AP_ADDR}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP_ADDR=${WIFI_AP_ADDR}"
sed -i -E "s/export WIFI_AP_NETMASK=.*/export WIFI_AP_NETMASK=${WIFI_AP_NETMASK}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP_NETMASK=${WIFI_AP_NETMASK}"
sed -i -E "s/export WIFI_AP_WAN_IFACE=.*/export WIFI_AP_WAN_IFACE=${WIFI_AP_WAN_IFACE:-eth0}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_AP_WAN_IFACE=${WIFI_AP_WAN_IFACE:-eth0}"

## patch hostapd.conf with SSID, PSK and channel
HOSTAPD_CONF="${TARGET_DIR}/etc/hostapd.conf"
if [[ -f "${HOSTAPD_CONF}" ]] && [[ ! -z "${WIFI_AP_SSID}" ]]; then
	sed -i -E "s/^ssid=.*/ssid=${WIFI_AP_SSID}/g" ${HOSTAPD_CONF}
	print_green "WIFI_AP_SSID=${WIFI_AP_SSID}"
	sed -i -E "s/^wpa_passphrase=.*/wpa_passphrase=${WIFI_AP_PSK}/g" ${HOSTAPD_CONF}
	print_green "WIFI_AP_PSK=${WIFI_AP_PSK}"
	if [[ ! -z "${WIFI_AP_CHANNEL}" ]]; then
		sed -i -E "s/^channel=.*/channel=${WIFI_AP_CHANNEL}/g" ${HOSTAPD_CONF}
		if [[ ${WIFI_AP_CHANNEL} -gt 14 ]]; then
			sed -i -E '/^hw_mode=/d' ${HOSTAPD_CONF}
			sed -i -E "/^channel=/a hw_mode=a" ${HOSTAPD_CONF}
		fi
		print_green "WIFI_AP_CHANNEL=${WIFI_AP_CHANNEL}"
	fi
	if [[ "${WIFI_AP_BSS_TRANSITION:-OFF}" == "ON" ]]; then
		sed -i -E "s/^bss_transition=.*/bss_transition=1/g" ${HOSTAPD_CONF}
		print_green "WIFI_AP_BSS_TRANSITION=ON"
	fi
fi

## patch dnsmasq.conf dhcp-range based on WIFI_AP_ADDR/WIFI_AP_NETMASK
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

exit 0
