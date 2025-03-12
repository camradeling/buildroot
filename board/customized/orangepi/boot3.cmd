setenv fdt_high ffffffff

setenv bootdir default
setenv rootpart /dev/mmcblk0p2
fatload mmc 0:1 ${kernel_addr_r} bootok 1; if itest.b *${kernel_addr_r} == 1; then setenv flagbyte 1; else setenv flagbyte 0; fi; mw ${kernel_addr_r} 0 1; fatwrite mmc 0:1 ${kernel_addr_r} bootok 1;
if itest.b ${flagbyte} == 1; then setenv bootdir updated;setenv rootpart /dev/mmcblk0p3; else setenv bootdir default;setenv rootpart /dev/mmcblk0p2; fi;
setenv bootargs "console=ttyS0,115200 earlyprintk root=${rootpart} rootwait init=/sbin/overlayroot2.sh"
fatload mmc 0 $kernel_addr_r ${bootdir}/Image
fatload mmc 0 $fdt_addr_r ${bootdir}/sun50i-h618-orangepi-zero3.dtb
booti $kernel_addr_r - $fdt_addr_r
