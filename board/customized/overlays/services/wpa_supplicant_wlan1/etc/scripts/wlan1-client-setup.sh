#!/bin/sh
. /etc/system.vars

if [ -z "${WIFI_CLIENT}" ] || [ "${WIFI_CLIENT}" = "OFF" ]; then
    exit 0
fi

WIFI_AP_IFACE="${WIFI_AP_WLAN_NAME:-wlan0}"

case "$1" in
    start)
        iptables -t nat -A POSTROUTING -o wlan1 -j MASQUERADE
        iptables -A FORWARD -i ${WIFI_AP_IFACE} -o wlan1 -j ACCEPT
        iptables -A FORWARD -i wlan1 -o ${WIFI_AP_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        ;;
    stop)
        iptables -t nat -D POSTROUTING -o wlan1 -j MASQUERADE
        iptables -D FORWARD -i ${WIFI_AP_IFACE} -o wlan1 -j ACCEPT
        iptables -D FORWARD -i wlan1 -o ${WIFI_AP_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        ;;
esac
