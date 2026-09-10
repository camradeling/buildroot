#!/bin/bash
# Bring up the Quectel ECM network interface.
#
# The kernel binds cdc_ether and the interface appears, but nothing configures
# it: there is no 80-ifupdown.rules in this image, so "allow-hotplug" in
# /etc/network/interfaces never fires, and listing the modem in "ifup -a" would
# make every boot without a modem wait for DHCP. udev calls us on plug-in
# instead: 99-quectel-ecm.rules -> quectel-ecm-up.service.
#
# The address comes from the modem's own DHCP server; the default route it hands
# out is demoted to metric 700 by /etc/dhclient-exit-hooks.

source /etc/system.vars 2>/dev/null

IFACE=wwan0
CARRIER_WAIT=15
LOCK_FILE="/run/quectel_ecm_up.lock"

function log()
{
	logger -t quectel_ecm_up "$*"
}

if [ -z "${QUECTEL_ECM}" ] || [ "${QUECTEL_ECM}" != "ON" ]; then
	exit 0
fi

# the modem re-enumerates after the mode switch, so the rule can fire again
# while we are still working - keep a single instance.
#
# Every command below that can spawn a daemon must get 9>&-: ifup starts dhclient,
# which would inherit this descriptor and hold the lock for as long as it runs,
# making every later invocation exit silently right here. That is exactly what
# happened after the first modem reset - the replug did nothing at all and wwan0
# stayed down with no log line to show why.
exec 9> ${LOCK_FILE}
flock -n 9 || exit 0

if [ ! -d /sys/class/net/${IFACE} ]; then
	log "ERROR: ${IFACE} does not exist, 79-quectel-ecm-name.rules did not rename the ECM device"
	exit 1
fi

# ifup keeps its state in /run/network/ifstate: after a replug the interface is
# still marked up there and ifup would refuse to touch it
ifdown --force ${IFACE} > /dev/null 2>&1 9>&-

ip link set dev ${IFACE} up

# dhclient needs carrier, which the modem takes a moment to assert after
# enumeration. Best effort only - try DHCP either way, the modem answers from
# its internal server even before the data call is up.
waited=0
while [ ${waited} -lt ${CARRIER_WAIT} ]; do
	[ "$(cat /sys/class/net/${IFACE}/carrier 2>/dev/null)" == "1" ] && break
	sleep 1
	waited=$((waited + 1))
done

if [ ${waited} -ge ${CARRIER_WAIT} ]; then
	log "WARNING: no carrier on ${IFACE} after ${CARRIER_WAIT}s, trying DHCP anyway"
fi

if ! ifup ${IFACE} 9>&-; then
	log "ERROR: ifup ${IFACE} failed"
	exit 1
fi

log "${IFACE} up: $(ip -4 -o addr show dev ${IFACE} | awk '{print $4}'), routes: $(ip -4 route show default dev ${IFACE} | tr '\n' ';')"
exit 0
