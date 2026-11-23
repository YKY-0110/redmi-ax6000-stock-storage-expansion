import hashlib
import struct
import sys
import zlib
from dataclasses import dataclass, field
from pathlib import Path


PARTITIONS = "/nmbm_spim_nand/partitions"
BOOT = f"{PARTITIONS}/partition@600000"
SECOND = f"{PARTITIONS}/partition@2400000"
OVERLAY = f"{PARTITIONS}/partition@4200000"
ALIAS_PATH = f"{PARTITIONS}/migration@2400000"
ALIAS = {"label": b"rb06-merge\0", "reg": struct.pack(">2I", 0x2400000, 0x5000000)}
KERNEL = "/images/kernel@1"
FDT = "/images/fdt@1"
NOP = struct.pack(">I", 4)


def align4(length: int) -> int:
    return (length + 3) & ~3


@dataclass
class Property:
    position: int
    value: bytes


@dataclass
class Node:
    start: int
    end: int = 0
    properties: dict[str, Property] = field(default_factory=dict)


def parse_fdt(blob: bytes) -> dict[str, Node]:
    magic, total, pos, table, _, version, _, _, strings_size, structure_size = (
        struct.unpack_from(">10I", blob)
    )
    assert magic == 0xD00DFEED and version == 17 and total <= len(blob)
    assert pos + structure_size <= table and table + strings_size <= total
    stack = []
    nodes = {}
    stop = pos + structure_size
    while pos < stop:
        start = pos
        token, = struct.unpack_from(">I", blob, pos)
        pos += 4
        if token == 1:
            end = blob.index(b"\0", pos, stop)
            stack.append(blob[pos:end].decode("ascii"))
            name = "/".join(stack)
            assert name not in nodes
            nodes[name] = Node(start)
            pos = (end + 4) & ~3
        elif token == 2:
            nodes["/".join(stack)].end = pos
            stack.pop()
        elif token == 3:
            length, offset = struct.unpack_from(">2I", blob, pos)
            pos += 8
            end = blob.index(b"\0", table + offset, table + strings_size)
            key = blob[table + offset:end].decode("ascii")
            assert pos + length <= stop
            node = nodes["/".join(stack)]
            assert key not in node.properties
            node.properties[key] = Property(pos, blob[pos:pos + length])
            pos = (pos + length + 3) & ~3
        elif token == 9:
            assert not stack and pos == stop
            return nodes
        elif token != 4:
            raise ValueError(f"Unexpected FDT token {token} at {start:#x}")
    raise ValueError("FDT_END token missing")


def values(nodes: dict[str, Node]) -> dict[str, dict[str, bytes]]:
    return {
        path: {key: prop.value for key, prop in node.properties.items()}
        for path, node in nodes.items()
    }


def digest(algorithm: bytes, data: bytes) -> bytes:
    if algorithm == b"crc32\0":
        return struct.pack(">I", zlib.crc32(data))
    if algorithm == b"sha1\0":
        return hashlib.sha1(data).digest()
    raise ValueError(f"Unexpected image hash algorithm: {algorithm!r}")


def check_hashes(fit: dict[str, dict[str, bytes]]) -> None:
    for image in (KERNEL, FDT):
        for node, algorithm in (("hash@1", b"crc32\0"), ("hash@2", b"sha1\0")):
            properties = fit[f"{image}/{node}"]
            assert properties["algo"] == algorithm
            assert properties["value"] == digest(algorithm, fit[image]["data"])


def check_and_patch(source: bytes) -> bytes:
    fit = parse_fdt(source)
    original = values(fit)
    assert set(fit) == {
        "", "/images", KERNEL, FDT, "/configurations", "/configurations/config@1",
        f"{KERNEL}/hash@1", f"{KERNEL}/hash@2", f"{FDT}/hash@1", f"{FDT}/hash@2",
    }
    assert original["/configurations"]["default"] == b"config@1\0"
    assert original["/configurations/config@1"]["kernel"] == b"kernel@1\0"
    assert original["/configurations/config@1"]["fdt"] == b"fdt@1\0"
    assert original[FDT]["description"].endswith(b"mt7986-RB06 device tree blob\0")
    check_hashes(original)

    embedded = fit[FDT].properties["data"]
    nodes = parse_fdt(embedded.value)
    expected_tree = values(nodes)
    assert expected_tree[BOOT] == {
        "label": b"ubi\0", "reg": struct.pack(">2I", 0x600000, 0x1E00000)
    }
    assert expected_tree[SECOND] == {
        "label": b"ubi1\0", "reg": struct.pack(">2I", 0x2400000, 0x1E00000)
    }
    assert expected_tree[OVERLAY] == {
        "label": b"overlay\0", "reg": struct.pack(">2I", 0x4200000, 0x3200000)
    }
    assert not any(path.startswith(OVERLAY + "/") for path in nodes)

    tree = bytearray(embedded.value)
    label = nodes[SECOND].properties["label"]
    reg = nodes[SECOND].properties["reg"]
    new_label = b"overlay\0"
    new_reg = struct.pack(">2I", 0x2400000, 0x5000000)
    assert (len(label.value) + 3) & ~3 == len(new_label)
    struct.pack_into(">I", tree, label.position - 8, len(new_label))
    tree[label.position:label.position + len(new_label)] = new_label
    tree[reg.position:reg.position + len(new_reg)] = new_reg

    old = nodes[OVERLAY]
    span = old.end - old.start
    assert span > 0 and span % 4 == 0
    tree[old.start:old.end] = NOP * (span // 4)
    expected_tree[SECOND] = {"label": new_label, "reg": new_reg}
    del expected_tree[OVERLAY]
    assert values(parse_fdt(tree)) == expected_tree

    result = bytearray(source)
    result[embedded.position:embedded.position + len(tree)] = tree
    expected = original
    expected[FDT]["data"] = bytes(tree)
    for name in ("hash@1", "hash@2"):
        path = f"{FDT}/{name}"
        prop = fit[path].properties["value"]
        new_hash = digest(expected[path]["algo"], tree)
        assert len(new_hash) == len(prop.value)
        result[prop.position:prop.position + len(new_hash)] = new_hash
        expected[path]["value"] = new_hash

    actual = values(parse_fdt(result))
    assert actual == expected and len(result) == len(source)
    check_hashes(actual)
    return bytes(result)


if __name__ == "__main__":
    source = Path(sys.argv[1]).read_bytes()
    target = Path(sys.argv[2])
    result = check_and_patch(source)
    target.write_bytes(result)
    print(f"{target.name}: {len(result)} bytes")
    print(f"SHA256: {hashlib.sha256(result).hexdigest()}")
