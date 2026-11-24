#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

HOSTNAME_FILE=${TARGET_DIR}/etc/hostname
TARGET_DIR=${1}

delete_file_silent $HOSTNAME_FILE
if [[ -z ${DEV_HOSTNAME} ]]; then
        print_green "INFO: variable DEV_HOSTNAME is not set"
else
        set_value $DEV_HOSTNAME $HOSTNAME_FILE
        sed -i -E "s/export DEV_HOSTNAME=.*/export DEV_HOSTNAME=${DEV_HOSTNAME}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
        print_green "DEV_HOSTNAME=${DEV_HOSTNAME}"
fi
exit 0
