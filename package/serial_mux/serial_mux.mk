################################################################################
#
# serial_mux
#
################################################################################

SERIAL_MUX_VERSION = b5b680764997ce9575e746649f6ab17305fd814a
SERIAL_MUX_SITE = https://github.com/camradeling/serial_mux.git
SERIAL_MUX_SITE_METHOD = git
SERIAL_MUX_LICENSE = PROPRIETARY
SERIAL_MUX_CONF_OPTS = \
	-DCMAKE_INSTALL_SYSCONFDIR=/etc \
	-DINSTALL_INI_TO_SYSCONFDIR=ON \
	-DINSTALL_SYSTEMD_SERVICE=ON

define SERIAL_MUX_INSTALL_INIT_SYSTEMD
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	$(if $(BR2_PACKAGE_SERIAL_MUX_ENABLE_ISP),\
		ln -sf ../serial_mux@.service \
			$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/serial_mux@isp.service)
	$(if $(BR2_PACKAGE_SERIAL_MUX_ENABLE_MCU),\
		ln -sf ../serial_mux@.service \
			$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/serial_mux@mcu.service)
endef

$(eval $(cmake-package))
