#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
OVERLAY_DIR="${PWD}/board/customized/overlays/services/quectel_ecm"

RULE_FILE="${TARGET_DIR}/etc/udev/rules.d/99-quectel-ecm.rules"
UNIT_FILE="${TARGET_DIR}/etc/systemd/system/quectel-ecm.service"
SWITCH_SCRIPT="${TARGET_DIR}/etc/scripts/quectel_ecm.sh"

## start
sed -i -E "s/export QUECTEL_ECM=.*/export QUECTEL_ECM=${QUECTEL_ECM:-OFF}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "QUECTEL_ECM=${QUECTEL_ECM:-OFF}"

## Nothing is installed unless the option is on. The files are removed as well,
## so switching the option off and rebuilding leaves a clean image.
if [[ "${QUECTEL_ECM:-OFF}" != "ON" ]]; then
	delete_file_silent ${RULE_FILE}
	delete_file_silent ${UNIT_FILE}
	delete_file_silent ${SWITCH_SCRIPT}
	print_green "INFO: QUECTEL_ECM is OFF"
	exit 0
fi

if [[ ! -d "${OVERLAY_DIR}" ]]; then
	print_red "ERROR: QUECTEL_ECM=ON but ${OVERLAY_DIR} not found"
	exit 1
fi

create_dir ${TARGET_DIR}/etc/udev/rules.d
create_dir ${TARGET_DIR}/etc/systemd/system
create_dir ${TARGET_DIR}/etc/scripts

copy_file ${OVERLAY_DIR}/etc/udev/rules.d/99-quectel-ecm.rules ${RULE_FILE}
copy_file ${OVERLAY_DIR}/etc/systemd/system/quectel-ecm.service ${UNIT_FILE}
copy_file ${OVERLAY_DIR}/etc/scripts/quectel_ecm.sh ${SWITCH_SCRIPT}
set_chmod 0755 ${SWITCH_SCRIPT}

exit 0
