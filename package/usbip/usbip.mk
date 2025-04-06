################################################################################
#
# usbip - USB over IP networking utilities
#
################################################################################

# Use the same version as the Linux kernel being built
USBIP_VERSION = $(call qstrip,$(BR2_LINUX_KERNEL_VERSION))

# Use already downloaded kernel sources from Buildroot
USBIP_SITE = $(LINUX_DIR)
USBIP_SITE_METHOD = local  # Use local source tree
USBIP_AUTORECONF = YES
USBIP_SOURCE = #explicitly empty
# Path to usbip tools within kernel source tree
USBIP_OVERRIDE_SRCDIR = $(LINUX_DIR)/tools/usb/usbip

# Package dependencies
USBIP_DEPENDENCIES = linux libsysfs $(if $(BR2_PACKAGE_SYSTEMD),systemd,eudev)

# Pre-configure hook: Run autogen.sh
define USBIP_RUN_AUTOGEN
    cd ${USBIP_OVERRIDE_SRCDIR} && ./autogen.sh
endef
USBIP_PRE_CONFIGURE_HOOKS += USBIP_RUN_AUTOGEN

# Verify kernel sources exist before configuring
define USBIP_CHECK_LINUX_SOURCE
    if [ ! -d $(LINUX_DIR)/tools/usb/usbip ]; then \
        echo "Error: Linux source must be downloaded and extracted first"; \
        exit 1; \
    fi
endef
USBIP_PRE_CONFIGURE_HOOKS += USBIP_CHECK_LINUX_SOURCE

define USBIP_CHECK_KERNEL_VERSION
    if ! echo "$(BR2_LINUX_KERNEL_VERSION)" | grep -qE "^([4-9]\.|3\.[1-9][7-9])"; then \
        echo "Error: Kernel $(BR2_LINUX_KERNEL_VERSION) is too old. Need >= 3.17"; \
        exit 1; \
    fi
endef
USBIP_PRE_BUILD_HOOKS += USBIP_CHECK_KERNEL_VERSION

# Verify required kernel configurations are enabled
define USBIP_CHECK_KERNEL_CONFIG
    if ! grep -q "CONFIG_USBIP_CORE=[ym]" $(LINUX_DIR)/.config; then \
        echo "Error: CONFIG_USBIP_CORE not enabled in kernel config (needs 'y' or 'm')"; \
        echo "Enable it in: Device Drivers → USB support → USB/IP support"; \
        exit 1; \
    fi
    if grep -q "CONFIG_USBIP_CORE=m" $(LINUX_DIR)/.config && \
       ! grep -q "CONFIG_USBIP_HOST=[ym]" $(LINUX_DIR)/.config; then \
        echo "Error: CONFIG_USBIP_HOST required when USBIP_CORE is a module"; \
        exit 1; \
    fi
endef
USBIP_PRE_BUILD_HOOKS += USBIP_CHECK_KERNEL_CONFIG

define USBIP_BUILD_CMDS
    cd $(@D) && \
    autoreconf -i && \
    ./configure \
        CC="$(TARGET_CC)" \
        LD="$(TARGET_LD)" \
        CFLAGS="$(TARGET_CFLAGS) -fPIC" \
        LDFLAGS="$(TARGET_LDFLAGS) -Wl,--as-needed" \
        --host=$(GNU_TARGET_NAME) \
        --prefix=/usr \
        --enable-shared \
        --disable-static && \
    $(MAKE) all
endef

# Installation commands
define USBIP_INSTALL_TARGET_CMDS
    # Install binaries
    $(INSTALL) -D -m 0755 $(USBIP_SRCDIR)/src/usbip $(TARGET_DIR)/usr/bin/usbip
    $(INSTALL) -D -m 0755 $(USBIP_SRCDIR)/src/usbipd $(TARGET_DIR)/usr/sbin/usbipd
    # Install shared library and create symlinks
    $(INSTALL) -D -m 0755 $(@D)/libsrc/.libs/libusbip.so.* $(TARGET_DIR)/usr/lib/
    ln -sf libusbip.so.0 $(TARGET_DIR)/usr/lib/libusbip.so
endef

define USBIP_CLEAN_CMDS
    $(MAKE) -C $(USBIP_OVERRIDE_SRCDIR) clean
endef

$(eval $(autotools-package))
