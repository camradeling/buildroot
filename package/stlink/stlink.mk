################################################################################
#
# stlink
#
################################################################################

## for tag in git
STLINK_VERSION = v1.7.0
STLINK_SITE = git@github.com:stlink-org/stlink.git


STLINK_SITE_METHOD = git
STLINK_GIT_SUBMODULES = YES
STLINK_DEPENDENCIES = libusb

$(eval $(cmake-package))
