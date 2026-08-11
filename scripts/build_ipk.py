from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "luci-app-istoreos-sms"
DEFAULT_VERSION = "2.0.0-1"
EPOCH = 0


def payload_files() -> list[tuple[Path, str, int]]:
    files: list[tuple[Path, str, int]] = []
    for source_root, target_root in ((ROOT / "htdocs", "www"), (ROOT / "root", "")):
        for path in sorted(item for item in source_root.rglob("*") if item.is_file()):
            relative = path.relative_to(source_root).as_posix()
            target = f"{target_root}/{relative}".lstrip("/")
            mode = 0o755 if target in {
                "etc/init.d/istoreos_sms",
                "etc/uci-defaults/99-istoreos-sms",
                "usr/libexec/istoreos-sms/ensure-storage.sh",
            } else 0o600 if target == "etc/config/istoreos_sms" else 0o644
            files.append((path, target, mode))
    return files


def tar_gz(entries: list[tuple[str, bytes | None, int]]) -> bytes:
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", compresslevel=9, mtime=EPOCH) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, content, mode in entries:
                info = tarfile.TarInfo(name=name)
                info.mode = mode
                info.mtime = EPOCH
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                if content is None:
                    info.type = tarfile.DIRTYPE
                    info.size = 0
                    archive.addfile(info)
                else:
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))
    return compressed.getvalue()


def build(version: str, output_dir: Path) -> Path:
    payload = payload_files()
    data_file_entries = [
        (f"./{target}", source.read_bytes(), mode) for source, target, mode in payload
    ]
    data_directories: set[str] = set()
    for _, target, _ in payload:
        parts = target.split("/")[:-1]
        for depth in range(1, len(parts) + 1):
            data_directories.add(f"./{'/'.join(parts[:depth])}")
    data_directory_entries = [
        (directory, None, 0o755)
        for directory in sorted(data_directories, key=lambda item: (item.count("/"), item))
    ]
    data_entries = data_directory_entries + data_file_entries
    data_archive = tar_gz(data_entries)
    installed_size = max(
        1,
        (sum(len(content) for _, content, _ in data_file_entries) + 1023) // 1024,
    )

    control = (
        f"Package: {PACKAGE}\n"
        f"Version: {version}\n"
        "Architecture: all\n"
        "Maintainer: Lkxu <61963176+mikutea@users.noreply.github.com>\n"
        "Depends: sms-tool\n"
        "Section: luci\n"
        "Priority: optional\n"
        f"Installed-Size: {installed_size}\n"
        "Description: Modern LuCI SMS viewer with CNMI storage-mode health check.\n"
    ).encode("utf-8")
    control_entries = [
        ("./control", control, 0o644),
        ("./conffiles", b"/etc/config/istoreos_sms\n", 0o644),
    ]
    for name in ("postinst", "prerm", "postrm"):
        control_entries.append(
            (f"./{name}", (ROOT / "packaging" / "ipk" / name).read_bytes(), 0o755)
        )
    control_archive = tar_gz(control_entries)

    # OpenWrt 24.10's opkg expects the historical ipkg format: a gzip-compressed
    # tar archive. Debian's ar-based .deb container has similar inner members,
    # but opkg rejects it as a malformed package.
    blob = tar_gz([
        ("./debian-binary", b"2.0\n", 0o644),
        ("./data.tar.gz", data_archive, 0o644),
        ("./control.tar.gz", control_archive, 0o644),
    ])

    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
        members = {item.name: archive.extractfile(item).read() for item in archive.getmembers()}
    expected_members = ["./debian-binary", "./data.tar.gz", "./control.tar.gz"]
    if list(members) != expected_members:
        raise AssertionError(f"unexpected ipk members: {list(members)}")
    if members["./debian-binary"] != b"2.0\n":
        raise AssertionError("invalid debian-binary payload")

    with tarfile.open(fileobj=io.BytesIO(members["./control.tar.gz"]), mode="r:gz") as archive:
        control_members = {item.name: item for item in archive.getmembers()}
    if set(control_members) != {"./control", "./conffiles", "./postinst", "./prerm", "./postrm"}:
        raise AssertionError(f"unexpected control members: {sorted(control_members)}")
    for name in ("postinst", "prerm", "postrm"):
        if control_members[f"./{name}"].mode != 0o755:
            raise AssertionError(f"{name} is not executable")

    with tarfile.open(fileobj=io.BytesIO(members["./data.tar.gz"]), mode="r:gz") as archive:
        data_members = {item.name: item for item in archive.getmembers()}
    expected_data = data_directories | {f"./{target}" for _, target, _ in payload}
    if set(data_members) != expected_data:
        raise AssertionError("data archive does not match the repository payload")
    for directory in data_directories:
        if not data_members[directory].isdir() or data_members[directory].mode != 0o755:
            raise AssertionError(f"invalid directory entry: {directory}")
    for _, target, mode in payload:
        member_name = f"./{target}"
        if data_members[member_name].mode != mode:
            raise AssertionError(f"unexpected mode for {target}: {data_members[member_name].mode:o}")

    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"{PACKAGE}_{version}_all.ipk"
    output.write_bytes(blob)
    digest = hashlib.sha256(blob).hexdigest()
    print(f"built: {output}")
    print(f"sha256: {digest}")
    print(f"payload files: {len(payload)}")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description="Build an architecture-independent OpenWrt IPK.")
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    if not args.version or any(char.isspace() for char in args.version):
        parser.error("version must be non-empty and contain no whitespace")
    build(args.version, args.output_dir.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
