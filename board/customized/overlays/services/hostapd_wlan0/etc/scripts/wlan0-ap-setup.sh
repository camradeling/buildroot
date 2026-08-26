#!/bin/sh
. /etc/system.vars

if [ -z "${WIFI_AP}" ] || [ "${WIFI_AP}" = "OFF" ]; then
    exit 0
fi

AP_IFACE="${WIFI_AP_WLAN_NAME:-wlan0}"
WAN_IFACE="${WIFI_AP_WAN_IFACE:-eth0}"

case "$1" in
    start)
        ifconfig ${AP_IFACE} ${WIFI_AP_ADDR} netmask ${WIFI_AP_NETMASK} up
        iptables -t nat -A POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
        iptables -A FORWARD -i ${AP_IFACE} -o ${WAN_IFACE} -j ACCEPT
        iptables -A FORWARD -i ${WAN_IFACE} -o ${AP_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        ;;
    stop)
        iptables -t nat -D POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
        iptables -D FORWARD -i ${AP_IFACE} -o ${WAN_IFACE} -j ACCEPT
        iptables -D FORWARD -i ${WAN_IFACE} -o ${AP_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        ifconfig ${AP_IFACE} 0.0.0.0 down
        ;;
esac
