"""Build the RB06 1.0.67 one-boot RAM probe from the original boot volumes."""

import hashlib
import os
import stat
import struct
import subprocess
import sys
from pathlib import Path

from build_overlay_fit import ALIAS, ALIAS_PATH, FDT, KERNEL, OVERLAY, SECOND, align4, check_hashes, digest, parse_fdt, values


HERE = Path(__file__).resolve().parent
CONFIG = "/configurations/config@1"
RAMDISK = "/images/ramdisk@rb06-probe"
MARKER = b"RB06-1.0.67-RAM-PROBE\0"
MIGRATION_MARKER = b"RB06-1.0.67-RAM-OVERLAY80-MIGRATE\0"
ROLLBACK_PATH = ALIAS_PATH.rpartition("/")[0] + "/rollback@4200000"
ROLLBACK = {"label": b"rb06-rollback\0", "reg": struct.pack(">2I", 0x4200000, 0x3200000)}
ROOTFS_MD5 = "05fca9ffaad1fc6445d83b733ef62019"

DATA_HOOK = b"""#!/bin/sh
rb06_ram_data() {
    if ! grep -q ' /data tmpfs ' /proc/mounts || [ ! -f /data/.rb06-ram-probe ]; then
        /bin/busybox reboot -f
        return 1
    fi
    mkdir -p /data/userdisk/data || return 1
    mount -o bind /data/userdisk /userdisk || return 1
    mount -o bind /readonly /userdisk/data || return 1
    pi_mount_skip_next=true
}
boot_hook_add preinit_mount_root rb06_ram_data
"""

ROOT_HOOK = b"""#!/bin/sh
rb06_ram_root() { boot_run_hook preinit_mount_root; }
boot_hook_add preinit_main rb06_ram_root
"""


def fdt_blob(template: bytes, nodes: dict[str, dict[str, bytes]]) -> bytes:
    header = list(struct.unpack_from(">10I", template))
    assert header[4] == 40 and header[5] == 17
    reservations = template[header[4]:header[2]]
    strings = bytearray()
    string_offsets = {}
    structure = bytearray()
    children = {path: [] for path in nodes}
    for path in nodes:
        if path:
            children[path.rpartition("/")[0]].append(path)

    def emit(path: str) -> None:
        name = path.rpartition("/")[2].encode() + b"\0"
        structure.extend(struct.pack(">I", 1) + name.ljust(align4(len(name)), b"\0"))
        for key, value in nodes[path].items():
            if key not in string_offsets:
                string_offsets[key] = len(strings)
                strings.extend(key.encode() + b"\0")
            structure.extend(struct.pack(">3I", 3, len(value), string_offsets[key]))
            structure.extend(value.ljust(align4(len(value)), b"\0"))
        for child in children[path]:
            emit(child)
        structure.extend(struct.pack(">I", 2))

    emit("")
    structure.extend(struct.pack(">I", 9))
    header[2] = header[4] + len(reservations)
    header[3] = header[2] + len(structure)
    header[8], header[9] = len(strings), len(structure)
    header[1] = header[3] + len(strings)
    output = struct.pack(">10I", *header) + reservations + structure + strings
    assert values(parse_fdt(output)) == nodes
    return output


def archive_newc(entries: list[tuple[str, int, bytes, int, int]]) -> bytes:
    def pad(payload: bytes) -> bytes:
        return payload.ljust(align4(len(payload)), b"\0")

    output = bytearray()
    for ino, (path, mode, data, major, minor) in enumerate(entries + [("TRAILER!!!", 0, b"", 0, 0)], 1):
        name = path.encode("ascii") + b"\0"
        fields = (ino, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0, len(data), 0, 0, major, minor, len(name), 0)
        record = b"070701" + b"".join(f"{field:08x}".encode("ascii") for field in fields)
        output.extend(pad(record + name))
        output.extend(pad(data))
    return bytes(output)


def make_archive(rootfs: Path, seven_zip: Path, *, migration: bool = False) -> bytes:
    def stock(path: str) -> bytes:
        return subprocess.check_output([str(seven_zip), "e", "-so", str(rootfs), path.replace("/", os.sep)])

    entries = [(path, stat.S_IFDIR | 0o755, b"", 0, 0) for path in
               ("bin", "sbin", "lib", "dev", "proc", "sys", "ram", "source-data", "newroot", "hooks")]
    for path, major, minor in (("dev/console", 5, 1), ("dev/null", 1, 3)):
        entries.append((path, stat.S_IFCHR | 0o600, b"", major, minor))
    for path in ("bin/busybox", "lib/libc.so", "lib/libgcc_s.so.1", "lib/librpc.so",
                 "usr/sbin/ubiattach", "usr/sbin/ubidetach"):
        data = stock(path)
        assert data[:4] == b"\x7fELF" and struct.unpack_from("<H", data, 18)[0] == 183
        entries.append((path.replace("usr/sbin/", "sbin/"), stat.S_IFREG | 0o755, data, 0, 0))
    entries.append(("lib/ld-musl-aarch64.so.1", stat.S_IFLNK | 0o777, b"libc.so", 0, 0))
    for applet in ("sh", "cat", "chroot", "cp", "dd", "md5sum", "mknod", "mount", "umount"):
        entries.append((f"bin/{applet}", stat.S_IFLNK | 0o777, b"busybox", 0, 0))

    boot_check = stock("etc/init.d/boot_check")
    assert boot_check.count(b"\n\tset_setup_flag\n") == 1
    boot_check = boot_check.replace(b"\n\tset_setup_flag\n", b"\n\t: # Keep the stock slot-0 fallback during the RAM trial.\n")
    init = (HERE / "ram_probe_init.sh").read_bytes()
    hooks = [("hooks/39_mount_ubi_data", DATA_HOOK), ("hooks/80_mount_root", ROOT_HOOK),
             ("hooks/boot_check", boot_check)]
    if migration:
        before_move = b"mount -o move /ram /newroot/mnt\n"
        assert init.count(before_move) == 1
        init = init.replace(before_move, b"cp /hooks/check-overlay80.sh /ram/rb06-check-overlay80.sh\n" + before_move)
        timer = b"sleep 600; /bin/busybox reboot -f"
        assert init.count(timer) == 1
        init = init.replace(timer, b"sleep 600; if mkdir /mnt/.rb06-migrate-lock 2>/dev/null; then /bin/busybox reboot -f; fi")
        checker = (HERE / "ram_probe_check_overlay80.sh").read_bytes()
        hooks.append(("hooks/check-overlay80.sh", checker))
    for path, data in [("init", init), *hooks]:
        assert b"\r" not in data
        entries.append((path, stat.S_IFREG | 0o755, data, 0, 0))
    return archive_newc(entries)


def build(source: bytes, archive: bytes, *, migration: bool = False) -> bytes:
    nodes = values(parse_fdt(source))
    check_hashes(nodes)
    assert not any("signature" in node for node in nodes)
    assert nodes[FDT]["description"].endswith(b"mt7986-RB06 device tree blob\0")
    assert set(nodes[CONFIG]) == {"description", "kernel", "fdt"}
    old_tree = nodes[FDT]["data"]
    tree = values(parse_fdt(old_tree))
    for path in (SECOND, OVERLAY):
        assert "read-only" not in tree[path]
        tree[path]["read-only"] = b""
    if migration:
        assert ALIAS_PATH not in tree
        assert ROLLBACK_PATH not in tree
        tree[ALIAS_PATH] = ALIAS
        tree[ROLLBACK_PATH] = ROLLBACK
    tree["/chosen"]["rb06-fit-probe"] = MIGRATION_MARKER if migration else MARKER
    nodes[FDT]["data"] = fdt_blob(old_tree, tree)
    for path in (f"{FDT}/hash@1", f"{FDT}/hash@2"):
        nodes[path]["value"] = digest(nodes[path]["algo"], nodes[FDT]["data"])
    nodes[RAMDISK] = {
        "description": b"RB06 one-boot RAM probe\0", "data": archive,
        "type": b"ramdisk\0", "arch": b"arm64\0", "os": b"linux\0", "compression": b"none\0",
    }
    for i, algorithm in enumerate((b"crc32\0", b"sha1\0"), 1):
        nodes[f"{RAMDISK}/hash@{i}"] = {"algo": algorithm, "value": digest(algorithm, archive)}
    nodes[CONFIG]["ramdisk"] = b"ramdisk@rb06-probe\0"
    output = fdt_blob(source, nodes)
    check_hashes(values(parse_fdt(output)))
    return output


if __name__ == "__main__":
    args = sys.argv[1:]
    migration = args[-1] == "--migration"
    if migration:
        args = args[:-1]
    kernel, rootfs, destination, seven_zip = map(Path, args)
    assert hashlib.md5(rootfs.read_bytes()).hexdigest() == ROOTFS_MD5
    archive = make_archive(rootfs, seven_zip, migration=migration)
    image = build(kernel.read_bytes(), archive, migration=migration)
    destination.write_bytes(image)
    print(f"{destination.name}: {len(image)} bytes")
    print(f"SHA-256: {hashlib.sha256(image).hexdigest()}")
    print(f"MD5: {hashlib.md5(image).hexdigest()}")
