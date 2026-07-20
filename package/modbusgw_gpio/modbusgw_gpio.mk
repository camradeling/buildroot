################################################################################
#
# modbusgw_gpio
#
################################################################################

MODBUSGW_GPIO_VERSION = v0.1.0
MODBUSGW_GPIO_SITE = https://github.com/camradeling/modbusgw-gpio.git
MODBUSGW_GPIO_SITE_METHOD = git
MODBUSGW_GPIO_GIT_SUBMODULES = YES
MODBUSGW_GPIO_LICENSE = GPL-2.0
MODBUSGW_GPIO_DEPENDENCIES = mxml

$(eval $(cmake-package))
