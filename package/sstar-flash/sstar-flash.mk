################################################################################
#
# sstar-flash
#
################################################################################

SSTAR_FLASH_VERSION = 65b9bfc981ba231132c7769a9a2722fb65360d89
SSTAR_FLASH_SITE = https://github.com/vdenisov-c-arlo/LoryUSBTool.git
SSTAR_FLASH_SITE_METHOD = git
SSTAR_FLASH_SUBDIR = sstar-flash
SSTAR_FLASH_LICENSE = MIT

define SSTAR_FLASH_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/sstar-flash \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)"
endef

define SSTAR_FLASH_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/sstar-flash/sstar-flash \
		$(TARGET_DIR)/usr/bin/sstar-flash
endef

ifeq ($(BR2_PACKAGE_SSTAR_FLASH_UDEV_RULES),y)
define SSTAR_FLASH_INSTALL_UDEV_RULES
	$(INSTALL) -D -m 0644 /dev/null \
		$(TARGET_DIR)/etc/udev/rules.d/99-sigmastar-flash.rules
	printf '%s\n' \
		'# SigmaStar SoC in USB ROM boot mode (VID:PID 1b20:0300)' \
		'SUBSYSTEM=="scsi_generic", ATTRS{idVendor}=="1b20", ATTRS{idProduct}=="0300", MODE="0666"' \
		'SUBSYSTEM=="block", ATTRS{idVendor}=="1b20", ATTRS{idProduct}=="0300", MODE="0666"' \
		'# SigmaStar SoC in U-Boot mode (VID:PID 1a40:0201)' \
		'SUBSYSTEM=="scsi_generic", ATTRS{idVendor}=="1a40", ATTRS{idProduct}=="0201", MODE="0666"' \
		'SUBSYSTEM=="block", ATTRS{idVendor}=="1a40", ATTRS{idProduct}=="0201", MODE="0666"' \
		> $(TARGET_DIR)/etc/udev/rules.d/99-sigmastar-flash.rules
endef
SSTAR_FLASH_POST_INSTALL_TARGET_HOOKS += SSTAR_FLASH_INSTALL_UDEV_RULES
endif

$(eval $(generic-package))
