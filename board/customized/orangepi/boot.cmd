setenv fdt_high ffffffff

setenv bootslot slot1
setenv rootpart /dev/mmcblk0p2

if fatload mmc 0:1 ${kernel_addr_r} active 1; then
    if itest.b *${kernel_addr_r} == 0x32; then
        setenv bootslot slot2
        setenv rootpart /dev/mmcblk0p3
    fi
fi

setenv bootargs "console=ttyS0,115200 earlyprintk root=${rootpart} rootwait init=/sbin/overlayroot2.sh"
fatload mmc 0 ${kernel_addr_r} ${bootslot}/zImage
fatload mmc 0 ${fdt_addr_r} ${bootslot}/sun8i-h2-plus-orangepi-zero.dtb
bootz ${kernel_addr_r} - ${fdt_addr_r}
