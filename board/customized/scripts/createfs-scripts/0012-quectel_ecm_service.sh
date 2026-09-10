#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
OVERLAY_DIR="${PWD}/board/customized/overlays/services/quectel_ecm"

## <relative path in the overlay> -> installed as ${TARGET_DIR}/<same path>
FILES="etc/udev/rules.d/99-quectel-ecm.rules
etc/udev/rules.d/79-quectel-ecm-name.rules
etc/systemd/system/quectel-ecm.service
etc/systemd/system/quectel-ecm-up.service
etc/scripts/quectel_ecm.sh
etc/scripts/quectel_ecm_up.sh
etc/network/interfaces.d/wwan0
etc/dhclient-exit-hooks"

## the two scripts are executed, everything else is config
EXECUTABLES="etc/scripts/quectel_ecm.sh
etc/scripts/quectel_ecm_up.sh"

## start
sed -i -E "s/export QUECTEL_ECM=.*/export QUECTEL_ECM=${QUECTEL_ECM:-OFF}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "QUECTEL_ECM=${QUECTEL_ECM:-OFF}"

## Nothing is installed unless the option is on. The files are removed as well,
## so switching the option off and rebuilding leaves a clean image.
if [[ "${QUECTEL_ECM:-OFF}" != "ON" ]]; then
	for f in ${FILES}; do
		delete_file_silent ${TARGET_DIR}/${f}
	done
	print_green "INFO: QUECTEL_ECM is OFF"
	exit 0
fi

if [[ ! -d "${OVERLAY_DIR}" ]]; then
	print_red "ERROR: QUECTEL_ECM=ON but ${OVERLAY_DIR} not found"
	exit 1
fi

for f in ${FILES}; do
	create_dir $(dirname ${TARGET_DIR}/${f})
	copy_file ${OVERLAY_DIR}/${f} ${TARGET_DIR}/${f}
	# copy_file only warns, and an image missing one of these would boot with a
	# modem that never comes up
	if [[ ! -f ${TARGET_DIR}/${f} ]]; then
		print_red "ERROR: ${f} was not installed into the target"
		exit 1
	fi
done

for f in ${EXECUTABLES}; do
	set_chmod 0755 ${TARGET_DIR}/${f}
done

## wwan0 is configured from /etc/network/interfaces.d, which is only read if the
## generated /etc/network/interfaces sources it (see 0002-netconfig.sh)
if ! grep -q "source-directory /etc/network/interfaces.d" ${TARGET_DIR}/etc/network/interfaces; then
	print_red "ERROR: /etc/network/interfaces does not source /etc/network/interfaces.d, wwan0 would be ignored"
	exit 1
fi

exit 0
