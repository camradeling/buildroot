#############################################################
#
# usbip
#
#############################################################

USBIP_VERSION = 0.1.7
USBIP_SITE = http://downloads.sourceforge.net/project/usbip/usbip/$(USBIP_VERSION)
USBIP_LICENSE = GPLv2+
USBIP_LICENSE_FILES = COPYING
USBIP_CONF_OPTS = --without-tcpwrappers
USBIP_SUBDIR = src
USBIP_AUTORECONF = YES

$(eval $(autotools-package))