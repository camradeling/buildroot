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

## Both of these were removed from the overlay: wlan1-client-setup.sh when NAT
## moved to netpolicy.service, wlan1-fix-metric.sh when the default-route metrics
## moved to /etc/iface-metrics. Delete them explicitly: output/target/ is not
## wiped between builds and the overlay rsync has no --delete, so the old copies
## would keep shipping - and rc.local runs everything in /etc/scripts/*.sh, so a
## stale wlan1-fix-metric.sh would still be re-adding a metric-200 route by hand.
delete_file_silent ${TARGET_DIR}/etc/scripts/wlan1-client-setup.sh
delete_file_silent ${TARGET_DIR}/etc/scripts/wlan1-fix-metric.sh

## enable wlan1 services if WIFI_CLIENT=ON
##
## Removing the links is not enough to disable them: preset-all runs after the
## post-build scripts and recreates every link it finds an [Install] section for.
## wpa_supplicant_wlan1.service and dhclient_wlan1.service therefore carry
## ConditionPathExists=/etc/wpa_supplicant_wlan1.conf, and deleting that config
## is what actually keeps wlan1 from associating and installing a default route.
if [[ "${WIFI_CLIENT}" == "ON" ]]; then
	create_dir ${FULL_PATH}
	create_link "../wpa_supplicant_wlan1.service" "${FULL_PATH}/wpa_supplicant_wlan1.service"
	create_link "../dhclient_wlan1.service" "${FULL_PATH}/dhclient_wlan1.service"
	print_green "INFO: wlan1 client services enabled"
else
	delete_file_silent ${TARGET_DIR}/etc/wpa_supplicant_wlan1.conf
	delete_file_silent ${FULL_PATH}/wpa_supplicant_wlan1.service
	delete_file_silent ${FULL_PATH}/dhclient_wlan1.service
	print_green "INFO: WIFI_CLIENT is OFF, wpa_supplicant_wlan1.conf removed"
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
