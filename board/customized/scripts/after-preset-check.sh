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
# Rules A-C below check that this design is actually in force, so that a newly
# added unit cannot silently start shipping enabled - which is how
# openvpn@server.service and wpa_supplicant_wlan1.service ended up running on
# images built with VPN_CLIENT=OFF / WIFI_CLIENT=OFF. Rules D to F cover the other
# ways a config can rot: files that used to be installed and no longer should be,
# files that have to be present for something to have one owner, and a unit that
# is enabled somewhere other than multi-user.target.wants. Rule G covers the
# pieces of the Xray uplink whose absence is invisible until a LAN client tries to
# reach the internet.
#
# Runs once per filesystem type (ext2 and tar here), on a throwaway copy of
# target/ that is deleted afterwards, so it must stay read-only - it is.
#
# Scope is /etc/systemd/system/multi-user.target.wants only: that is where both
# preset-all and our createfs scripts create links. Links under
# /usr/lib/systemd/system/*.wants are upstream vendor defaults and not ours. Units
# that are enabled into some other target - a device unit for QUECTEL_ECM, a timer
# for xray-health - are named one by one in rules F and G instead of walked.

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
netpolicy.service
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
## QUECTEL_ECM has no entry in multi-user.target.wants: quectel-ecm.service is
## started by udev via SYSTEMD_WANTS and has no [Install] section at all, and
## quectel-ecm-up.service is WantedBy= the wwan0 device unit, so preset-all puts
## its link in sys-subsystem-net-devices-wwan0.device.wants instead. Rule F below
## is what checks that link, since it is the only thing that brings the uplink up.

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
	"/etc/udev/rules.d/79-quectel-ecm-name.rules /etc/udev/rules.d/99-quectel-ecm.rules /usr/libexec/quectel/quectel_ecm.sh /usr/libexec/quectel/quectel_at.inc /usr/sbin/modem-time /etc/systemd/system/modem-time.service"
check_feature XRAY_CLIENT  "${XRAY_CLIENT:-OFF}"  "xray.service xray-health.timer xray-health.service" \
	"/etc/xray/config.json"

## openvpn@client.service is the one gated unit preset-all does not manage
## (openvpn@.service is a real template), so here presence in .wants is meaningful
if [[ "${VPN_CLIENT:-OFF}" == "ON" ]]; then
	if [[ ! -L "${WANTS_DIR}/openvpn@client.service" ]]; then
		fail "VPN_CLIENT=ON but openvpn@client.service is not enabled"
	fi
elif [[ -L "${WANTS_DIR}/openvpn@client.service" ]]; then
	fail "VPN_CLIENT is off but openvpn@client.service is still enabled"
fi

## D. Paths that must be gone from the image whatever the feature flags say.
##
## output/target/ is not wiped between builds and neither the overlay rsync nor
## the createfs copies use --delete, so dropping a file from an overlay does not
## remove it from the image - it just stops being updated. For these particular
## files that is a live regression and not dead weight, because something still
## executes them: rc.local runs every /etc/scripts/*.sh at boot, dhclient-script
## sources /etc/dhclient-exit-hooks on every lease, and ifupdown reads
## interfaces.d. Each one used to be an owner of something that now has exactly
## one owner, so a leftover copy means two owners again.
RETIRED="/etc/scripts/quectel_ecm.sh
/etc/scripts/quectel_ecm_up.sh
/etc/scripts/wlan1-fix-metric.sh
/etc/scripts/wlan1-client-setup.sh
/etc/dhclient-exit-hooks
/etc/network/interfaces.d/wwan0"

for path in ${RETIRED}; do
	if [[ -e "${TARGET_DIR}${path}" || -L "${TARGET_DIR}${path}" ]]; then
		fail "${path} is retired but is still in the image; the createfs script" \
			"that used to install it has to delete it explicitly"
	fi
done

## E. The metric ladder is a single source of truth only if it is actually there.
for path in /etc/iface-metrics /usr/sbin/iface-metric; do
	if [[ ! -e "${TARGET_DIR}${path}" ]]; then
		fail "${path} is missing, so every default route would take the" \
			"fallback metric instead of the one the table specifies"
	fi
done

## F. With QUECTEL_ECM=ON, the one thing that starts the DHCP client on the
## modem's uplink is a .wants link on the wwan0 device unit, created by preset-all
## from the unit's [Install] section. If preset-all ever stops creating it - a
## typo in WantedBy=, a preset that disables the unit - the image still boots, the
## modem still switches to ECM, and wwan0 just sits there with no address, which
## is exactly the failure this replaced and it took a live board to spot. So check
## the link, not the [Install] line.
if [[ "${QUECTEL_ECM:-OFF}" == "ON" ]]; then
	QECM_WANTS_DIR="${TARGET_DIR}/etc/systemd/system/sys-subsystem-net-devices-wwan0.device.wants"
	if [[ ! -L "${QECM_WANTS_DIR}/quectel-ecm-up.service" ]]; then
		fail "QUECTEL_ECM=ON but quectel-ecm-up.service is not linked into" \
			"sys-subsystem-net-devices-wwan0.device.wants, so nothing would" \
			"start dhclient when wwan0 appears"
	fi
	## Same shape, same silent failure: without this link the board runs with a
	## clock two years in the past, which breaks every TLS handshake including
	## Xray's REALITY one (it embeds a client timestamp).
	if [[ ! -L "${QECM_WANTS_DIR}/modem-time.service" ]]; then
		fail "QUECTEL_ECM=ON but modem-time.service is not linked into" \
			"sys-subsystem-net-devices-wwan0.device.wants, so nothing would" \
			"set the clock from the modem"
	fi
fi

## G. The Xray uplink. check_feature above covers the config file and the unit's
## condition; these are the pieces whose absence shows up only as "the LAN has no
## internet", with the rules installed and nothing behind them.
if [[ "${XRAY_CLIENT:-OFF}" == "ON" ]]; then
	for path in /usr/bin/xray /usr/sbin/xraypolicy /usr/sbin/xray-health; do
		if [[ ! -e "${TARGET_DIR}${path}" ]]; then
			fail "XRAY_CLIENT=ON but ${path} is missing from the image"
		fi
	done

	## The health check is the only thing that notices a tunnel that accepts
	## connections and carries nothing, and it runs from a timer - so the link
	## preset-all creates from [Install] is the whole feature. Same silent failure
	## as rule F: the image boots, xray runs, the LAN blackholes, and nothing says
	## so. The link lands in timers.target.wants, which rule A does not walk.
	if [[ ! -L "${TARGET_DIR}/etc/systemd/system/timers.target.wants/xray-health.timer" ]]; then
		fail "XRAY_CLIENT=ON but xray-health.timer is not linked into" \
			"timers.target.wants, so a dead tunnel would never be noticed"
	fi

	## The probe needs a client, and busybox has no nc applet in this defconfig.
	if [[ ! -e "${TARGET_DIR}/usr/bin/nc" && ! -e "${TARGET_DIR}/bin/nc" ]]; then
		fail "XRAY_CLIENT=ON but there is no nc in the image, so xray-health's probe" \
			"can never succeed and it would restart xray forever"
	fi

	## Policy routing is the one thing busybox's ip applet cannot do, and it does
	## not fail loudly: it has no "rule" command at all, and it *silently ignores*
	## "table 100" on a route add. Measured on the live board - "ip route add local
	## default dev lo table 100" installed a black-hole default route in the main
	## table and took the box off the network. So iproute2 has to own /usr/sbin/ip.
	IP_BIN="${TARGET_DIR}/usr/sbin/ip"
	if [[ -L "${IP_BIN}" ]]; then
		fail "/usr/sbin/ip is a symlink to $(readlink "${IP_BIN}") - with busybox on" \
			"that path xraypolicy's ip rule/ip route commands fail silently and" \
			"'table 100' lands in the main routing table"
	elif [[ ! -f "${IP_BIN}" ]]; then
		fail "XRAY_CLIENT=ON but /usr/sbin/ip is missing (BR2_PACKAGE_IPROUTE2=y?)"
	fi

	## The dnsmasq configs that exist must take their upstream from the file
	## xraypolicy writes. 0013 appends the line; if the createfs scripts are ever
	## reordered so that 0007 or 0010 rewrites the file afterwards, this catches it
	## at build time instead of as a DNS leak in the field.
	##
	## no-resolv is checked too, and it is not redundant: it makes dnsmasq ignore
	## every resolv-file, so leaving one behind turns the line above into a comment
	## and the LAN silently resolves through nothing at all.
	for path in /etc/dnsmasq_usb0.conf /etc/dnsmasq_wlan0.conf; do
		[[ -f "${TARGET_DIR}${path}" ]] || continue
		if ! grep -q '^resolv-file=/run/xray-dns\.conf$' "${TARGET_DIR}${path}"; then
			fail "XRAY_CLIENT=ON but ${path} does not take its upstream from" \
				"/run/xray-dns.conf, so LAN clients would resolve around the" \
				"tunnel - or keep resolving through it after it dies"
		fi
		if grep -qx 'no-resolv' "${TARGET_DIR}${path}"; then
			fail "XRAY_CLIENT=ON but ${path} still has no-resolv, which makes dnsmasq" \
				"ignore resolv-file=/run/xray-dns.conf and leaves the LAN with no upstream"
		fi
	done
fi

if [[ ${RC} -eq 0 ]]; then
	print_green "INFO: after-preset-check: systemd unit gating matches ${VARS_FILE}"
else
	print_red "ERROR: after-preset-check failed, see the errors above"
fi

exit ${RC}
