#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
OVERLAY_DIR="${PWD}/board/customized/overlays/services/icmpvpn"

## Google's ranges through an OpenVPN tunnel to singaserv, switched on the board
## by "icmpvpn on|off" (see usr/sbin/icmpvpn in the overlay). The carrier drops
## every packet to Google's ranges and the xray tunnel carries no ICMP, so this
## is the only way the bench can ping Google.
##
## ICMPVPN=ON installs the tool and ICMPVPN_CONFIG, the openvpn client profile for
## this board (not in git: it holds the key). Whether the tunnel is actually up
## is decided on the board, not here: icmpvpn.service starts it at boot only if
## "icmpvpn on" left /media/data/icmpvpn.on behind.

## <relative path in the overlay> -> installed as ${TARGET_DIR}/<same path>
FILES="usr/sbin/icmpvpn
etc/icmpvpn/google-v4.txt
etc/systemd/system/icmpvpn.service"
PROFILE=etc/icmpvpn/client.conf

fail()
{
	print_red "ERROR: $*"
	exit 1
}

## Clean up first, whatever the switch says: output/target/ is not wiped between
## builds, and a profile left from an ON build would let the unit start.
for f in ${FILES} ${PROFILE}; do
	delete_file_silent ${TARGET_DIR}/${f}
done

## after-preset-check reads the switch back from the image
sed -i -E "s/export ICMPVPN=.*/export ICMPVPN=${ICMPVPN:-OFF}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}

if [[ "${ICMPVPN:-OFF}" != "ON" ]]; then
	print_green "INFO: ICMPVPN is OFF"
	exit 0
fi

[[ "${XRAY_CLIENT:-OFF}" == "ON" && "${XRAY_BOARD_TUNNEL:-OFF}" == "ON" ]] ||
	fail "ICMPVPN=ON needs XRAY_CLIENT=ON and XRAY_BOARD_TUNNEL=ON: openvpn's own" \
		"connection to singaserv has to ride the xray tunnel, the carrier blocks it otherwise"
## openvpn@client would bring up a second client and accept the pushed default
## route; this tool runs its own openvpn with a profile that refuses it
[[ "${VPN_CLIENT:-OFF}" != "ON" ]] ||
	fail "ICMPVPN=ON and VPN_CLIENT=ON both start an openvpn client; turn VPN_CLIENT off"
[[ -n "${ICMPVPN_CONFIG}" ]] || fail "ICMPVPN is ON but ICMPVPN_CONFIG is not set"
[[ -r "${ICMPVPN_CONFIG}" ]] || fail "ICMPVPN_CONFIG=${ICMPVPN_CONFIG}: not found or not readable by $(id -un)"
grep -q '^<key>' "${ICMPVPN_CONFIG}" || fail "ICMPVPN_CONFIG has no inline <key>, not a client profile"

for f in ${FILES}; do
	create_dir $(dirname ${TARGET_DIR}/${f})
	copy_file ${OVERLAY_DIR}/${f} ${TARGET_DIR}/${f}
	[[ -f ${TARGET_DIR}/${f} ]] || fail "${f} was not installed into the target"
done
set_chmod 0755 ${TARGET_DIR}/usr/sbin/icmpvpn

## The profile as the server issued it, with the lines this board depends on
## forced: a fixed device name (the routes name it), nothing the server pushes
## that could take the default route or DNS, and the hooks that put the routes
## back after a reconnect. Earlier copies of any of these are dropped first, so
## a profile that already has them (one copied off a board) gives the same file.
OUT=${TARGET_DIR}/${PROFILE}
create_dir $(dirname ${OUT})
( umask 077
  sed -E -e '/^(dev|pull-filter|route-noexec|script-security|up|down) /d' \
         -e '/^route-noexec$/d' -e '/^# --- testbot4:/d' \
         -e '/^# keep the board default route/d' "${ICMPVPN_CONFIG}" > ${OUT}
  cat >> ${OUT} <<'EOF'

# --- added by 0015-icmpvpn_service.sh ---
dev tun9
pull-filter ignore redirect-gateway
pull-filter ignore dhcp-option
pull-filter ignore route
route-noexec
script-security 2
up "/usr/sbin/icmpvpn up"
down "/usr/sbin/icmpvpn down"
EOF
)
chmod 600 ${OUT}
print_green "ICMPVPN=ON: icmpvpn, its boot unit and the openvpn profile installed"

exit 0
