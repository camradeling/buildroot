# Shared AT-command machinery for the Quectel scripts. Sourced, not executed.
#
# Callers set LOG_TAG (journal tag) and may override AT_OUT before sourcing;
# everything else has a working default.
#
# Two scripts talk to the same serial port - quectel_ecm.sh on plug-in and
# modem-time on every wwan0 appearance - so both take LOCK_FILE first. They do
# it differently on purpose: the mode switch takes it non-blocking and skips its
# run if it is held, while modem-time waits (see with_modem_lock).

QUECTEL_VID="${QUECTEL_VID:-2c7c}"
LOCK_FILE="${LOCK_FILE:-/run/quectel_ecm.lock}"
AT_OUT="${AT_OUT:-/run/quectel_ecm.at}"

function log()
{
	logger -t "${LOG_TAG:-quectel}" "$*"
}

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

# Which of the modem's ttyUSB ports answers AT. Echoes the port, empty if none.
function find_at_port()
{
	local ports=$1
	local p
	for p in ${ports}; do
		if at_cmd ${p} "AT" 1 | grep -q "OK"; then
			echo ${p}
			return 0
		fi
	done
	return 1
}

# Run "$@" while holding the modem lock, then drop it. Waits up to
# ${LOCK_WAIT:-30}s: the caller is a poller, and the thing it is most likely
# waiting for is quectel_ecm.sh resetting the modem, which is worth waiting for.
function with_modem_lock()
{
	local rc

	exec 9> ${LOCK_FILE}
	if ! flock -w ${LOCK_WAIT:-30} 9; then
		exec 9>&-
		return 1
	fi
	"$@"
	rc=$?
	exec 9>&-
	return ${rc}
}
