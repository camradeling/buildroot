#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

rm ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service
print_green "INFO: remove wpa_supplicant service from systemd, it can be added later"
rm ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/dhclient.service
print_green "INFO: remove dhclient service from systemd, it can be added later"
rm ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/dnsmasq_wlan0.service
print_green "INFO: remove dnsmasq_wlan0 service from systemd, it can be added later"
rm ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/hostapd.service
print_green "INFO: remove hostapd service from systemd, it can be added later"
