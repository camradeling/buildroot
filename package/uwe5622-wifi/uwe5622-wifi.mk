################################################################################
#
# uwe5622-wifi
#
################################################################################

UWE5622_WIFI_VERSION = 393358405103481286cced949b6ef70652c5dcb7
UWE5622_WIFI_SITE = https://github.com/ovo4096/archlinux-linux-uwe5622
UWE5622_WIFI_SITE_METHOD = git
UWE5622_WIFI_LICENSE = GPL-2.0
UWE5622_WIFI_LICENSE_FILES = unisocwifi/main.c

# Required kernel config
define UWE5622_WIFI_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_CFG80211)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MMC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_BT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_PM)
endef

# Set Kconfig options that the driver Makefiles check
UWE5622_WIFI_MODULE_MAKE_OPTS = \
	CONFIG_AW_WIFI_DEVICE_UWE5622=y \
	CONFIG_WLAN_UWE5622=y \
	CONFIG_TTY_OVERY_SDIO=m

define UWE5622_WIFI_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/etc/modules-load.d
	printf 'uwe5622_bsp_sdio\nsprdwl_ng\nsprdbt_tty\n' \
		> $(TARGET_DIR)/etc/modules-load.d/uwe5622.conf
endef

$(eval $(kernel-module))
$(eval $(generic-package))
