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


def tar_gz(entries: list[tuple[str, bytes, int]]) -> bytes:
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", compresslevel=9, mtime=EPOCH) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, content, mode in entries:
                info = tarfile.TarInfo(name=name)
                info.size = len(content)
                info.mode = mode
                info.mtime = EPOCH
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                archive.addfile(info, io.BytesIO(content))
    return compressed.getvalue()


def ar_member(name: str, content: bytes, mode: int = 0o100644) -> bytes:
    if len(name) > 15:
        raise ValueError(f"ar member name is too long: {name}")
    header = (
        f"{name + '/':<16}"
        f"{EPOCH:<12}"
        f"{0:<6}"
        f"{0:<6}"
        f"{mode:<8o}"
        f"{len(content):<10}`\n"
    ).encode("ascii")
    if len(header) != 60:
        raise AssertionError(f"invalid ar header length for {name}: {len(header)}")
    return header + content + (b"\n" if len(content) % 2 else b"")


def parse_ar(blob: bytes) -> dict[str, bytes]:
    if not blob.startswith(b"!<arch>\n"):
        raise ValueError("missing ar signature")
    offset = 8
    members: dict[str, bytes] = {}
    while offset < len(blob):
        header = blob[offset : offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("invalid ar member header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        offset += 60
        members[name] = blob[offset : offset + size]
        offset += size + (size % 2)
    return members


def build(version: str, output_dir: Path) -> Path:
    payload = payload_files()
    data_entries = [
        (target, source.read_bytes(), mode) for source, target, mode in payload
    ]
    data_archive = tar_gz(data_entries)
    installed_size = max(1, (sum(len(content) for _, content, _ in data_entries) + 1023) // 1024)

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
        ("control", control, 0o644),
        ("conffiles", b"/etc/config/istoreos_sms\n", 0o644),
    ]
    for name in ("postinst", "prerm", "postrm"):
        control_entries.append(
            (name, (ROOT / "packaging" / "ipk" / name).read_bytes(), 0o755)
        )
    control_archive = tar_gz(control_entries)

    blob = b"!<arch>\n"
    blob += ar_member("debian-binary", b"2.0\n")
    blob += ar_member("control.tar.gz", control_archive)
    blob += ar_member("data.tar.gz", data_archive)

    members = parse_ar(blob)
    if list(members) != ["debian-binary", "control.tar.gz", "data.tar.gz"]:
        raise AssertionError(f"unexpected ipk members: {list(members)}")
    if members["debian-binary"] != b"2.0\n":
        raise AssertionError("invalid debian-binary payload")

    with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:gz") as archive:
        control_members = {item.name: item for item in archive.getmembers()}
    if set(control_members) != {"control", "conffiles", "postinst", "prerm", "postrm"}:
        raise AssertionError(f"unexpected control members: {sorted(control_members)}")
    for name in ("postinst", "prerm", "postrm"):
        if control_members[name].mode != 0o755:
            raise AssertionError(f"{name} is not executable")

    with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"]), mode="r:gz") as archive:
        data_members = {item.name: item for item in archive.getmembers()}
    expected_data = {target for _, target, _ in payload}
    if set(data_members) != expected_data:
        raise AssertionError("data archive does not match the repository payload")
    for _, target, mode in payload:
        if data_members[target].mode != mode:
            raise AssertionError(f"unexpected mode for {target}: {data_members[target].mode:o}")

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
