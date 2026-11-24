#!/bin/bash
if [ -z ${USB_GADGET_DEVICE} ] || [ ${USB_GADGET_DEVICE} == "OFF" ]; then
	exit 0
fi

modprobe libcomposite
modprobe usb_f_rndis
cd /sys/kernel/config/usb_gadget/
mkdir -p ${DEV_HOSTNAME}
cd ${DEV_HOSTNAME}
echo "0x0200" > bcdUSB
echo "0x3066" > bcdDevice
echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct  # Multifunction Composite Gadget
#echo 0x0451 > idVendor   # Linux Foundation
#echo 0x6141 > idProduct  # Multifunction Composite Gadget
echo 0x00 > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol
mkdir -p strings/0x409
mkdir -p configs/c.1/strings/0x409
echo "Charge Manager 3.0" > strings/0x409/product

############################################################
if [ ! -z ${USB_RNDIS} ] && [ ${USB_RNDIS} == "ON" ]; then
	mkdir -p functions/rndis.usb0
	# set up mac address of remote device
	echo "42:63:65:13:34:56" > functions/rndis.usb0/host_addr
	# set up local mac address
	echo "42:63:65:66:43:21" > functions/rndis.usb0/dev_addr
	mkdir -p os_desc
	echo 1 > os_desc/use
	echo 0xcd > os_desc/b_vendor_code
	echo MSFT100 > os_desc/qw_sign
	mkdir -p functions/rndis.usb0/os_desc/interface.rndis
	echo RNDIS > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
	echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
	ln -s functions/rndis.usb0 configs/c.1/
	ln -s configs/c.1 os_desc
fi
###################### mass storage ########################
if [ ! -z ${USB_MASS_STORAGE} ] && [ ${USB_MASS_STORAGE} == "ON" ]; then
	mkdir -p functions/mass_storage.usb0
	echo 1 > functions/mass_storage.usb0/stall # allow bulk EPs
	echo 0 > functions/mass_storage.usb0/lun.0/cdrom # don't emulate CD-ROm
	echo 1 > functions/mass_storage.usb0/lun.0/ro # no write access
	# enable Force Unit Access (FUA) to make Windows write synchronously
	# this is slow, but unplugging the stick without unmounting works
	echo 0 > functions/mass_storage.usb0/lun.0/nofua
	echo /dev/mmcblk1p4 > functions/mass_storage.usb0/lun.0/file
	ln -s functions/mass_storage.usb0 configs/c.1/
fi
############################################################
# check for first available UDC driver
UDC_DRIVER=$(ls /sys/class/udc | cut -f1 | head -n 1)
# bind USB gadget to this UDC driver
echo $UDC_DRIVER > UDC
# Give it time to install
#sleep 5
# Yank it back
#echo "" > UDC
#ln -s functions/mass_storage.usb0 configs/c.1/
#echo "0x00" > bDeviceClass
#echo $UDC_DRIVER > UDC
## The bind above creates the gadget's net device as usb%d. The Quectel modem's
## cdc_ether also registers as usb%d and is only renamed to wwan0 by udev ~100 ms
## later, so on some boots it holds usb0 at the moment of the bind and the
## gadget comes up as usb1 - and everything below, dnsmasq_usb0, netpolicy and
## xraypolicy expect usb0. The kernel only takes an ifname pattern with %d, so
## find the gadget by its fixed dev_addr and rename it once usb0 is free.
gadget_ifname_usb0()
{
	local _mac _dev _i
	_mac=$(tr -d "\0\n" < functions/rndis.usb0/dev_addr)
	for _i in $(seq 50); do
		for _dev in /sys/class/net/*; do
			[ "$(cat ${_dev}/address 2>/dev/null)" == "${_mac}" ] || continue
			_dev=${_dev##*/}
			[ "${_dev}" == "usb0" ] && return 0
			if [ ! -e /sys/class/net/usb0 ] && ip link set dev "${_dev}" name usb0 2>/dev/null; then
				echo "usbstart: gadget interface ${_dev} renamed to usb0"
				return 0
			fi
		done
		sleep 0.2
	done
	echo "usbstart: ERROR: gadget interface (${_mac}) is not usb0 after 10 s" >&2
	return 1
}

if [ ! -z ${USB_RNDIS} ] && [ ${USB_RNDIS} == "ON" ]; then
	sleep 0.2
	gadget_ifname_usb0
	. /etc/profile.d/usbaddr.sh
	ifconfig usb0 ${USB_ADDR} up
	# usb0 is both a LAN and the last-resort uplink: if the USB host shares its
	# connection we can egress through it, but only when nothing else is left.
	# The metric comes from /etc/iface-metrics so the whole ladder is in one file.
	ip route add default via 192.168.100.75 dev usb0 \
		metric $(/usr/sbin/iface-metric usb0)
	rm /var/lib/misc/dnsmasq.leases
fi

######################## UVC part 2 ########################
