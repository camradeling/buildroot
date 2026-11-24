#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

## start
sed -i -E "s/export USB_GADGET_DEVICE=.*/export USB_GADGET_DEVICE=${USB_GADGET_DEVICE}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "USB_GADGET_DEVICE=${USB_GADGET_DEVICE}"
sed -i -E "s/export USB_RNDIS=.*/export USB_RNDIS=${USB_RNDIS}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "USB_RNDIS=${USB_RNDIS}"
sed -i -E "s/export USB_MASS_STORAGE=.*/export USB_MASS_STORAGE=${USB_MASS_STORAGE}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "USB_MASS_STORAGE=${USB_MASS_STORAGE}"

## dnsmasq_usb0.service is enabled by preset-all regardless of these variables
## (preset-all runs after the post-build scripts), so the config file is what
## actually switches it off - the unit has ConditionPathExists on it.
DNSMASQ_USB="${TARGET_DIR}/etc/dnsmasq_usb0.conf"
if [[ "${USB_GADGET_DEVICE}" != "ON" ]] || [[ "${USB_RNDIS}" != "ON" ]]; then
	delete_file_silent ${DNSMASQ_USB}
	print_green "INFO: USB network gadget is off, dnsmasq_usb0.conf removed"
	exit 0
fi

## suppress DHCP gateway push to host unless USB_PUSH_GATEWAY=ON
if [[ -f "${DNSMASQ_USB}" ]] && [[ "${USB_PUSH_GATEWAY:-OFF}" != "ON" ]]; then
	if ! grep -q "^dhcp-option=3$" ${DNSMASQ_USB}; then
		echo "dhcp-option=3" >> ${DNSMASQ_USB}
	fi
	print_green "USB_PUSH_GATEWAY=OFF (dhcp-option=3 added)"
fi

exit 0

