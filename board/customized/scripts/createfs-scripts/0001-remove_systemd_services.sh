#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

## Эти ссылки остаются в target/ от предыдущих сборок: overlay копируется без
## --delete, а preset-all их создаёт заново на каждой сборке (он запускается
## ПОСЛЕ post-build скриптов, уже в копии target/). Поэтому удаление здесь -
## только уборка мусора, выключением сервиса оно не является: за это отвечает
## ConditionPathExists= в самих unit-файлах плюс удаление конфига в 0007/0010/0011.
## -f обязателен: без него отсутствие ссылки даёт rm rc=1, а
## before-fs-allscripts.sh прерывает сборку по ненулевому коду возврата.
rm -f ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service
print_green "INFO: remove wpa_supplicant service from systemd, it can be added later"
rm -f ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/dhclient.service
print_green "INFO: remove dhclient service from systemd, it can be added later"
rm -f ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/dnsmasq_wlan0.service
print_green "INFO: remove dnsmasq_wlan0 service from systemd, it can be added later"
rm -f ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/hostapd.service
print_green "INFO: remove hostapd service from systemd, it can be added later"
rm -f ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/wpa_supplicant_wlan1.service
print_green "INFO: remove wpa_supplicant_wlan1 service from systemd, it can be added later"
rm -f ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/dhclient_wlan1.service
print_green "INFO: remove dhclient_wlan1 service from systemd, it can be added later"

exit 0
