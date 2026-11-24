################################################################################
#
# rtl88xx-aircrack
#
################################################################################

# Only version 5.2.20- works with kernels older than 4.14

RTL88XX_SPECIAL_VERSION = v5.6.4.2
RTL88XX_SPECIAL_SITE = https://github.com/camradeling/rtl88XX.git
RTL88XX_SPECIAL_SITE_METHOD = git

define RTL88XX_SPECIAL_BUILD_CMDS
	@echo "---------------------------------------------------------------------------"
	@echo "custom command used"
	$(TARGET_MAKE_ENV) $(MAKE) \
	    $(TARGET_CONFIGURE_OPTS) \
	    CONFIG_88XXAU=m \
	    ARCH=$(shell echo $(BR2_ARCH) | sed -e "s/aarch64/arm64/;") \
	    CROSS_COMPILE=$(TARGET_CROSS) \
	    KVER=$(LINUX_VERSION_PROBED) \
	    KSRC=$(LINUX_DIR) \
	    USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT" \
	    -C $(@D)
endef

define RTL88XX_SPECIAL_INSTALL_TARGET_CMDS
	[ -d $(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED)/extra ] || mkdir $(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED)/extra
	$(INSTALL) -D -m 0644 $(@D)/88XXau.ko $(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED)/extra/
endef

$(eval $(kernel-module))
$(eval $(generic-package))
