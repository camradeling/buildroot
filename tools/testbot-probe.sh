#!/bin/bash
# Quick host-side probe of testbot4's uplink, for testbot-probe.timer (every 30s).
#
# testbot-diag.service runs the full diagnosis every 5 minutes, and that is too
# coarse: the outages in workplans/003 often lasted 1-3 minutes, so they would
# start and end between two runs. This asks only what costs nothing - does the
# board answer ping, does an HTTPS request from this host get out - and on the
# OK -> FAIL edge runs testbot-diag.sh right away, while the outage is still on.
#
#   DIR/probe.state   "<since> ok|fail", the previous result
#   DIR/probe.log     one line per transition, with the outage's length on recovery
#
# Transitions also go to the journal at warning priority (-t testbot-probe).
# Silent otherwise, so a quiet day leaves no journal lines at all.
#
# Usage: testbot-probe.sh [-c conf] [DIR]   DIR defaults to $STATE_DIRECTORY
#        testbot-probe.sh [-c conf] --check-ap
#
#   --check-ap   exit 0 if this host is on the board's AP (AP_SSID in the
#                config; always 0 when that is empty), 1 otherwise - the units'
#                ExecCondition, so nothing runs or logs while the host is away

HERE=$(dirname "$(readlink -f "$0")")
CONF=${TESTBOT_DIAG_CONF:-${HERE}/testbot-diag.conf}
CHECK_AP=""
DIR=${STATE_DIRECTORY}

while [ $# -gt 0 ]; do
	case "$1" in
	-c|--config)	CONF=$2; shift ;;
	--check-ap)	CHECK_AP=1 ;;
	-h|--help)	sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)		DIR=$1 ;;
	esac
	shift
done

source "${CONF}" || exit 2
E2E_HOST=${E2E_HOST:-api.anthropic.com}
[ -n "${BOARD_ADDR}" ] || { echo "BOARD_ADDR is not set in ${CONF}" >&2; exit 2; }

if [ -n "${CHECK_AP}" ]; then
	[ -z "${AP_SSID}" ] && exit 0
	dev=$(ip route get "${BOARD_ADDR}" 2>/dev/null | sed -n -E 's/.* dev ([^ ]+).*/\1/p')
	[ -n "${dev}" ] && iw dev "${dev}" link 2>/dev/null | sed -n 's/^\s*SSID: //p' | grep -qxF "${AP_SSID}"
	exit $?
fi

[ -n "${DIR}" ] || { echo "no state directory: pass DIR or run under StateDirectory=" >&2; exit 2; }
mkdir -p "${DIR}" || exit 2

ago()
{
	local s=$1
	[ ${s} -ge 3600 ] && echo "$((s / 3600))h$((s % 3600 / 60))m" || echo "$((s / 60))m$((s % 60))s"
}

if ping -c2 -W1 -q "${BOARD_ADDR}" > /dev/null 2>&1; then
	BOARD_PING=ok
else
	BOARD_PING=fail
fi
## Any HTTP status is a working path; only a curl error is not
curl -s -o /dev/null -m 8 "https://${E2E_HOST}/"
RC=$?
[ ${RC} -eq 0 ] && STATE=ok || STATE=fail

NOW=$(date +%s)
[ -f "${DIR}/probe.state" ] && read -r SINCE PREV < "${DIR}/probe.state"
[ "${PREV}" = "${STATE}" ] && exit 0
echo "${NOW} ${STATE}" > "${DIR}/probe.state"

## The first run after install or reboot only records the state
[ -z "${PREV}" ] && exit 0

if [ "${STATE}" = fail ]; then
	MSG="uplink lost: https://${E2E_HOST} curl exit ${RC}, board ping ${BOARD_PING}"
else
	MSG="uplink back after $(ago $((NOW - SINCE)))"
fi
echo "$(date -d @${NOW} '+%F %T') ${MSG}" >> "${DIR}/probe.log"
logger -t testbot-probe -p user.warning "${MSG}"

## The diagnosis that matters is the one taken during the outage. It takes its
## own lock, so a scheduled run already in progress makes this a no-op.
if [ "${STATE}" = fail ]; then
	"${HERE}/testbot-diag.sh" -c "${CONF}" --log-state "${DIR}" > /dev/null
fi
exit 0
