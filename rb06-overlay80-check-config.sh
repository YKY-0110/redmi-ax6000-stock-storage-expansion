#!/bin/sh
# Recheck the saved configuration against the running RB06 /data.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 2 ] || die 'usage: rb06-overlay80-check-config.sh <archive in /tmp> <recorded MD5>'
archive=$1
expected=$(printf '%s' "$2" | tr 'A-F' 'a-f')
case "$archive" in /tmp/*) ;; *) die 'put the verified backup in /tmp' ;; esac
case "$expected" in ''|*[!a-f0-9]*) die 'invalid recorded MD5' ;; esac
[ "${#expected}" -eq 32 ] || die 'invalid recorded MD5 length'
grep -q ' /tmp tmpfs ' /proc/mounts || die '/tmp is not tmpfs'
grep -q ' /data ubifs ' /proc/mounts || die '/data must be mounted from UBIFS'
sum=$(md5sum < "$archive")
[ "${sum%% *}" = "$expected" ] || die 'archive does not match the recorded MD5'

scratch=$(mktemp -d /tmp/rb06-config-check.XXXXXX)
trap 'rm -r "$scratch"' 0
reference=$scratch/reference
mkdir "$reference"
tar -tzf "$archive" > "$scratch/members"

# Extract only saved configuration directories. tar uses the recorded names.
set --
for item in etc ini .ssh root/.ssh ssh; do
    member=$(awk -v item="$item" '{name=$0; sub(/^\.\//,"",name); sub(/\/$/,"",name); if (name==item) {print; exit}}' "$scratch/members")
    if [ -n "$member" ]; then set -- "$@" "${member%/}"; fi
done
[ "$#" -gt 0 ] || die 'backup does not contain a configuration directory'
tar -xzpf "$archive" -C "$reference" "$@"
[ -d "$reference/etc/config" ] || die 'backup etc/config was not extracted'

cat > "$scratch/check-entry.sh" <<'ENTRY'
set -eu
base=$1
saved=$2
relative=${saved#"$base/"}
live=/data/$relative
report() { printf '%s %s\n' "$1" "/data/$relative"; }
if [ ! -e "$live" ] && [ ! -L "$live" ]; then
    report MISSING
    exit 0
fi
saved_meta=$(stat -c '%f %u %g' "$saved")
live_meta=$(stat -c '%f %u %g' "$live")
if [ "$saved_meta" != "$live_meta" ]; then
    report CHANGED_METADATA_OR_TYPE
elif [ -L "$saved" ]; then
    saved_link=$(readlink "$saved" && printf .)
    live_link=$(readlink "$live" && printf .)
    if [ "$saved_link" = "$live_link" ]; then report OK; else report CHANGED_LINK; fi
elif [ -f "$saved" ]; then
    if cmp -s "$saved" "$live"; then report OK; else report CHANGED_CONTENT; fi
elif [ -d "$saved" ]; then
    report OK
else
    report UNSUPPORTED_ENTRY
fi
ENTRY

count=0
: > "$scratch/results"
for member do
    relative=${member#./}
    relative=${relative%/}
    path=$reference/$relative
    find "$path" -exec /bin/sh "$scratch/check-entry.sh" "$reference" '{}' \; >> "$scratch/results"
    entries=$(find "$path" | wc -l)
    count=$((count + entries))
done
results=$(wc -l < "$scratch/results")
[ "$count" -eq "$results" ] || die 'an entry check failed before recording a result'
if grep -v '^OK ' "$scratch/results"; then
    printf 'Compared %s saved entries. Review the differences above.\n' "$count"
    exit 2
fi
printf 'PASS: all %s saved configuration entries match.\n' "$count"
