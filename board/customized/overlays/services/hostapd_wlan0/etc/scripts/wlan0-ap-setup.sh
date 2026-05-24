#!/bin/sh
. /etc/system.vars

if [ -z "${WIFI_AP}" ] || [ "${WIFI_AP}" = "OFF" ]; then
    exit 0
fi

case "$1" in
    start)
        ifconfig wlan0 ${WIFI_AP_ADDR} netmask ${WIFI_AP_NETMASK} up
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
        iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        ;;
    stop)
        iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
        iptables -D FORWARD -i wlan0 -o eth0 -j ACCEPT
        iptables -D FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        ifconfig wlan0 0.0.0.0 down
        ;;
esac
