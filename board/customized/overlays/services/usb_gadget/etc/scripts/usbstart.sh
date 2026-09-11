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
if [ ! -z ${USB_RNDIS} ] && [ ${USB_RNDIS} == "ON" ]; then
	sleep 0.2
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
