#!/bin/sh
# Wait for dhclient to install the route, then replace it with a higher metric
# so eth0 remains the preferred default route
sleep 3
GW=$(ip route show dev wlan1 | grep default | awk '{print $3}')
if [ -n "${GW}" ]; then
    ip route del default via ${GW} dev wlan1 2>/dev/null
    ip route add default via ${GW} dev wlan1 metric 200
fi
