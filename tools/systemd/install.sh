#!/bin/bash
# Install the host-side testbot4 monitoring: testbot-diag.timer (full diagnosis
# every 5 min) and testbot-probe.timer (quick probe every 30 s). See
# workplans/004-testbot-diag.md.
#
# Usage: sudo tools/systemd/install.sh [--user NAME]
#        sudo tools/systemd/install.sh --uninstall
#
#   --user NAME  who the checks run as: the user whose SSH key reaches the
#                board and who can read tools/testbot-diag.conf. Default: the
#                user who ran sudo.
#
# The state - history.log, reports/, probe.log - lands in /var/lib/testbot-diag
# and stays there on --uninstall.

set -e

HERE=$(dirname "$(readlink -f "$0")")
REPO=$(dirname "$(dirname "${HERE}")")
DEST=/etc/systemd/system
UNITS="testbot-diag.service testbot-diag.timer testbot-probe.service testbot-probe.timer"
RUN_USER=${SUDO_USER}
UNINSTALL=""

while [ $# -gt 0 ]; do
	case "$1" in
	--user)		RUN_USER=$2; shift ;;
	--uninstall)	UNINSTALL=1 ;;
	-h|--help)	sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)		echo "unknown option: $1" >&2; exit 1 ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

if [ -n "${UNINSTALL}" ]; then
	systemctl disable --now testbot-diag.timer testbot-probe.timer 2>/dev/null || true
	for u in ${UNITS}; do
		rm -f "${DEST}/${u}"
	done
	systemctl daemon-reload
	echo "removed; /var/lib/testbot-diag kept"
	exit 0
fi

[ -n "${RUN_USER}" ] && id "${RUN_USER}" > /dev/null 2>&1 ||
	{ echo "no such user '${RUN_USER}', pass --user" >&2; exit 1; }

## Everything the service user has to reach, checked as that user now rather
## than found out from the journal later
for f in "${REPO}/tools/testbot-diag.sh" "${REPO}/tools/testbot-probe.sh"; do
	sudo -u "${RUN_USER}" test -x "${f}" || { echo "${RUN_USER} cannot run ${f}" >&2; exit 1; }
done
sudo -u "${RUN_USER}" test -r "${REPO}/tools/testbot-diag.conf" || {
	echo "${RUN_USER} cannot read ${REPO}/tools/testbot-diag.conf - copy it from testbot-diag.conf.template" >&2
	exit 1
}

for u in ${UNITS}; do
	sed -e "s|@USER@|${RUN_USER}|g" -e "s|@REPO@|${REPO}|g" "${HERE}/${u}" > "${DEST}/${u}"
done
systemctl daemon-reload
systemctl enable --now testbot-diag.timer testbot-probe.timer

cat <<MSG
installed, running as ${RUN_USER} from ${REPO}

  systemctl list-timers 'testbot-*'
  journalctl -t testbot-diag -t testbot-probe -p warning   # transitions only
  tail /var/lib/testbot-diag/history.log /var/lib/testbot-diag/probe.log
  ls /var/lib/testbot-diag/reports/
MSG
