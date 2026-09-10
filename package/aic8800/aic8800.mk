################################################################################
#
# aic8800
#
################################################################################

AIC8800_VERSION = bd11969265809a0fc948f1107c8256bbb2c1aa60
AIC8800_SITE = $(call github,radxa-pkg,aic8800,$(AIC8800_VERSION))
AIC8800_LICENSE = GPL-2.0
AIC8800_LICENSE_FILES = LICENSE

AIC8800_MODULE_SUBDIRS = src/USB/driver_fw/drivers/aic8800

define AIC8800_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_NET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_CFG80211)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_SUPPORT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB)
endef

AIC8800_MODULE_MAKE_OPTS = \
	CONFIG_AIC_LOADFW_SUPPORT=m \
	CONFIG_AIC8800_WLAN_SUPPORT=m \
	CONFIG_PLATFORM_UBUNTU=y \
	CONFIG_PLATFORM_ROCKCHIP=n \
	CONFIG_PLATFORM_ALLWINNER=n \
	CONFIG_PLATFORM_AMLOGIC=n \
	CONFIG_PLATFORM_HI=n \
	KVER=$(LINUX_VERSION_PROBED) \
	USER_EXTRA_CFLAGS="-DCONFIG_$(call qstrip,$(BR2_ENDIAN))_ENDIAN -Wno-error"

ifeq ($(BR2_PACKAGE_AIC8800_BTUSB),y)
AIC8800_MODULE_SUBDIRS += src/USB/driver_fw/drivers/aic_btusb
AIC8800_MODULE_MAKE_OPTS += CONFIG_AIC_BTUSB_SUPPORT=m
endif

define AIC8800_INSTALL_FIRMWARE
	mkdir -p $(TARGET_DIR)/lib/firmware/
	cp -a $(@D)/src/USB/driver_fw/fw/* \
		$(TARGET_DIR)/lib/firmware/
endef
AIC8800_POST_INSTALL_TARGET_HOOKS += AIC8800_INSTALL_FIRMWARE

$(eval $(kernel-module))
$(eval $(generic-package))

################################################################################
# host-aic8800 -- build modules for the host kernel
################################################################################

HOST_AIC8800_KDIR = /lib/modules/$(shell uname -r)/build
HOST_AIC8800_MODDESTDIR = /lib/modules/$(shell uname -r)/kernel/drivers/net/wireless/aic8800

define HOST_AIC8800_BUILD_CMDS
	$(MAKE) -C $(HOST_AIC8800_KDIR) \
		M=$(@D)/src/USB/driver_fw/drivers/aic8800 \
		CONFIG_AIC_LOADFW_SUPPORT=m \
		CONFIG_AIC8800_WLAN_SUPPORT=m \
		CONFIG_PLATFORM_UBUNTU=y \
		CONFIG_PLATFORM_ROCKCHIP=n \
		CONFIG_PLATFORM_ALLWINNER=n \
		CONFIG_PLATFORM_AMLOGIC=n \
		CONFIG_PLATFORM_HI=n \
		modules
endef

define HOST_AIC8800_INSTALL_CMDS
	mkdir -p $(HOST_AIC8800_MODDESTDIR)
	$(INSTALL) -m 0644 \
		$(@D)/src/USB/driver_fw/drivers/aic8800/aic_load_fw/aic_load_fw.ko \
		$(HOST_AIC8800_MODDESTDIR)/
	$(INSTALL) -m 0644 \
		$(@D)/src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko \
		$(HOST_AIC8800_MODDESTDIR)/
	mkdir -p /lib/firmware/aic8800_fw/USB
	cp -a $(@D)/src/USB/driver_fw/fw/* /lib/firmware/aic8800_fw/USB/
	depmod -a $(shell uname -r)
endef

$(eval $(host-generic-package))
