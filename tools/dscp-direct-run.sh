#!/bin/bash
# Run a process (and everything it starts) with a DSCP mark on all of its
# packets, so that the testbot AP lets exactly that traffic bypass the tunnels.
#
# This runs on the AP client, not on the board. The board side is a DSCP host in
# the vars file, "<mac>,<ip>,<dscp>" in WIFI_AP_DIRECT_HOSTS (workplans/006):
# netpolicy marks packets from that MAC+IP carrying that DSCP as direct, and the
# rest of the client stays tunnelled. The DSCP here must be the same value.
#
# How: a cgroup v2 group (/sys/fs/cgroup/<name>) and an nftables table whose
# output chain sets the DSCP on every packet from a socket in that group. A
# process moved into the group passes it on to its children. The mark is set per
# socket, so every packet of a flow carries it - a connection never starts on
# one path and continues on the other.
#
# Usage (as root, or through sudo - the command itself runs as the calling user):
#   sudo dscp-direct-run.sh [-d DSCP] [-u USER] [--] COMMAND [ARGS...]
#   sudo dscp-direct-run.sh stop      remove the nft table and the cgroup
#   dscp-direct-run.sh status         show the rule and the processes in the group
#
#   -d DSCP   1..63, default 7 (or $DSCP_DIRECT)
#   -u USER   run COMMAND as USER (default: SUDO_USER, else root)
#
# GUI programs need their session environment, which sudo drops by default:
#   sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,DBUS_SESSION_BUS_ADDRESS \
#        dscp-direct-run.sh firefox
#
# Requires: cgroup v2 (unified hierarchy), nftables, kernel >= 5.13 (nft socket
# cgroupv2 match).
#
# Limits worth knowing:
#  - DNS: lookups done by the system resolver (systemd-resolved, nscd) do not come
#    from this cgroup, so they stay unmarked and tunnelled. Only the traffic the
#    process sends itself is direct.
#  - The nft rule resolves the cgroup when it is loaded. "stop" and a later run
#    recreate both, so never rmdir the group by hand while the table is loaded.
#  - The table first clears this DSCP from every packet, so only the group can
#    carry it - a program that happens to pick the same value (ssh's "lowdelay"
#    is DSCP 4) stays tunnelled instead of going direct and being reset when it
#    changes its TOS mid-connection. Root on this machine can still bypass.

set -u

CG_NAME=${DSCP_DIRECT_CGROUP:-dscp-direct}
CG_ROOT=/sys/fs/cgroup
CG=${CG_ROOT}/${CG_NAME}
NFT_TABLE=dscp_direct
DSCP=${DSCP_DIRECT:-7}
RUN_USER=${SUDO_USER:-}

die() { echo "dscp-direct-run: $*" >&2; exit 1; }

need_root() {
	[ "$(id -u)" -eq 0 ] || die "needs root: sudo $0 $*"
}

check_env() {
	[ -f "${CG_ROOT}/cgroup.controllers" ] ||
		die "${CG_ROOT} is not a cgroup v2 hierarchy (hybrid/v1 setup?)"
	command -v nft >/dev/null || die "nft not found (install nftables)"
}

nft_load() {
	nft delete table inet ${NFT_TABLE} 2>/dev/null
	## priority mangle: before anything that might look at the DSCP. filter type,
	## not route: the DSCP does not change where the packet goes on this machine.
	nft -f - <<EOF || die "could not load the nft table (kernel without nft socket cgroupv2?)"
table inet ${NFT_TABLE} {
	chain output {
		type filter hook output priority mangle; policy accept;
		meta nfproto ipv4 ip dscp ${DSCP} ip dscp set 0
		meta nfproto ipv6 ip6 dscp ${DSCP} ip6 dscp set 0
		socket cgroupv2 level 1 "${CG_NAME}" meta nfproto ipv4 ip dscp set ${DSCP}
		socket cgroupv2 level 1 "${CG_NAME}" meta nfproto ipv6 ip6 dscp set ${DSCP}
	}
}
EOF
}

cmd_status() {
	if nft list table inet ${NFT_TABLE} 2>/dev/null; then :; else echo "no nft table ${NFT_TABLE}"; fi
	if [ -d "${CG}" ]; then
		echo "processes in ${CG}:"
		while read -r pid; do
			[ -n "${pid}" ] && ps -o pid=,user=,args= -p "${pid}"
		done < "${CG}/cgroup.procs"
	else
		echo "no cgroup ${CG}"
	fi
}

cmd_stop() {
	need_root stop
	nft delete table inet ${NFT_TABLE} 2>/dev/null && echo "nft table ${NFT_TABLE} removed"
	if [ -d "${CG}" ]; then
		if [ -s "${CG}/cgroup.procs" ]; then
			die "${CG} still has processes, stop them first (see: $0 status)"
		fi
		rmdir "${CG}" && echo "cgroup ${CG} removed"
	fi
}

cmd_run() {
	need_root "$@"
	check_env
	[ $# -gt 0 ] || die "no command given"
	[[ "${DSCP}" =~ ^[0-9]{1,2}$ ]] && (( DSCP >= 1 && DSCP <= 63 )) || die "DSCP ${DSCP} is not 1..63"

	mkdir -p "${CG}" || die "cannot create ${CG}"
	## Reload every time: the cgroup may have been recreated since the last run,
	## and a rule pointing at the old one matches nothing
	nft_load

	echo $$ > "${CG}/cgroup.procs" || die "cannot move into ${CG}"

	if [ -z "${RUN_USER}" ] || [ "${RUN_USER}" = root ]; then
		echo "dscp-direct-run: DSCP ${DSCP}, running as root: $*" >&2
		exec "$@"
	fi
	id "${RUN_USER}" >/dev/null 2>&1 || die "no such user ${RUN_USER}"
	_uid=$(id -u "${RUN_USER}")
	_home=$(getent passwd "${RUN_USER}" | cut -d: -f6)
	export HOME="${_home}" USER="${RUN_USER}" LOGNAME="${RUN_USER}"
	[ -n "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "/run/user/${_uid}" ] || export XDG_RUNTIME_DIR="/run/user/${_uid}"
	echo "dscp-direct-run: DSCP ${DSCP}, running as ${RUN_USER}: $*" >&2
	exec setpriv --reuid="${_uid}" --regid="$(id -g "${RUN_USER}")" --init-groups -- "$@"
}

case "${1:-}" in
	status) cmd_status; exit ;;
	stop) cmd_stop; exit ;;
	""|-h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac

while [ $# -gt 0 ]; do
	case "$1" in
		-d) [ $# -ge 2 ] || die "-d needs a value"; DSCP=$2; shift 2 ;;
		-u) [ $# -ge 2 ] || die "-u needs a value"; RUN_USER=$2; shift 2 ;;
		--) shift; break ;;
		-*) die "unknown option $1" ;;
		*) break ;;
	esac
done
cmd_run "$@"
