#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
FILENAME="${TARGET_DIR}/etc/network/interfaces"
DNSFILE="${TARGET_DIR}/etc/resolv.conf"

## variable DEVICE_IFACE is taken from .vars file
FULL_PATH="${TARGET_DIR}/etc/systemd/system/multi-user.target.wants"

create_dir ${FULL_PATH}

IFPLUGD_IFACE0_LINK="${FULL_PATH}/ifplugd@${DEVICE_IFACE}.service"
IFPLUGD_ETH01_LINK="${FULL_PATH}/ifplugd@${DEVICE_IFACE}:1.service"
IFPLUGD_ETH1_LINK="${FULL_PATH}/ifplugd@${MODEM_IFACE}.service"
IFPLUGD_SERVICE="../ifplugd@.service"

###################
# Удаляем все ссылки, которые можем создать (при наличии этих переменных)
delete_file_silent ${IFPLUGD_IFACE0_LINK}
delete_file_silent ${IFPLUGD_ETH01_LINK}
delete_file_silent ${FILENAME}
delete_file_silent ${DNSFILE}
delete_file_silent ${IFPLUGD_ETH1_LINK}


# рабочий скрипт
if ! [ -d ${TARGET_DIR}/etc/network ]; then
	mkdir -p ${TARGET_DIR}/etc/network
else
	print_red "INFO: folder \"${TARGET_DIR}/etc/network\" exists" 
fi


set_space "source-directory" "/etc/network/interfaces.d" ${FILENAME}
set_space "auto" "lo" ${FILENAME}
set_space "iface lo" "inet loopback" ${FILENAME}

if [[ -z "${DEVICE_STATIC_ADDR}" ]]; then
	print_red "INFO: variable DEVICE_STATIC_ADDR is not set"

elif [[ "${DEVICE_STATIC_ADDR}" == "OFF" ]]; then
	print_red "INFO: variable DEVICE_STATIC_ADDR=OFF. STATIC IP is not set"

elif [[ "${DEVICE_STATIC_ADDR}" == "ON" ]]; then
	if [[ "${DEVICE_IFACE}" == "eth0" ]]; then
		set_space "allow-hotplug" "eth0" ${FILENAME}
	elif [[ "${DEVICE_IFACE}" == "usb0" ]]; then
                set_space "auto" "usb0" ${FILENAME}
	else
		print_red "ERROR! script for interface ${DEVICE_IFACE} not work"
		exit 1
	fi
	set_space "iface ${DEVICE_IFACE}" "inet static" ${FILENAME}
	create_link $IFPLUGD_SERVICE $IFPLUGD_IFACE0_LINK
	set_space "  address" ${DEVICE_STATIC_IPADDR} ${FILENAME}
	set_space "  netmask" ${DEVICE_STATIC_NETMASK} ${FILENAME}
	if [[ ! -z ${DEVICE_STATIC_GATEWAY} ]]; then
		set_space "  gateway" ${DEVICE_STATIC_GATEWAY} $FILENAME
		if [[ "${DEVICE_DHCP_ADDR}" == "ON" ]]; then
			set_space "  metric" "100" ${FILENAME}
		fi
	fi
else
	print_red "ERROR: DEVICE_STATIC_ADDR=${DEVICE_STATIC_ADDR}. Only ON or OFF"
	exit 2
fi

########### DNS-SERVER ########
if [[ -z ${DEVICE_DNS_SERVER} && -z ${DEVICE_STATIC_GATEWAY} ]]; then
	NAMESERVER="8.8.8.8"
elif [[ -z ${DEVICE_STATIC_GATEWAY}} ]]; then
	NAMESERVER=$DEVICE_DNS_SERVER
elif [[ -z ${DEVICE_DNS_SERVER} ]]; then
	NAMESERVER=$DEVICE_STATIC_GATEWAY
else
	NAMESERVER=$DEVICE_DNS_SERVER
fi

set_space "nameserver" $NAMESERVER $DNSFILE
#################################

if [[ -z "${DEVICE_DHCP_ADDR}" ]] || [[ "${DEVICE_DHCP_ADDR}" == "OFF" ]]; then
	print_red "INFO: variable DEVICE_DHCP_ADDR=OFF. DHCP is not set"
elif [[ "${DEVICE_DHCP_ADDR}" == "ON" ]]; then
	if [[ "${DEVICE_IFACE}" == "eth0" ]]; then
		set_space "allow-hotplug" "eth0:1" ${FILENAME}
		set_space "iface eth0:1" "inet dhcp" ${FILENAME}
		create_link $IFPLUGD_SERVICE $IFPLUGD_ETH01_LINK
	fi
	print_green "INFO: dhcp-ip done"
else
	print_red "ERROR: DEVICE_DHCP_ADDR=${DEVICE_DHCP_ADDR}. only ON or OFF"
	exit 2
fi

print_green "INFO: netconfig.sh DONE"

if [[ -z ${MODEM_IFACE} ]]; then
	print_red "INFO: variable ${MODEM_IFACE} is not set"
else
	print_green "INFO: create configuration for usb-modem interface"
	set_space "allow-hotplug" ${MODEM_IFACE} ${FILENAME}
	set_space "iface ${MODEM_IFACE}" "inet static" ${FILENAME}
	set_space "  address" ${MODEM_IPADDR} ${FILENAME}
	set_space "  netmask" ${MODEM_NETMASK} ${FILENAME}
	if [[ -z $VPN_IP ]]; then
		if [[ -z ${MODEM_GATEWAY} ]]; then
			print_red "ERROR! VPN_IP and MODEM_GATEWAY is not set, exit"
			exit 2
		else
			set_space "  gateway" ${MODEM_GATEWAY} ${FILENAME}
		fi
	else
		set_space "  post-up" "ip route add ${VPN_IP} via ${MODEM_GATEWAY} metric 10" ${FILENAME}
		sed -i "s/gateway ${DEVICE_STATIC_GATEWAY}/post-up ip route add ${VPN_IP} via ${DEVICE_STATIC_GATEWAY} metric 20/g" $FILENAME
	fi
	create_link  $IFPLUGD_SERVICE $IFPLUGD_ETH1_LINK
fi



exit 0
