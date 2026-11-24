################################################################################
#
# xray
#
################################################################################

XRAY_VERSION = 26.3.27
XRAY_SITE = https://github.com/XTLS/Xray-core/releases/download/v$(XRAY_VERSION)
# Upstream's asset name carries no version, and Buildroot names the downloaded
# file after the URL's basename, so every version lands on the same
# dl/xray/Xray-linux-arm64-v8a.zip. After bumping XRAY_VERSION the hash check
# will fail on the stale file - remove it and let it download again.
XRAY_SOURCE = Xray-linux-arm64-v8a.zip
XRAY_LICENSE = MPL-2.0
XRAY_LICENSE_FILES = LICENSE

# This is upstream's prebuilt, statically linked binary: there is nothing to
# configure or build. See Config.in for why it is not built from source.
define XRAY_EXTRACT_CMDS
	$(UNZIP) $(XRAY_DL_DIR)/$(XRAY_SOURCE) -d $(@D)
endef

define XRAY_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/xray $(TARGET_DIR)/usr/bin/xray
endef

$(eval $(generic-package))
