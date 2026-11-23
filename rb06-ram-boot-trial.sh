#!/bin/sh
# RB06 1.0.67 only. Stage either probe after booting original slot 0.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

RAM_FIT=/tmp/RB06-1.0.67-ram-boot-test.fit
RAM_FIT_BYTES=4415076
RAM_FIT_MD5=f7b58b45e24d5593792b385891ae5667
MIGRATION_FIT=/tmp/RB06-1.0.67-ram-overlay80-migrate.fit
MIGRATION_FIT_BYTES=4420144
MIGRATION_FIT_MD5=d90374f1dea82a412f29db7acf6d7123
OEM_KERNEL=7c0d72265ab338b991e8cd798198e8ee
OEM_ROOTFS=05fca9ffaad1fc6445d83b733ef62019

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect() { [ "$1" = "$2" ] || die "expected $2 for $3, got '$1'"; }
mtd_num() { cat "/sys/class/ubi/ubi$1/mtd_num"; }
vol_name() { cat "/sys/class/ubi/ubi$1_$2/name"; }

check_mtd() {
    local target=$1 name=$2 length=$3 base
    base="/sys/class/mtd/mtd$target"
    expect "$(cat "$base/name")" "$name" "mtd$target label"
    expect "$(cat "$base/size")" "$length" "mtd$target size"
    expect "$(cat "$base/erasesize")" 131072 "mtd$target erase size"
}

start_checks() {
    local slot=$1 field
    case " $(cat /proc/cmdline) " in *" firmware=$slot "*) ;; *) die "must be running firmware=$slot" ;; esac
    expect "$(cat /proc/xiaoqiang/ft_mode)" 0 'factory mode'
    expect "$(nvram get flag_last_success)" "$slot" flag_last_success
    expect "$(nvram get flag_boot_rootfs)" "$slot" flag_boot_rootfs
    expect "$(nvram get flag_boot_success)" 1 flag_boot_success
    expect "$(nvram get flag_ota_reboot)" 0 flag_ota_reboot
    for field in restore_defaults flag_format_overlay flag_data_mount_fail; do
        case "$(nvram get "$field" 2>/dev/null || :)" in
            ''|0) ;;
            *) die "$field is set" ;;
        esac
    done
    check_mtd 8 ubi 31457280
    check_mtd 9 ubi1 31457280
    check_mtd 10 overlay 52428800
    expect "$(mtd_num 0)" "$((slot + 8))" 'running UBI device'
    expect "$(mtd_num 1)" 10 'original data device'
    grep -q ' /data ubifs ' /proc/mounts || die 'original /data is not mounted'
    grep -q ' /tmp tmpfs ' /proc/mounts || die '/tmp must be tmpfs'
    grep -q ' /dev tmpfs ' /proc/mounts || die '/dev must be tmpfs'
    [ -c /dev/ubi_ctrl ] || die 'missing /dev/ubi_ctrl'
}

new_workspace() {
    devices=$(mktemp -d /dev/rb06-ram-test.XXXXXX)
    trap 'rm -f "$devices/control" "$devices/kernel" "$devices/rootfs" "$devices/test"; rmdir "$devices"' 0
}

make_node() {
    local path=$1 attr=$2 devno
    devno=$(cat "$attr/dev")
    mknod "$path" c "${devno%:*}" "${devno#*:}"
}

prefix_md5() {
    local input=$1 bytes=$2 sum
    sum=$(head -c "$bytes" "$input" | md5sum)
    printf '%s\n' "${sum%% *}"
}

attach_inactive() {
    local target=$1
    if [ ! -r /sys/class/ubi/ubi2/mtd_num ]; then
        ubiattach /dev/ubi_ctrl --devn=2 --mtdn="$target"
    fi
    expect "$(mtd_num 2)" "$target" 'inactive UBI device'
    expect "$(cat /sys/class/ubi/ubi2/ro_mode)" 0 'inactive UBI read-only mode'
    expect "$(vol_name 2 1)" rootfs 'inactive rootfs volume'
    make_node "$devices/control" /sys/class/ubi/ubi2
    make_node "$devices/kernel" /sys/class/ubi/ubi2_0
    make_node "$devices/rootfs" /sys/class/ubi/ubi2_1
}

arm_trial() {
    nvram set flag_ota_reboot=1
    nvram commit
    sync
}

switch_8() {
    start_checks 1
    new_workspace
    attach_inactive 8
    expect "$(vol_name 2 0)" kernel 'mtd8 kernel volume'
    expect "$(prefix_md5 "$devices/kernel" 3301376)" "$OEM_KERNEL" 'mtd8 original FIT'
    expect "$(prefix_md5 "$devices/rootfs" 16125952)" "$OEM_ROOTFS" 'mtd8 original rootfs'
    ubidetach /dev/ubi_ctrl --mtdn=8
    arm_trial
    echo 'MTD8_ORIGINAL_TRIAL_ARMED. Run reboot manually.'
}

known_trial_fit() {
    local volume=$1
    if [ "$(prefix_md5 "$volume" "$RAM_FIT_BYTES")" = "$RAM_FIT_MD5" ]; then
        return 0
    fi
    [ "$(prefix_md5 "$volume" "$MIGRATION_FIT_BYTES")" = "$MIGRATION_FIT_MD5" ]
}

stage_9() {
    local fit=$1 bytes=$2 digest=$3 armed=$4 sum
    start_checks 0
    expect "$(vol_name 0 0)" kernel 'active original kernel volume'
    expect "$(prefix_md5 /dev/ubi0_0 3301376)" "$OEM_KERNEL" 'active mtd8 original FIT'
    expect "$(wc -c < "$fit" | tr -d ' ')" "$bytes" 'test FIT size'
    sum=$(md5sum < "$fit")
    expect "${sum%% *}" "$digest" 'test FIT digest'
    new_workspace
    attach_inactive 9
    expect "$(prefix_md5 "$devices/rootfs" 16125952)" "$OEM_ROOTFS" 'mtd9 original rootfs'
    case "$(vol_name 2 0)" in
        kernel)
            expect "$(prefix_md5 "$devices/kernel" 3301376)" "$OEM_KERNEL" 'mtd9 original FIT'
            if [ ! -d /sys/class/ubi/ubi2_2 ]; then
                ubimkvol "$devices/control" -n 2 -N kernel-ramtest -s "$bytes"
            fi
            expect "$(vol_name 2 2)" kernel-ramtest 'temporary mtd9 kernel volume'
            make_node "$devices/test" /sys/class/ubi/ubi2_2
            ubiupdatevol "$devices/test" "$fit"
            expect "$(prefix_md5 "$devices/test" "$bytes")" "$digest" 'test FIT readback'
            ubirename "$devices/control" kernel kernel-before-ramtest kernel-ramtest kernel
            ;;
        kernel-before-ramtest)
            expect "$(vol_name 2 2)" kernel 'mtd9 trial kernel'
            make_node "$devices/test" /sys/class/ubi/ubi2_2
            if [ "$(prefix_md5 "$devices/test" "$bytes")" != "$digest" ]; then
                known_trial_fit "$devices/test" || die 'unknown FIT in the existing mtd9 trial volume'
                ubiupdatevol "$devices/test" "$fit"
            fi
            ;;
        *) die 'unexpected kernel names on mtd9' ;;
    esac
    expect "$(vol_name 2 0)" kernel-before-ramtest 'preserved mtd9 kernel'
    expect "$(vol_name 2 2)" kernel 'mtd9 trial kernel'
    expect "$(prefix_md5 "$devices/test" "$bytes")" "$digest" 'selected trial FIT'
    ubidetach /dev/ubi_ctrl --mtdn=9
    arm_trial
    echo "$armed. Run reboot manually."
}

restore_9() {
    start_checks 0
    new_workspace
    attach_inactive 9
    expect "$(vol_name 2 0)" kernel-before-ramtest 'preserved mtd9 kernel'
    expect "$(vol_name 2 2)" kernel 'mtd9 trial kernel'
    expect "$(prefix_md5 "$devices/kernel" 3301376)" "$OEM_KERNEL" 'preserved original mtd9 FIT'
    make_node "$devices/test" /sys/class/ubi/ubi2_2
    known_trial_fit "$devices/test" || die 'unknown FIT in the existing mtd9 trial volume'
    ubirename "$devices/control" kernel kernel-ramtest kernel-before-ramtest kernel
    expect "$(vol_name 2 0)" kernel 'restored kernel name'
    ubirmvol "$devices/control" -n 2
    ubidetach /dev/ubi_ctrl --mtdn=9
    sync
    echo 'MTD9_PREVIOUS_FIT_RESTORED. Current slot is still mtd8.'
}

case "${1:-}" in
    switch-8) switch_8 ;;
    stage-9) stage_9 "$RAM_FIT" "$RAM_FIT_BYTES" "$RAM_FIT_MD5" MTD9_RAM_TRIAL_ARMED ;;
    stage-migrate) stage_9 "$MIGRATION_FIT" "$MIGRATION_FIT_BYTES" "$MIGRATION_FIT_MD5" MTD9_RAM_MIGRATION_ARMED ;;
    restore-9) restore_9 ;;
    *) die 'usage: rb06-ram-boot-trial.sh switch-8 | stage-9 | stage-migrate | restore-9' ;;
esac
