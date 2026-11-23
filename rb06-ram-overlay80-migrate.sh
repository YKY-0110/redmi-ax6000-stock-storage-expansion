#!/bin/sh
# RB06 1.0.67 RAM migration. Prepare only reads the old data partition.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

WORK=/tmp/rb06-migrate
DEV=/dev/rb06-migrate
LOCK=/mnt/.rb06-migrate-lock
SERVICE=rb06-overlay80-migration
FINAL=$WORK/final.fit
BACKUP=$WORK/original-data.tar.gz
OLD=$WORK/source
NEW=$WORK/restored
BYTES=3301376
FINAL_MD5=9b865f68aae729b5bde371a5494e404a
STOCK_KERNEL=7c0d72265ab338b991e8cd798198e8ee
STOCK_ROOTFS=05fca9ffaad1fc6445d83b733ef62019

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect() { [ "$1" = "$2" ] || die "expected $2 for $3, got '$1'"; }
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
digest() { local sum; sum=$(md5sum <"$1") || return 1; printf '%s\n' "${sum%% *}"; }
prefix_md5() { local sum; sum=$(head -c "$2" "$1" | md5sum); printf '%s\n' "${sum%% *}"; }
mtd_num() { cat "/sys/class/ubi/ubi$1/mtd_num"; }
volume() { cat "/sys/class/ubi/ubi$1_$2/name"; }

boot_flags() {
    local key
    expect "$(nvram get flag_boot_rootfs)" 1 flag_boot_rootfs
    expect "$(nvram get flag_last_success)" 0 flag_last_success
    expect "$(nvram get flag_boot_success)" 0 flag_boot_success
    expect "$(nvram get flag_ota_reboot)" 1 flag_ota_reboot
    for key in restore_defaults flag_format_overlay flag_data_mount_fail; do
        case "$(nvram get "$key" 2>/dev/null || :)" in ''|0) ;; *) die "$key is set" ;; esac
    done
}

alias_id() {
    local id
    id=$(awk -v name="\"$1\"" '$4==name {sub(/:$/, "", $1); sub(/^mtd/, "", $1); print $1}' /proc/mtd)
    case "$id" in ''|*[!0-9]*) return 1 ;; esac
    [ "$id" -gt 10 ] || return 1
    printf '%s\n' "$id"
}

check_mtd() {
    local id=$1 name=$2 offset=$3 size=$4 base
    base=/sys/class/mtd/mtd$id
    expect "$(cat "$base/name")" "$name" "mtd$id label"
    expect "$(cat "$base/offset")" "$offset" "mtd$id offset"
    expect "$(cat "$base/size")" "$size" "mtd$id size"
    expect "$(cat "$base/erasesize")" 131072 "mtd$id erase size"
    expect "$(cat "$base/writesize")" 2048 "mtd$id write size"
}

check_env() {
    local marker flags id path
    marker=$(tr -d '\000' </sys/firmware/devicetree/base/chosen/rb06-fit-probe)
    expect "$marker" RB06-1.0.67-RAM-OVERLAY80-MIGRATE 'migration FIT marker'
    expect "$(cat /proc/xiaoqiang/ft_mode)" 0 'factory mode'
    boot_flags
    for path in /tmp /dev /mnt /data; do
        grep -q " $path tmpfs " /proc/mounts || die "$path must be in RAM"
    done
    [ -f /data/.rb06-ram-probe ] || die 'RAM data copy missing'
    MERGE=$(alias_id rb06-merge) || die 'missing 80 MiB alias'
    ROLLBACK=$(alias_id rb06-rollback) || die 'missing 50 MiB rollback alias'
    check_mtd 8 ubi 6291456 31457280
    check_mtd 9 ubi1 37748736 31457280
    check_mtd 10 overlay 69206016 52428800
    check_mtd "$MERGE" rb06-merge 37748736 83886080
    check_mtd "$ROLLBACK" rb06-rollback 69206016 52428800
    for id in 8 "$MERGE" "$ROLLBACK"; do
        flags=$(cat "/sys/class/mtd/mtd$id/flags")
        [ "$((flags & 0x400))" -ne 0 ] || die "mtd$id is read-only"
    done
    for id in 9 10; do
        flags=$(cat "/sys/class/mtd/mtd$id/flags")
        [ "$((flags & 0x400))" -eq 0 ] || die "original mtd$id is not read-only"
    done
    for path in /sys/class/ubi/ubi*/mtd_num; do
        [ -r "$path" ] || continue
        case "$(cat "$path")" in
            9|10|"$MERGE"|"$ROLLBACK") die "one of the data ranges is attached to UBI ($path)" ;;
        esac
    done
    mkdir -p "$WORK" "$DEV" "$OLD" "$NEW"
    chmod 700 "$WORK" "$DEV"
    expect "$(wc -c <"$FINAL" | tr -d ' ')" "$BYTES" 'final FIT size'
    expect "$(digest "$FINAL")" "$FINAL_MD5" 'final FIT digest'
}

node() {
    local file=$1 attr=$2 number
    number=$(cat "$attr/dev") || return 1
    rm -f "$file" || return 1
    mknod "$file" c "${number%:*}" "${number#*:}"
}

verify_rollback_alias() {
    local block
    node "$DEV/original-data" /sys/class/mtd/mtd10
    node "$DEV/rollback" "/sys/class/mtd/mtd$ROLLBACK"
    for block in 0 399; do
        dd if="$DEV/original-data" of="$WORK/original.sample" bs=131072 skip="$block" count=1 2>/dev/null
        dd if="$DEV/rollback" of="$WORK/rollback.sample" bs=131072 skip="$block" count=1 2>/dev/null
        [ "$(wc -c <"$WORK/original.sample")" -eq 131072 ] || die 'short data sample'
        cmp "$WORK/original.sample" "$WORK/rollback.sample" || die 'rollback alias does not match mtd10'
    done
    ( : 3<>"$DEV/rollback" ) || die 'kernel rejected opening the rollback alias for read/write'
}

manifest() (
    cd "$1" || return 1
    find . -xdev -exec /bin/sh "$WORK/manifest-entry.sh" '{}' \; > "$2.raw" || return 1
    if grep -q '^ERROR' "$2.raw"; then return 1; fi
    sort "$2.raw" > "$2"
)

test_archive() {
    local fixture
    cat > "$WORK/manifest-entry.sh" <<'ENTRY'
set -eu
trap 'if [ "$?" -ne 0 ]; then echo ERROR; fi' 0
path=$1
path_hash=$(printf '%s' "$path" | md5sum)
metadata=$(stat -c '%f %u %g' "$path")
if [ -L "$path" ]; then
    target=$(readlink "$path" && printf '.')
    payload=$(printf '%s' "$target" | md5sum)
elif [ -f "$path" ]; then
    payload=$(md5sum < "$path")
    metadata="$metadata $(stat -c %h "$path")"
elif [ -d "$path" ]; then
    payload=directory
else
    echo 'ERROR unsupported archive entry type'; exit 1
fi
printf '%s|%s|%s\n' "$path_hash" "$metadata" "$payload"
ENTRY
    fixture=$(mktemp -d "$WORK/archive-test.XXXXXX")
    mkdir "$fixture/source" "$fixture/extracted"
    printf 'config\n' >"$fixture/source/auth key"
    chmod 600 "$fixture/source/auth key"
    ln "$fixture/source/auth key" "$fixture/source/hardlink"
    ln -s 'auth key' "$fixture/source/symlink"
    tar -czf "$fixture/data.tar.gz" -C "$fixture/source" .
    tar -xzpf "$fixture/data.tar.gz" -C "$fixture/extracted"
    manifest "$fixture/source" "$fixture/before"
    manifest "$fixture/extracted" "$fixture/after"
    cmp "$fixture/before" "$fixture/after"
}

prepare_cleanup() {
    if grep -q " $OLD " /proc/mounts; then umount "$OLD" || :; fi
    if [ -r /sys/class/ubi/ubi1/mtd_num ] && [ "$(mtd_num 1)" = 10 ]; then
        ubidetach /dev/ubi_ctrl --mtdn=10 || :
    fi
}

prepare() {
    check_env
    [ ! -e /sys/class/ubi/ubi1/mtd_num ] || die 'UBI device 1 is unavailable'
    mkdir "$LOCK" || die 'the timer or another operation already owns the migration lock'
    trap prepare_cleanup 0
    say 'Automatic trial reboot is suspended. Original flash data is still intact.'
    sh /mnt/rb06-check-overlay80.sh
    verify_rollback_alias
    test_archive

    say 'Archiving the original read-only mtd10, before any flash writes.'
    ubiattach /dev/ubi_ctrl --devn=1 --mtdn=10
    expect "$(mtd_num 1)" 10 'source UBI'
    expect "$(cat /sys/class/ubi/ubi1/ro_mode)" 1 'source read-only mode'
    expect "$(volume 1 0)" data 'source data volume'
    mount -t ubifs -o ro ubi1_0 "$OLD"
    [ -s "$OLD/etc/config/network" ] || die 'original network configuration is missing'
    tar -czf "$BACKUP" -C "$OLD" .
    tar -tzf "$BACKUP" >/dev/null
    manifest "$OLD" "$WORK/original.manifest"
    umount "$OLD"
    ubidetach /dev/ubi_ctrl --mtdn=10
    trap - 0
    digest "$WORK/original.manifest" > "$WORK/manifest.md5"
    digest "$BACKUP" > "$WORK/backup.md5"
    md5sum "$BACKUP"
    say 'READY_BEFORE_ERASE. Download the backup and verify its MD5 on the computer.'
}

check_backup() {
    local from_pc
    from_pc=$(printf '%s' "$1" | tr 'A-F' 'a-f')
    test -d "$LOCK" || die 'run prepare in this RAM boot first'
    expect "$(digest "$BACKUP")" "$(cat "$WORK/backup.md5")" 'RAM backup digest'
    expect "$(digest "$BACKUP")" "$from_pc" 'computer backup digest'
    expect "$(digest "$WORK/original.manifest")" "$(cat "$WORK/manifest.md5")" 'source manifest digest'
}

stage_mtd8() {
    if [ ! -r /sys/class/ubi/ubi2/mtd_num ]; then
        ubiattach /dev/ubi_ctrl --devn=2 --mtdn=8
    fi
    expect "$(mtd_num 2)" 8 'inactive system slot'
    expect "$(cat /sys/class/ubi/ubi2/ro_mode)" 0 'mtd8 UBI read-only mode'
    expect "$(volume 2 0)" kernel 'fallback kernel name'
    expect "$(volume 2 1)" rootfs 'fallback rootfs name'
    node "$DEV/system" /sys/class/ubi/ubi2
    node "$DEV/oem-kernel" /sys/class/ubi/ubi2_0
    node "$DEV/oem-rootfs" /sys/class/ubi/ubi2_1
    expect "$(prefix_md5 "$DEV/oem-kernel" "$BYTES")" "$STOCK_KERNEL" 'original mtd8 FIT'
    expect "$(prefix_md5 "$DEV/oem-rootfs" 16125952)" "$STOCK_ROOTFS" 'original mtd8 rootfs'
    if [ ! -d /sys/class/ubi/ubi2_2 ]; then
        ubimkvol "$DEV/system" -n 2 -N kernel-next -s "$BYTES"
    fi
    expect "$(volume 2 2)" kernel-next 'mtd8 staging volume'
    node "$DEV/final-kernel" /sys/class/ubi/ubi2_2
    ubiupdatevol "$DEV/final-kernel" "$FINAL"
    expect "$(prefix_md5 "$DEV/final-kernel" "$BYTES")" "$FINAL_MD5" 'final FIT readback'
    say 'mtd8 final FIT pre-staged. Original mtd8 kernel is still selected.'
}

restore_volume() {
    local target=$1
    node "$DEV/write-range" "/sys/class/mtd/mtd$target" || return 1
    ubiformat "$DEV/write-range" --sub-page-size=2048 --yes || return 1
    ubiattach /dev/ubi_ctrl --devn=1 --mtdn="$target" || return 1
    [ "$(mtd_num 1)" = "$target" ] || return 1
    node "$DEV/data-control" /sys/class/ubi/ubi1 || return 1
    ubimkvol "$DEV/data-control" --vol_id=0 --name=data --maxavsize || return 1
    mount -t ubifs ubi1_0 "$NEW" || return 1
    tar -xzpf "$BACKUP" -C "$NEW" || return 1
    sync || return 1
    umount "$NEW" || return 1
    ubidetach /dev/ubi_ctrl --mtdn="$target" || return 1
    ubiattach /dev/ubi_ctrl --devn=1 --mtdn="$target" || return 1
    [ "$(mtd_num 1)" = "$target" ] || return 1
    [ "$(volume 1 0)" = data ] || return 1
    mount -t ubifs -o ro ubi1_0 "$NEW" || return 1
    manifest "$NEW" "$WORK/restored.manifest" || return 1
    cmp "$WORK/original.manifest" "$WORK/restored.manifest" || return 1
    [ -s "$NEW/etc/config/network" ] || return 1
    say "Restored /data files, modes, ownership and links verified on mtd$target."
}

reboot_8() { sync; /bin/busybox reboot -f; }

on_exit() {
    rc=$?
    trap - 0
    [ "$rc" -ne 0 ] || exit 0
    say "Stopped in $phase (status $rc)."
    if [ "$phase" = restore ] && [ "$(volume 2 0 2>/dev/null)" = kernel ]; then
        say 'Attempting rollback to the original 50 MiB data layout.'
        if grep -q " $NEW " /proc/mounts; then umount "$NEW" || exit "$rc"; fi
        if [ -r /sys/class/ubi/ubi1/mtd_num ]; then
            [ "$(mtd_num 1)" = "$MERGE" ] || exit "$rc"
            ubidetach /dev/ubi_ctrl --mtdn="$MERGE" || exit "$rc"
        fi
        if restore_volume "$ROLLBACK" && umount "$NEW" && ubidetach /dev/ubi_ctrl --mtdn="$ROLLBACK"; then
            boot_flags
            say 'Old 50 MiB data restored and verified; rebooting original mtd8.'
            reboot_8
        else
            say 'Rollback failed. Staying in RAM with the backup and log.'
        fi
    fi
    exit "$rc"
}

worker() {
    local size
    phase=before-erase
    trap on_exit 0
    check_env
    check_backup "$1"
    [ ! -r /sys/class/ubi/ubi1/mtd_num ] || die 'UBI device 1 is not free'
    stage_mtd8
    boot_flags

    phase=restore
    say 'Erasing the old mtd9+mtd10 ranges and rebuilding the 80 MiB data volume.'
    restore_volume "$MERGE"
    size=$(df -k "$NEW" | awk 'END {print $(NF-4)}')
    [ "$size" -gt 51200 ] || die 'new UBIFS did not expand beyond 50 MiB'
    say "New /data capacity verified: $size KiB."
    umount "$NEW"
    ubidetach /dev/ubi_ctrl --mtdn="$MERGE"
    boot_flags
    expect "$(prefix_md5 "$DEV/final-kernel" "$BYTES")" "$FINAL_MD5" 'final FIT readback'

    phase=activate
    ubirename "$DEV/system" kernel kernel-before-overlay80 kernel-next kernel
    expect "$(volume 2 0)" kernel-before-overlay80 'former mtd8 kernel'
    expect "$(volume 2 2)" kernel 'selected mtd8 kernel'
    ubidetach /dev/ubi_ctrl --mtdn=8
    say '80 MiB /data verified and final mtd8 FIT selected. Rebooting to mtd8.'
    reboot_8
}

probe_launcher() {
    local attempts=0
    check_env
    rm -f "$WORK/procd-probe.log"
    # Use the same supervisor and BusyBox path as the real worker.
    ubus call service set "{\"name\":\"rb06-overlay80-probe-$$\",\"instances\":{\"probe\":{\"command\":[\"/bin/busybox\",\"ash\",\"-c\",\"echo PROCD_LAUNCH_OK > /tmp/rb06-migrate/procd-probe.log\"]}}}" \
        || die 'procd rejected the launch probe'
    while [ ! -s "$WORK/procd-probe.log" ] && [ "$attempts" -lt 5 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
    [ -s "$WORK/procd-probe.log" ] || die 'procd did not start the probe'
    expect "$(cat "$WORK/procd-probe.log")" PROCD_LAUNCH_OK 'launch probe output'
    echo PROCD_LAUNCH_OK
}

launch_worker() {
    local from_pc digest_arg payload
    from_pc=$1
    check_env
    check_backup "$from_pc"
    expect "$(cat "$WORK/procd-probe.log" 2>/dev/null || :)" PROCD_LAUNCH_OK 'launch probe; run probe-launch first'
    mkdir "$WORK/started" || die 'a worker has already been launched in this RAM boot'
    cp "$0" "$WORK/worker.sh"
    digest_arg=$(cat "$WORK/backup.md5")
    case "$digest_arg" in ''|*[!a-f0-9]*) die 'invalid backup digest for worker launch' ;; esac
    expect "${#digest_arg}" 32 'backup MD5 length'
    payload=$(printf '{"name":"%s","instances":{"worker":{"command":["/bin/busybox","ash","%s","worker","%s"]}}}' \
        "$SERVICE" "$WORK/worker.sh" "$digest_arg")
    ubus call service set "$payload" || die 'procd launch request failed; keep the RAM backup and inspect the service before retrying'
    say "Migration submitted to procd. Log: $WORK/migration.log"
}

case "${1:-}" in
    prepare) prepare ;;
    probe-launch) probe_launcher ;;
    start)
        [ "$#" -eq 2 ] || die 'usage: start <MD5 of the downloaded backup>'
        launch_worker "$2"
        ;;
    worker)
        [ "$0" = "$WORK/worker.sh" ] && [ -d "$WORK/started" ] || die 'launch the worker with start'
        exec </dev/null >> "$WORK/migration.log" 2>&1
        ( set -C; printf '%s\n' "$$" > "$WORK/worker-entered" ) || die 'another worker already entered'
        cd "$WORK"
        worker "$2"
        ;;
    *) die 'usage: rb06-ram-overlay80-migrate.sh prepare | probe-launch | start <backup MD5>' ;;
esac
