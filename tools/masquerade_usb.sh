#!/bin/bash
set -euo pipefail

USB_IFACE="enx426365133456"
WIFI_IFACE="wlx78bdbc4b1597"
USB_SUBNET="192.168.100.0/24"

case "${1:-start}" in
    start)
        echo 1 > /proc/sys/net/ipv4/ip_forward
        iptables -t nat -A POSTROUTING -s ${USB_SUBNET} -o ${WIFI_IFACE} -j MASQUERADE
        iptables -A FORWARD -i ${USB_IFACE} -o ${WIFI_IFACE} -j ACCEPT
        iptables -A FORWARD -i ${WIFI_IFACE} -o ${USB_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        echo "Masquerade: ${USB_IFACE} (${USB_SUBNET}) -> ${WIFI_IFACE}"
        ;;
    stop)
        iptables -t nat -D POSTROUTING -s ${USB_SUBNET} -o ${WIFI_IFACE} -j MASQUERADE
        iptables -D FORWARD -i ${USB_IFACE} -o ${WIFI_IFACE} -j ACCEPT
        iptables -D FORWARD -i ${WIFI_IFACE} -o ${USB_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
        echo "Masquerade removed"
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
