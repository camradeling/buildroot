#!/bin/bash
# Make sure a Quectel modem exposes its network function as ECM.
#
# The EC200A (and relatives) can come up in RNDIS mode (AT+QCFG="usbnet",3),
# which needs the rndis_host driver. Our kernel only builds cdc_ether, so in
# that mode the modem shows up as serial ports only and there is no network
# interface. Supported values on the EC200A are 1 (ECM) and 3 (RNDIS).
#
# Started by udev on plug-in: 99-quectel-ecm.rules -> quectel-ecm.service.
# Lives in /usr/libexec/quectel/ and not /etc/scripts/ deliberately: rc.local runs
# every /etc/scripts/*.sh at boot with no arguments, and udev is the only correct
# trigger for this one.

source /etc/system.vars 2>/dev/null

LOG_TAG="quectel_ecm"
source /usr/libexec/quectel/quectel_at.inc

ECM_MODE="1"
AT_PORT_WAIT=20

if [ -z "${QUECTEL_ECM}" ] || [ "${QUECTEL_ECM}" != "ON" ]; then
	exit 0
fi

# udev fires once per plug-in, but the modem re-enumerates after the mode
# switch - keep a single instance so the runs do not overlap
exec 9> ${LOCK_FILE}
flock -n 9 || exit 0

## find_modem, list_ports, at_cmd and find_at_port come from quectel_at.inc,
## sourced above - modem-time needs the same three and there is no second copy.

## Is there a modem at all? Answer this before waiting for anything.
##
## The old loop asked "modem AND ports?" up to AT_PORT_WAIT times, so with no
## modem plugged in it burned the full 20s before concluding there was nothing to
## do. That cost nothing while udev was the only trigger, but this script also sat
## in /etc/scripts/, which rc.local runs in full on every boot - and
## rc-local.service is ordered before hostapd, so every modem-less boot delayed
## the AP by 20s. The script now lives in /usr/libexec/quectel/ where rc.local
## cannot reach it, and exits immediately anyway: sysfs already knows whether a
## USB device is present, there is nothing to wait for.
MODEM=$(find_modem)
if [ -z "${MODEM}" ]; then
	log "no Quectel device (${QUECTEL_VID}) found, nothing to do"
	exit 0
fi

## Only now is waiting justified: the modem is on the bus, so its ttyUSB ports
## are coming, they are just not bound yet.
PORTS=""
waited=0
while [ ${waited} -lt ${AT_PORT_WAIT} ]; do
	PORTS=$(list_ports ${MODEM})
	[ -n "${PORTS}" ] && break
	sleep 1
	waited=$((waited + 1))
done

if [ -z "${PORTS}" ]; then
	log "ERROR: Quectel found at ${MODEM} but no ttyUSB port appeared in ${AT_PORT_WAIT}s"
	exit 1
fi

## find a port that answers AT
AT_PORT=$(find_at_port "${PORTS}")

if [ -z "${AT_PORT}" ]; then
	log "ERROR: none of the ports (${PORTS}) answered AT"
	exit 1
fi

# Bind the data call to the USB network device. Without this the ECM link comes
# up perfectly - the host gets a lease from the modem's internal DHCP server and
# can ping the modem at 192.168.43.1 - but nothing is forwarded to the PDP
# context, so there is no internet. Seen on an EC200A that reported
# "+QNETDEVCTL: 0,0,0,0" while +CGACT/+CGPADDR showed an active context with a
# carrier IP, which makes it look like a routing problem on our side.
#
# The third argument is autoconnect, so the modem redials by itself after a
# reset. Asserted on every plug-in anyway: it is a per-modem setting, so a
# replacement modem arrives with it unset.
#
# Note AT+QCFG="nat" is deliberately left alone - traffic flows with nat=0.
function ensure_netdev_bound()
{
	local state

	state=$(at_cmd ${AT_PORT} 'AT+QNETDEVCTL?' 2 | sed -n -E 's/.*\+QNETDEVCTL: *([0-9,]+).*/\1/p' | head -1)
	if [ -z "${state}" ]; then
		log "AT+QNETDEVCTL not supported on this modem, skipping the data call binding"
		return 0
	fi

	case "${state}" in
	1,1,*)
		log "data call already bound to the net device (+QNETDEVCTL: ${state})"
		return 0
		;;
	esac

	log "data call not bound (+QNETDEVCTL: ${state}), binding it with autoconnect"
	if at_cmd ${AT_PORT} 'AT+QNETDEVCTL=1,1,1' 3 | grep -q "OK"; then
		log "AT+QNETDEVCTL=1,1,1 accepted"
	else
		log "ERROR: modem refused AT+QNETDEVCTL=1,1,1, wwan0 will have no uplink"
	fi
}

ensure_netdev_bound

## read the current usbnet mode
MODE=$(at_cmd ${AT_PORT} 'AT+QCFG="usbnet"' 2 | sed -n -E 's/.*\+QCFG: "usbnet",([0-9]+).*/\1/p' | head -1)

if [ -z "${MODE}" ]; then
	log "ERROR: could not read usbnet mode on ${AT_PORT}"
	exit 1
fi

if [ "${MODE}" == "${ECM_MODE}" ]; then
	log "usbnet=${MODE} (ECM) already set, nothing to do"
	exit 0
fi

log "usbnet=${MODE} on ${AT_PORT}, switching to ECM (usbnet=${ECM_MODE})"

if ! at_cmd ${AT_PORT} "AT+QCFG=\"usbnet\",${ECM_MODE}" 2 | grep -q "OK"; then
	log "ERROR: modem refused AT+QCFG=\"usbnet\",${ECM_MODE}"
	exit 1
fi

## the new mode is kept in the modem NVRAM and applied after a reset; the reset
## re-enumerates the modem, so udev starts us again and we confirm the new mode
log "usbnet=${ECM_MODE} stored, resetting modem"
at_cmd ${AT_PORT} "AT+CFUN=1,1" 2 > /dev/null

rm -f ${AT_OUT}
exit 0
