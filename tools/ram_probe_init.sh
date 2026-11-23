#!/bin/sh
set -eu
export PATH=/bin:/sbin
umask 077

fail() {
    rc=$?
    trap - 0
    echo "RB06-RAM-PROBE stopped at $phase (status $rc). Rebooting the trial."
    /bin/busybox sleep 3
    /bin/busybox reboot -f
    while :; do /bin/busybox sleep 60; done
}

phase=initialization
trap fail 0
mount -t proc proc /proc
mount -t sysfs sysfs /sys
case " $(cat /proc/cmdline) " in *' firmware=1 '*) ;; *) exit 1 ;; esac
case " $(cat /proc/cmdline) " in *' factory_mode=1 '*) exit 1 ;; esac
[ "$(cat /sys/class/mtd/mtd9/name)" = ubi1 ]
[ "$(cat /sys/class/mtd/mtd10/name)" = overlay ]
for mtd in 9 10; do
    flags=$(cat "/sys/class/mtd/mtd$mtd/flags")
    [ "$((flags & 0x400))" -eq 0 ]
done
node() {
    numbers=$(cat "$3/dev")
    mknod "$1" "$2" "${numbers%:*}" "${numbers#*:}"
}

phase=copy-rootfs
mount -t tmpfs -o mode=0700,size=24m tmpfs /ram
node /dev/ubi_ctrl c /sys/class/misc/ubi_ctrl
if [ ! -r /sys/class/ubi/ubi0/mtd_num ]; then
    ubiattach /dev/ubi_ctrl --devn=0 --mtdn=9
fi
[ "$(cat /sys/class/ubi/ubi0/mtd_num)" = 9 ]
[ "$(cat /sys/class/ubi/ubi0_1/name)" = rootfs ]
node /dev/ubi0_1 c /sys/class/ubi/ubi0_1
node /dev/loop0 b /sys/class/block/loop0
dd if=/dev/ubi0_1 of=/ram/rb06-rootfs.squashfs bs=126976 count=127
result=$(md5sum </ram/rb06-rootfs.squashfs)
[ "${result%% *}" = 05fca9ffaad1fc6445d83b733ef62019 ]
mount -t squashfs -o ro,loop /ram/rb06-rootfs.squashfs /newroot
[ -x /newroot/sbin/init ]

phase=release-mtd9
ubidetach /dev/ubi_ctrl --mtdn=9
[ ! -e /sys/class/ubi/ubi0/mtd_num ]
echo 'PASS: mtd9 UBI detached after copying the original rootfs to RAM.' >/ram/rb06-ram-probe.log

phase=clone-read-only-data
[ ! -e /sys/class/ubi/ubi1/mtd_num ]
ubiattach /dev/ubi_ctrl --devn=1 --mtdn=10
[ "$(cat /sys/class/ubi/ubi1/mtd_num)" = 10 ]
[ "$(cat /sys/class/ubi/ubi1/ro_mode)" = 1 ]
[ "$(cat /sys/class/ubi/ubi1_0/name)" = data ]
mount -t ubifs -o ro ubi1_0 /source-data
mount -t tmpfs -o mode=0755,size=176m tmpfs /newroot/data
cp -a /source-data/. /newroot/data/
[ -s /newroot/data/etc/config/network ]
: >/newroot/data/.rb06-ram-probe
umount /source-data
ubidetach /dev/ubi_ctrl --mtdn=10
[ ! -e /sys/class/ubi/ubi1/mtd_num ]
echo 'PASS: read-only mtd10 copied to RAM and detached.' >>/ram/rb06-ram-probe.log

phase=install-ram-only-hooks
for path in lib/preinit/39_mount_ubi_data lib/preinit/80_mount_root etc/init.d/boot_check; do
    # Keep the bind sources on the RAM mount across switch_root.
    name=${path##*/}
    cp "/hooks/$name" "/ram/$name"
    mount -o bind "/ram/$name" "/newroot/$path"
done
mount -o move /ram /newroot/mnt

phase=start-oem-init
# Run from the loop-backed root so the timer survives switch_root.
chroot /newroot /bin/busybox sh -c 'sleep 600; /bin/busybox reboot -f' &
unset INITRAMFS PREINIT
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec /bin/busybox switch_root /newroot /sbin/init
