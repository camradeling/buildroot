# Shared AT-command machinery for the Quectel scripts. Sourced, not executed.
#
# Callers set LOG_TAG (journal tag) and may override AT_OUT before sourcing;
# everything else has a working default.
#
# Two scripts talk to the same serial port - quectel_ecm.sh on plug-in and
# modem-time on every wwan0 appearance - so both serialise on AT_LOCK through
# with_modem_lock, blocking, for as long as they are actually holding the port.

QUECTEL_VID="${QUECTEL_VID:-2c7c}"

# Two locks, and the difference between them is the whole point.
#
# AT_LOCK serialises the serial port. Two readers on one ttyUSB get each other's
# replies, so everything that sends an AT command takes this one and waits for it.
#
# LOCK_FILE is a single-instance lock and only quectel_ecm.sh uses it: udev fires
# once per plug-in and the mode switch re-enumerates the modem, so overlapping runs
# of the switch have to collapse into one. That one is taken non-blocking.
#
# They used to be the same file, and that cost a ten-minute outage on a live board,
# so this is not a tidiness argument. At boot modem-time won the race by 76ms and
# held the lock through its first AT round (port discovery, ~9s); quectel_ecm.sh's
# flock -n gave up 200ms in and exited 0 without a word. Nothing ever asserted
# AT+QNETDEVCTL, so the modem never bound its data call to the ECM interface -
# wwan0 appeared, dhclient took a lease from the modem's own DHCP server, the
# default route was installed, and not one packet reached the carrier. Every check
# on the box said the uplink was up. It stayed that way until an unrelated
# re-enumeration let the mode switch run, ten minutes later.
AT_LOCK="${AT_LOCK:-/run/quectel_at.lock}"
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

# Run "$@" while holding the serial port lock, then drop it. Waits up to
# ${LOCK_WAIT:-30}s: every caller here is either a poller or a plug-in handler, and
# what they are waiting for - the other one's AT round - takes seconds and is worth
# waiting for. Hold it for the shortest run that must not be interleaved, not for a
# whole poll: modem-time takes it per attempt and drops it between them.
#
# fd 8, not 9, so a caller can hold its own single-instance lock on 9 at the same
# time.
function with_modem_lock()
{
	local rc

	exec 8> ${AT_LOCK}
	if ! flock -w ${LOCK_WAIT:-30} 8; then
		exec 8>&-
		## Distinct from anything "$@" is likely to return, so a caller can tell
		## "I never got the port" from "what I ran on it failed" - a modem that is
		## busy from a modem that is broken. It is the first of those that used to
		## be silent.
		return 111
	fi
	"$@"
	rc=$?
	exec 8>&-
	return ${rc}
}
