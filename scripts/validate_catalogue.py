#!/usr/bin/env python3
"""Manually validate checked-in Kapp source packages, ZIPs, and catalogue pins."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile


ROOT = Path(__file__).resolve().parent.parent
CATALOGUE_PATH = ROOT / "catalogue.json"
HOST_LOCALIZATION_RESOURCES = {
    f"Sources/Kapp/Resources/{language}.lproj/Localizable.strings"
    for language in ("en", "es", "fr")
}


def is_localized_resource(relative: str) -> bool:
    parts = PurePosixPath(relative).parts
    structurally_valid = (
        len(parts) == 5
        and parts[:3] == ("Sources", "Kapp", "Resources")
        and parts[3].endswith(".lproj")
        and len(parts[3]) > len(".lproj")
        and parts[4].endswith(".strings")
        and len(parts[4]) > len(".strings")
    )
    if not structurally_valid:
        return False
    return (
        parts[4].casefold() != "localizable.strings"
        or relative in HOST_LOCALIZATION_RESOURCES
    )


def fail(message: str) -> None:
    raise ValueError(message)


def portable_files(package: Path) -> dict[str, bytes]:
    if package.is_symlink() or not package.is_dir():
        fail(f"package is not a regular directory: {package}")
    files: dict[str, bytes] = {}
    for path in sorted(package.rglob("*")):
        relative = path.relative_to(package).as_posix()
        if path.is_symlink():
            fail(f"symbolic links are not portable: {package.name}/{relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            fail(f"non-regular source member: {package.name}/{relative}")
        allowed = relative in {"Package.swift", "Kapp.json"} or (
            relative.startswith("Sources/")
            and (relative.endswith(".swift") or is_localized_resource(relative))
        )
        if not allowed or any(part.startswith(".") for part in PurePosixPath(relative).parts):
            fail(f"unsupported portable source member: {package.name}/{relative}")
        files[relative] = path.read_bytes()
    if "Package.swift" not in files or "Kapp.json" not in files:
        fail(f"missing required package files: {package.name}")
    if not any(path.startswith("Sources/") for path in files):
        fail(f"missing Sources files: {package.name}")
    return files


def source_digest(files: dict[str, bytes]) -> str:
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(path.encode())
        digest.update(b"\0")
        digest.update(files[path])
        digest.update(b"\0")
    return digest.hexdigest()


def zip_files(archive: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    with zipfile.ZipFile(archive) as zipped:
        for member in zipped.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in member.filename:
                fail(f"unsafe ZIP member: {member.filename}")
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                fail(f"symbolic link in ZIP: {member.filename}")
            if not member.is_dir() and not stat.S_ISREG(mode):
                fail(f"non-regular ZIP member: {member.filename}")
            if member.is_dir():
                continue
            if member.filename in files:
                fail(f"duplicate ZIP member: {member.filename}")
            files[member.filename] = zipped.read(member)
        bad_member = zipped.testzip()
        if bad_member is not None:
            fail(f"corrupt ZIP member: {bad_member}")
    return files


def main() -> int:
    catalogue = json.loads(CATALOGUE_PATH.read_text())
    if catalogue.get("formatVersion") != 1 or not catalogue.get("entries"):
        fail("catalogue must use formatVersion 1 and contain entries")
    packages: dict[str, tuple[Path, dict, dict[str, bytes]]] = {}
    for package in sorted((ROOT / "packages").iterdir()):
        files = portable_files(package)
        manifest = json.loads(files["Kapp.json"])
        app_id = manifest["appID"]
        if app_id in packages:
            fail(f"duplicate package appID: {app_id}")
        packages[app_id] = (package, manifest, files)

    seen: set[str] = set()
    for entry in catalogue["entries"]:
        app_id = entry["appID"]
        if app_id in seen or app_id not in packages:
            fail(f"missing or duplicate source package for catalogue appID: {app_id}")
        seen.add(app_id)
        package, manifest, files = packages[app_id]
        archive_name = entry.get("includedArchiveName")
        archive = ROOT / "releases" / archive_name
        if not archive_name or archive.name != archive_name or not archive.is_file():
            fail(f"missing checked-in ZIP for {app_id}")
        if zip_files(archive) != files:
            fail(f"ZIP bytes do not exactly match {package.relative_to(ROOT)}")
        expected_location = (
            "https://raw.githubusercontent.com/llk23r/kapsicum-apps/main/releases/"
            + archive_name
        )
        facts_match = (
            entry["name"] == manifest["displayName"]
            and entry["version"] == manifest["version"]
            and entry["usesAI"] == manifest["usesAI"]
            and entry["requestedReadCapabilityIDs"]
            == manifest["requestedReadCapabilityIDs"]
        )
        if not facts_match:
            fail(f"catalogue facts do not match Kapp.json for {app_id}")
        if entry["sourceZIPLocation"] != expected_location:
            fail(f"sourceZIPLocation does not name the checked-in ZIP for {app_id}")
        if entry["sourceDigest"] != source_digest(files):
            fail(f"canonical source digest mismatch for {app_id}")
        if entry["zipSHA256"] != hashlib.sha256(archive.read_bytes()).hexdigest():
            fail(f"ZIP SHA-256 mismatch for {app_id}")

    if seen != set(packages):
        fail("every source package must have exactly one catalogue entry")
    print(f"Validated {len(seen)} portable Kapp package(s).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, ValueError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
