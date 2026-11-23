#!/bin/sh
# Read the two original firmware volumes into RAM on an unmodified RB06 1.0.67.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
grep -q ' /tmp tmpfs ' /proc/mounts || die '/tmp is not tmpfs'
[ "$(cat /proc/xiaoqiang/ft_mode)" = 0 ] || die 'expected ordinary boot mode'
slot=$(cat /sys/class/ubi/ubi0/mtd_num)
case "$slot" in 8|9) ;; *) die 'the system is not running from an original RB06 slot' ;; esac
[ "$(cat /sys/class/ubi/ubi1/mtd_num)" = 10 ] || die 'expected the original mtd10 /data'
grep -Eq '^mtd10:[[:space:]]+03200000[[:space:]]+00020000[[:space:]]+"overlay"$' /proc/mtd || die 'original mtd10 layout not found'
[ "$(cat /sys/class/ubi/ubi0_0/name)" = kernel ] || die 'expected the original kernel volume at ubi0_0'
[ "$(cat /sys/class/ubi/ubi0_1/name)" = rootfs ] || die 'expected the original rootfs volume at ubi0_1'
[ -c /dev/ubi0_0 ] && [ -c /dev/ubi0_1 ] || die 'original UBI character devices are unavailable'

work=/tmp/rb06-source
[ ! -L "$work" ] || die 'source directory is a symbolic link'
mkdir -p "$work"
chmod 700 "$work"
dd if=/dev/ubi0_0 of="$work/kernel.fit" bs=126976 count=26
dd if=/dev/ubi0_1 of="$work/rootfs.squashfs" bs=126976 count=127
[ "$(wc -c < "$work/kernel.fit")" -eq 3301376 ] || die 'kernel FIT read length mismatch'
[ "$(wc -c < "$work/rootfs.squashfs")" -eq 16125952 ] || die 'rootfs read length mismatch'
md5sum "$work/kernel.fit" "$work/rootfs.squashfs"
printf 'Saved the two read-only volume dumps from mtd%s in %s\n' "$slot" "$work"
