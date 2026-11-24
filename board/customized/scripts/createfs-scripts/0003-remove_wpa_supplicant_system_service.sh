#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
rm ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service
print_green "INFO: remove wpa_supplicant service from systemd"
