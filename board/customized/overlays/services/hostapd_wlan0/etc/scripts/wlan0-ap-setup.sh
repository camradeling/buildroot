#!/bin/sh
# Address assignment for the AP interface, run from hostapd.service's
# ExecStartPost/ExecStopPost.
#
# NAT used to live here as well, masquerading out a single hardcoded
# ${WIFI_AP_WAN_IFACE:-eth0}. That was wrong twice over: AP clients could only
# reach the internet over that one interface (so they had none once wwan0 was
# the only live uplink), and tearing the rules down in ExecStopPost meant a
# plain "systemctl restart hostapd" removed NAT for everything on the board.
# It is now installed once at boot by netpolicy.service, keyed on the LAN
# subnet instead of on an uplink. See /usr/sbin/netpolicy.
. /etc/system.vars

if [ -z "${WIFI_AP}" ] || [ "${WIFI_AP}" = "OFF" ]; then
    exit 0
fi

AP_IFACE="${WIFI_AP_WLAN_NAME:-wlan0}"

case "$1" in
    start)
        ifconfig ${AP_IFACE} ${WIFI_AP_ADDR} netmask ${WIFI_AP_NETMASK} up
        ;;
    stop)
        ifconfig ${AP_IFACE} 0.0.0.0 down
        ;;
esac
