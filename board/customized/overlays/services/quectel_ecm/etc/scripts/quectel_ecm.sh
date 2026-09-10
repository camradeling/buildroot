#!/bin/bash
# Make sure a Quectel modem exposes its network function as ECM.
#
# The EC200A (and relatives) can come up in RNDIS mode (AT+QCFG="usbnet",3),
# which needs the rndis_host driver. Our kernel only builds cdc_ether, so in
# that mode the modem shows up as serial ports only and there is no network
# interface. Supported values on the EC200A are 1 (ECM) and 3 (RNDIS).
#
# Started by udev on plug-in: 99-quectel-ecm.rules -> quectel-ecm.service

source /etc/system.vars 2>/dev/null

QUECTEL_VID="2c7c"
ECM_MODE="1"
AT_PORT_WAIT=20
LOCK_FILE="/run/quectel_ecm.lock"
AT_OUT="/run/quectel_ecm.at"

function log()
{
	logger -t quectel_ecm "$*"
}

if [ -z "${QUECTEL_ECM}" ] || [ "${QUECTEL_ECM}" != "ON" ]; then
	exit 0
fi

# udev fires once per plug-in, but the modem re-enumerates after the mode
# switch - keep a single instance so the runs do not overlap
exec 9> ${LOCK_FILE}
flock -n 9 || exit 0

function find_modem()
{
	local d
	for d in /sys/bus/usb/devices/*/; do
		[ -f "${d}idVendor" ] || continue
		if [ "$(cat ${d}idVendor)" == "${QUECTEL_VID}" ]; then
			echo "${d}"
			return 0
		fi
	done
	return 1
}

function list_ports()
{
	local modem=$1
	local t
	for t in ${modem}*:*/ttyUSB*; do
		[ -e "${t}" ] || continue
		echo "/dev/$(basename ${t})"
	done
}

# Send one AT command and echo back whatever the modem replied. There is no
# timeout(1) on the target, so read the port in the background and stop it
# after a fixed wait.
function at_cmd()
{
	local port=$1
	local cmd=$2
	local wait_s=${3:-2}
	local cpid

	# Line settings are best effort only: USB serial ignores the baud rate, and
	# the option driver on these modems rejects part of the termios request.
	# The modem answers on its default settings, command echo and all.
	stty -F ${port} 115200 raw -echo > /dev/null 2>&1

	: > ${AT_OUT}
	cat ${port} > ${AT_OUT} 2>/dev/null &
	cpid=$!
	sleep 0.3
	printf '%s\r' "${cmd}" > ${port} 2>/dev/null
	sleep ${wait_s}
	kill ${cpid} 2>/dev/null
	wait ${cpid} 2>/dev/null

	tr -d '\r' < ${AT_OUT}
}

## wait for the modem and its serial ports to show up
MODEM=""
PORTS=""
waited=0
while [ ${waited} -lt ${AT_PORT_WAIT} ]; do
	MODEM=$(find_modem)
	if [ -n "${MODEM}" ]; then
		PORTS=$(list_ports ${MODEM})
		[ -n "${PORTS}" ] && break
	fi
	sleep 1
	waited=$((waited + 1))
done

if [ -z "${MODEM}" ]; then
	log "no Quectel device (${QUECTEL_VID}) found, nothing to do"
	exit 0
fi

if [ -z "${PORTS}" ]; then
	log "ERROR: Quectel found at ${MODEM} but no ttyUSB port appeared in ${AT_PORT_WAIT}s"
	exit 1
fi

## find a port that answers AT
AT_PORT=""
for p in ${PORTS}; do
	if at_cmd ${p} "AT" 1 | grep -q "OK"; then
		AT_PORT=${p}
		break
	fi
done

if [ -z "${AT_PORT}" ]; then
	log "ERROR: none of the ports (${PORTS}) answered AT"
	exit 1
fi

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
