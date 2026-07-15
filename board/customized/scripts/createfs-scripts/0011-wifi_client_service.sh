#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

FULL_PATH="${TARGET_DIR}/etc/systemd/system/multi-user.target.wants"

## start
sed -i -E "s/export WIFI_CLIENT=.*/export WIFI_CLIENT=${WIFI_CLIENT}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "WIFI_CLIENT=${WIFI_CLIENT}"

if [[ ! -z "${WIFI_CLIENT_WLAN_NAME}" ]]; then
	sed -i -E "s/export WIFI_CLIENT_WLAN_NAME=.*/export WIFI_CLIENT_WLAN_NAME=${WIFI_CLIENT_WLAN_NAME}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
	if ! grep -q "WIFI_CLIENT_WLAN_NAME" ${TARGET_DIR}/${SYSTEM_VARS_FILE}; then
		echo "export WIFI_CLIENT_WLAN_NAME=${WIFI_CLIENT_WLAN_NAME}" >> ${TARGET_DIR}/${SYSTEM_VARS_FILE}
	fi
	print_green "WIFI_CLIENT_WLAN_NAME=${WIFI_CLIENT_WLAN_NAME}"
fi

if [[ ! -z "${WIFI_AP_WLAN_NAME}" ]]; then
	sed -i -E "s/export WIFI_AP_WLAN_NAME=.*/export WIFI_AP_WLAN_NAME=${WIFI_AP_WLAN_NAME}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
	if ! grep -q "WIFI_AP_WLAN_NAME" ${TARGET_DIR}/${SYSTEM_VARS_FILE}; then
		echo "export WIFI_AP_WLAN_NAME=${WIFI_AP_WLAN_NAME}" >> ${TARGET_DIR}/${SYSTEM_VARS_FILE}
	fi
	print_green "WIFI_AP_WLAN_NAME=${WIFI_AP_WLAN_NAME}"
fi

## enable wlan1 services if WIFI_CLIENT=ON
if [[ "${WIFI_CLIENT}" == "ON" ]]; then
	create_dir ${FULL_PATH}
	create_link "../wpa_supplicant_wlan1.service" "${FULL_PATH}/wpa_supplicant_wlan1.service"
	create_link "../dhclient_wlan1.service" "${FULL_PATH}/dhclient_wlan1.service"
	print_green "INFO: wlan1 client services enabled"
fi

## patch wpa_supplicant_wlan1.conf with SSID and PSK
WPA_CONF="${TARGET_DIR}/etc/wpa_supplicant_wlan1.conf"
if [[ -f "${WPA_CONF}" ]] && [[ ! -z "${WLAN_SSID}" ]]; then
	sed -i -E "s/ssid=\".*\"/ssid=\"${WLAN_SSID}\"/g" ${WPA_CONF}
	print_green "WLAN_SSID=${WLAN_SSID}"
	sed -i -E "s/psk=\".*\"/psk=\"${WLAN_PSK}\"/g" ${WPA_CONF}
	print_green "WLAN_PSK=${WLAN_PSK}"
fi

## patch hostapd.conf interface with WIFI_AP_WLAN_NAME
HOSTAPD_CONF="${TARGET_DIR}/etc/hostapd.conf"
if [[ -f "${HOSTAPD_CONF}" ]] && [[ ! -z "${WIFI_AP_WLAN_NAME}" ]]; then
	sed -i -E "s/^interface=.*/interface=${WIFI_AP_WLAN_NAME}/g" ${HOSTAPD_CONF}
	print_green "hostapd interface=${WIFI_AP_WLAN_NAME}"
fi

exit 0
