#!/bin/sh
set -eu
export LC_ALL=C
umask 077

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

case " $(cat /proc/cmdline) " in
    *' firmware=1 '*) ;;
    *) die 'expected the RAM trial boot from mtd9' ;;
esac
[ "$(cat /proc/xiaoqiang/ft_mode)" = 0 ] || die 'factory mode must be off'
marker=$(tr -d '\000' </sys/firmware/devicetree/base/chosen/rb06-fit-probe)
[ "$marker" = RB06-1.0.67-RAM-OVERLAY80-MIGRATE ] || die 'unexpected FIT marker'
grep -q ' /data tmpfs ' /proc/mounts || die 'the copied /data is not in RAM'
[ -f /data/.rb06-ram-probe ] || die 'the original data copy did not finish'
grep -q '^PASS: mtd9 UBI detached' /mnt/rb06-ram-probe.log || die 'missing mtd9 detach confirmation'
grep -q '^PASS: read-only mtd10 copied to RAM and detached' /mnt/rb06-ram-probe.log || die 'missing mtd10 detach confirmation'
root_dev=$(awk '$5=="/" {print $3; exit}' /proc/self/mountinfo)
backing=$(cat "/sys/dev/block/$root_dev/loop/backing_file")
[ "$backing" = /mnt/rb06-rootfs.squashfs ] || die "unexpected root backing file: $backing"
grep -q ' /mnt tmpfs ' /proc/mounts || die 'the root backing mount is not tmpfs'

alias=$(awk '$4 == "\"rb06-merge\"" {sub(/:$/, "", $1); sub(/^mtd/, "", $1); print $1}' /proc/mtd)
case "$alias" in ''|*[!0-9]*) die 'expected exactly one rb06-merge device' ;; esac
[ "$alias" -gt 10 ] || die 'unexpected device number for rb06-merge'
for f in /sys/class/ubi/ubi*/mtd_num; do
    [ -r "$f" ] || continue
    case "$(cat "$f")" in
        9|10|"$alias") die "a test range is still attached to UBI ($f)" ;;
    esac
done

check_mtd() {
    local id=$1 name=$2 offset=$3 size=$4 base
    base=/sys/class/mtd/mtd$id
    [ "$(cat "$base/name")" = "$name" ] || die "mtd$id label mismatch"
    [ "$(cat "$base/offset")" = "$offset" ] || die "mtd$id offset mismatch"
    [ "$(cat "$base/size")" = "$size" ] || die "mtd$id size mismatch"
    [ "$(cat "$base/erasesize")" = 131072 ] || die "mtd$id erase size mismatch"
    [ "$(cat "$base/writesize")" = 2048 ] || die "mtd$id write size mismatch"
}

check_mtd 9 ubi1 37748736 31457280
check_mtd 10 overlay 69206016 52428800
check_mtd "$alias" rb06-merge 37748736 83886080
for id in 9 10; do
    flags=$(cat "/sys/class/mtd/mtd$id/flags")
    [ "$((flags & 0x400))" -eq 0 ] || die "original mtd$id must remain read-only"
done
printf 'PASS: rb06-merge is mtd%s at 0x02400000, size 0x05000000; mtd9 and mtd10 are read-only.\n' "$alias"

grep -q ' /dev tmpfs ' /proc/mounts || die '/dev is not tmpfs'
grep -q ' /tmp tmpfs ' /proc/mounts || die '/tmp is not tmpfs'
devdir=$(mktemp -d /dev/rb06-overlay80-check.XXXXXX)
scratch=
cleanup() {
    rm -f "$devdir/first" "$devdir/second" "$devdir/merged"
    rmdir "$devdir"
    if [ -n "$scratch" ]; then
        rm -f "$scratch/original" "$scratch/alias"
        rmdir "$scratch"
    fi
}
trap cleanup 0
scratch=$(mktemp -d /tmp/rb06-overlay80-check.XXXXXX)

make_node() {
    local path=$1 id=$2 devno
    devno=$(cat "/sys/class/mtd/mtd$id/dev")
    mknod "$path" c "${devno%:*}" "${devno#*:}"
    [ -c "$path" ] || die "missing MTD character device: $path"
}
make_node "$devdir/first" 9
make_node "$devdir/second" 10
make_node "$devdir/merged" "$alias"

compare_range() {
    local original=$1 offset=$2 total=$3 start=0 count expected
    while [ "$start" -lt "$total" ]; do
        count=$((total - start))
        if [ "$count" -gt 32 ]; then count=32; fi
        expected=$((count * 131072))
        dd if="$original" of="$scratch/original" bs=131072 skip="$start" count="$count" 2>/dev/null || die "read failed at original eraseblock $start"
        dd if="$devdir/merged" of="$scratch/alias" bs=131072 skip="$((offset + start))" count="$count" 2>/dev/null || die "read failed at alias eraseblock $((offset + start))"
        [ "$(wc -c <"$scratch/original")" -eq "$expected" ] || die 'short read from original partition'
        [ "$(wc -c <"$scratch/alias")" -eq "$expected" ] || die 'short read from alias'
        cmp -s "$scratch/original" "$scratch/alias" || die "mapping mismatch at alias eraseblock $((offset + start))"
        start=$((start + count))
    done
}

echo 'Comparing the full 30 MiB and 50 MiB ranges (reads only).'
compare_range "$devdir/first" 0 240
echo 'PASS: first 30 MiB of rb06-merge matches all of mtd9.'
compare_range "$devdir/second" 240 400
echo 'PASS: last 50 MiB of rb06-merge matches all of mtd10.'

flags=$(cat "/sys/class/mtd/mtd$alias/flags")
[ "$((flags & 0x400))" -ne 0 ] || die 'mapping verified, but the alias lacks MTD_WRITEABLE'
( : 3<>"$devdir/merged" ) || die 'mapping verified, but the kernel rejected the read/write open'
echo 'PASS: ALIAS_OPEN_RDWR_OK. No write or erase was issued.'
