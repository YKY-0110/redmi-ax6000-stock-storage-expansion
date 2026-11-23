"""Build the three FITs for RB06 from user-supplied, unmodified 1.0.67 volumes."""

import argparse
import hashlib
import shutil
import subprocess
from pathlib import Path

from build_overlay_fit import check_and_patch
from build_ram_probe_fit import build, make_archive


STOCK_KERNEL_SHA256 = "3d91a964600545d18b51512540f12a90cbbe1fe45d7853e92245a6b85e27dae9"
STOCK_ROOTFS_SHA256 = "98ec160cf7c7708af3ab9b88aac8e11b848d63d5b5637f67642ebef3ce19460c"

EXPECTED_OUTPUTS = {
    "RB06-1.0.67-ram-boot-test.fit": "f10d9224b8317dc921ae34e5489bd93d24d5b036e007186192fb792f994d885d",
    "RB06-1.0.67-ram-overlay80-migrate.fit": "4d1fdf88f4dfcb0b21e2afb069077b602ef4340124adad4b2eb250992b9207c4",
    "RB06-1.0.67-overlay80-test.fit": "557a1f289746e138c9bbd217865fc3838e03ce47d10f5f3d46266821399bd42a",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verified_input(path: Path, size: int, expected_hash: str) -> bytes:
    data = path.read_bytes()
    if len(data) != size or sha256(data) != expected_hash:
        raise ValueError(f"{path.name}: does not match the expected RB06 1.0.67 original volume")
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, required=True, help="Original kernel.fit volume dump")
    parser.add_argument("--rootfs", type=Path, required=True, help="Original rootfs.squashfs volume dump")
    parser.add_argument("--7zip", dest="seven_zip", required=True, help="Path to 7z.exe, 7z, or 7zz")
    parser.add_argument("--output-dir", type=Path, default=Path("built"))
    args = parser.parse_args()
    if not __debug__:
        parser.error("use Python without -O so FIT validation remains enabled")

    try:
        kernel = verified_input(args.kernel, 3301376, STOCK_KERNEL_SHA256)
        verified_input(args.rootfs, 16125952, STOCK_ROOTFS_SHA256)
        executable = shutil.which(args.seven_zip)
        if executable is None:
            raise ValueError("7-Zip executable not found. Pass its full path with --7zip.")
        seven_zip = Path(executable).resolve()
        images = {
            "RB06-1.0.67-ram-boot-test.fit": build(kernel, make_archive(args.rootfs, seven_zip)),
            "RB06-1.0.67-ram-overlay80-migrate.fit": build(
                kernel, make_archive(args.rootfs, seven_zip, migration=True), migration=True
            ),
            "RB06-1.0.67-overlay80-test.fit": check_and_patch(kernel),
        }
        for name, image in images.items():
            if sha256(image) != EXPECTED_OUTPUTS[name]:
                raise ValueError(f"{name}: generated FIT checksum does not match the verified build")
        args.output_dir.mkdir(parents=True, exist_ok=True)
        for name, image in images.items():
            (args.output_dir / name).write_bytes(image)
            print(f"{EXPECTED_OUTPUTS[name]}  {name}")
    except (ValueError, OSError, subprocess.CalledProcessError, AssertionError) as error:
        parser.exit(1, f"Build failed: {error or 'FIT structure validation did not pass'}\n")


if __name__ == "__main__":
    main()
