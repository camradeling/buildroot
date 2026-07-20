setenv fdt_high ffffffff

# Force DO outputs low before kernel boots (PC6=DO5, PH4=DO6, PH5=DO7)
gpio clear 70
gpio clear 228
gpio clear 229

setenv bootslot slot1
setenv rootpart /dev/mmcblk0p2

if fatload mmc 0:1 ${kernel_addr_r} active 1; then
    if itest.b *${kernel_addr_r} == 0x32; then
        setenv bootslot slot2
        setenv rootpart /dev/mmcblk0p3
    fi
fi

setenv bootargs "console=ttyS0,115200 earlyprintk root=${rootpart} rootwait init=/sbin/overlayroot2.sh"
fatload mmc 0 ${kernel_addr_r} ${bootslot}/Image
fatload mmc 0 ${fdt_addr_r} ${bootslot}/sun50i-h618-orangepi-zero3.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
