#!/bin/bash
#
# BR2_ROOTFS_POST_FAKEROOT_SCRIPT - the only hook that runs *after* Buildroot's
# "systemctl --root=... preset-all" (fs/common.mk: ROOTFS_PRE_CMD_HOOKS, which is
# where systemd.mk installs it, then BR2_ROOTFS_POST_FAKEROOT_SCRIPT).
#
# It asserts, it does not fix. preset-all's default policy is *enable*, so every
# unit with an [Install] section is enabled in the image regardless of what the
# createfs scripts did earlier. The design that follows from that:
#
#   optional service = [Install] kept + Condition*= on a config file
#                      + createfs deletes that config file when the var is OFF
#
# The three rules below check that this design is actually in force, so that a
# newly added unit cannot silently start shipping enabled - which is how
# openvpn@server.service and wpa_supplicant_wlan1.service ended up running on
# images built with VPN_CLIENT=OFF / WIFI_CLIENT=OFF.
#
# Runs once per filesystem type (ext2 and tar here), on a throwaway copy of
# target/ that is deleted afterwards, so it must stay read-only - it is.
#
# Scope is /etc/systemd/system/multi-user.target.wants only: that is where both
# preset-all and our createfs scripts create links. Links under
# /usr/lib/systemd/system/*.wants are upstream vendor defaults and not ours.

set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "${SCRIPT_DIR}/functions.inc"

TARGET_DIR="${1}"
WANTS_DIR="${TARGET_DIR}/etc/systemd/system/multi-user.target.wants"
VARS_FILE="${TARGET_DIR}/etc/system.vars"

RC=0

fail()
{
	print_red "ERROR: after-preset-check: $*"
	RC=1
}

## Units that are meant to run on every image. Anything not listed here has to
## carry its own runtime condition.
ALWAYS_ON="lighttpd.service
modbusgw-gpio.service
networking.service
rc-local.service
remote-fs.target
rpcbind.service
sshd.service
syncfiles.service
usbipd.service
systemd-networkd.service"
## systemd-networkd: enabled by preset, ships no .network files, so it manages
## no interface. Harmless today; a candidate for removal from the defconfig.

## Feature table: <var expression state> | <gated units> | <config artifacts>
##   ON  -> every artifact must exist
##   OFF -> every artifact must be gone
## and each gated unit's Condition*Exists= must point at one of the artifacts,
## so a typo on either side is caught instead of silently disabling a feature.
##
## QUECTEL_ECM has no entry in a .wants dir at all - quectel-ecm.service and
## quectel-ecm-up.service are started by udev via SYSTEMD_WANTS and have no
## [Install] section, so preset-all does not touch them.

# shellcheck source=/dev/null
if [[ ! -f "${VARS_FILE}" ]]; then
	print_red "ERROR: after-preset-check: ${VARS_FILE} not found"
	exit 1
fi
source "${VARS_FILE}"

if [[ ! -d "${WANTS_DIR}" ]]; then
	print_red "ERROR: after-preset-check: ${WANTS_DIR} not found"
	exit 1
fi

## resolve a unit name to its unit file inside the target, following the
## template convention (openvpn@client.service -> openvpn@.service)
find_unit_file()
{
	local unit="$1" dir template
	for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
		if [[ -f "${TARGET_DIR}${dir}/${unit}" ]]; then
			echo "${TARGET_DIR}${dir}/${unit}"
			return 0
		fi
	done
	if [[ "${unit}" == *@*.service ]]; then
		template="${unit%%@*}@.service"
		for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
			if [[ -f "${TARGET_DIR}${dir}/${template}" ]]; then
				echo "${TARGET_DIR}${dir}/${template}"
				return 0
			fi
		done
	fi
	return 1
}

## instance name of a template unit, empty for a plain unit
unit_instance()
{
	local unit="$1"
	if [[ "${unit}" == *@*.service ]]; then
		unit="${unit%.service}"
		echo "${unit#*@}"
	fi
}

#####################################################################
## Rule A: everything enabled is either always-on or self-gating
#####################################################################
for link in "${WANTS_DIR}"/*; do
	[[ -e "${link}" || -L "${link}" ]] || continue
	unit="$(basename "${link}")"

	if grep -qxF "${unit}" <<< "${ALWAYS_ON}"; then
		continue
	fi
	## ifplugd@<iface>.service - one instance per interface from 0002-netconfig.sh
	if [[ "${unit}" == ifplugd@*.service ]]; then
		continue
	fi

	unit_file="$(find_unit_file "${unit}")" || {
		fail "${unit} is enabled but no unit file was found for it"
		continue
	}

	if ! grep -qE '^(Condition[A-Za-z]+|ExecCondition)=' "${unit_file}"; then
		fail "${unit} is enabled by preset-all but has no Condition*= gate." \
			"Add one (see hostapd.service) or add it to ALWAYS_ON in $(basename "$0")"
	fi
done

#####################################################################
## Rules B and C: config artifacts match the vars, units point at them
#####################################################################
check_feature()
{
	local feature="$1" state="$2" units="$3" artifacts="$4"
	local artifact unit unit_file instance cond found

	case "${state}" in
	ON)
		for artifact in ${artifacts}; do
			if [[ ! -e "${TARGET_DIR}${artifact}" ]]; then
				fail "${feature}=ON but ${artifact} is missing from the image"
			fi
		done
		;;
	*)
		for artifact in ${artifacts}; do
			if [[ -e "${TARGET_DIR}${artifact}" || -L "${TARGET_DIR}${artifact}" ]]; then
				fail "${feature} is off but ${artifact} is still in the image," \
					"so preset-all's link will start the service anyway"
			fi
		done
		;;
	esac

	for unit in ${units}; do
		unit_file="$(find_unit_file "${unit}")" || {
			fail "${feature}: unit file for ${unit} not found"
			continue
		}
		instance="$(unit_instance "${unit}")"
		found=0
		while read -r cond; do
			[[ -n "${cond}" ]] || continue
			cond="${cond//%i/${instance}}"
			for artifact in ${artifacts}; do
				if [[ "${cond}" == "${artifact}" ]]; then
					found=1
				fi
			done
		done < <(sed -n 's/^ConditionPathExists=//p' "${unit_file}")
		if [[ ${found} -eq 0 ]]; then
			fail "${unit} has no ConditionPathExists= on any of the ${feature}" \
				"config files (${artifacts}), so ${feature}=OFF would not disable it"
		fi
	done
}

USB_NET_STATE=OFF
if [[ "${USB_GADGET_DEVICE:-OFF}" == "ON" ]] && [[ "${USB_RNDIS:-OFF}" == "ON" ]]; then
	USB_NET_STATE=ON
fi

check_feature WIFI_AP     "${WIFI_AP:-OFF}"      "hostapd.service dnsmasq_wlan0.service" \
	"/etc/hostapd.conf /etc/dnsmasq_wlan0.conf"
check_feature WIFI_CLIENT "${WIFI_CLIENT:-OFF}"  "wpa_supplicant_wlan1.service dhclient_wlan1.service" \
	"/etc/wpa_supplicant_wlan1.conf"
check_feature USB_RNDIS   "${USB_NET_STATE}"     "dnsmasq_usb0.service" \
	"/etc/dnsmasq_usb0.conf"
check_feature VPN_CLIENT  "${VPN_CLIENT:-OFF}"   "openvpn@client.service" \
	"/etc/openvpn/client.conf /etc/openvpn/configs/client.conf"
check_feature QUECTEL_ECM "${QUECTEL_ECM:-OFF}"  "" \
	"/etc/udev/rules.d/79-quectel-ecm-name.rules /etc/udev/rules.d/99-quectel-ecm.rules"

## openvpn@client.service is the one gated unit preset-all does not manage
## (openvpn@.service is a real template), so here presence in .wants is meaningful
if [[ "${VPN_CLIENT:-OFF}" == "ON" ]]; then
	if [[ ! -L "${WANTS_DIR}/openvpn@client.service" ]]; then
		fail "VPN_CLIENT=ON but openvpn@client.service is not enabled"
	fi
elif [[ -L "${WANTS_DIR}/openvpn@client.service" ]]; then
	fail "VPN_CLIENT is off but openvpn@client.service is still enabled"
fi

if [[ ${RC} -eq 0 ]]; then
	print_green "INFO: after-preset-check: systemd unit gating matches ${VARS_FILE}"
else
	print_red "ERROR: after-preset-check failed, see the errors above"
fi

exit ${RC}
