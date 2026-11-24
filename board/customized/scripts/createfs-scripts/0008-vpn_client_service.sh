#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}

sed -i -E "s/export VPN_CLIENT=.*/export VPN_CLIENT=${VPN_CLIENT:-OFF}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}

# Удаляем все ссылки, которые могут быть использованы в прошлых сборках
if [[ -L "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/openvpn@client.service" ]]; then
                rm ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/openvpn@client.service
fi

# openvpn@client.service / openvpn@server.service были отдельными файлами и
# включались preset-all в каждой сборке. Теперь есть шаблон openvpn@.service, а
# эти файлы могли остаться в target/ от прошлых сборок (overlay не удаляет)
delete_file_silent ${TARGET_DIR}/etc/systemd/system/openvpn@client.service
delete_file_silent ${TARGET_DIR}/etc/systemd/system/openvpn@server.service
delete_file_silent ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/openvpn@server.service

if [[ -L "${TARGET_DIR}/etc/openvpn/configs/dummy.conf" ]]; then
	rm ${TARGET_DIR}/etc/openvpn/configs/dummy.conf
fi

if [[ -L "${TARGET_DIR}/etc/openvpn/client.conf" ]]; then
	rm ${TARGET_DIR}/etc/openvpn/client.conf
fi

# Конфиг от прошлой сборки не должен попасть в образ, собранный с VPN_CLIENT=OFF
delete_file_silent ${TARGET_DIR}/etc/openvpn/configs/client.conf

# Сначала проверяем VPN_CLIENT: если VPN не нужен - VPN_CONFIG не важен
if [[ -z ${VPN_CLIENT} ]]; then
	print_green "INFO: variable VPN_CLIENT is not set"
	exit 0
elif [[ "${VPN_CLIENT}" == "OFF" ]]; then
	print_green "INFO: VPN_CLIENT is OFF"
	exit 0
elif [[ "${VPN_CLIENT}" != "ON" ]]; then
	print_red "ERROR: VPN_CLIENT=${VPN_CLIENT}. ERROR! only ON or OFF"
	exit 1
fi

# VPN_CLIENT=ON - конфиг обязателен
if [[ -z ${VPN_CONFIG} ]]; then
	print_red "ERROR: VPN_CLIENT is ON but VPN_CONFIG is not set"
	exit 1
elif [[ ! -f ${VPN_CONFIG} ]]; then
	print_red "ERROR: VPN_CONFIG=${VPN_CONFIG}. ERROR! File not found"
	exit 1
fi

if ! cp ${VPN_CONFIG} ${TARGET_DIR}/etc/openvpn/configs/client.conf; then
	print_red "ERROR: can not copy ${VPN_CONFIG} to the target"
	exit 1
fi
ln -s configs/client.conf ${TARGET_DIR}/etc/openvpn/client.conf
print_green "INFO: link for configs/client.conf created"

create_dir ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants
ln -s ../openvpn@.service ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/openvpn@client.service
print_green "INFO: link for openvpn@client.service created"
exit 0
