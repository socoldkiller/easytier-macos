#!/usr/bin/env python3
"""Pure release metadata and Sparkle feed validation helpers."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from typing import Any, Sequence


BUILD_PATTERN = re.compile(r"^[0-9]{14}$")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")


class ReleaseError(ValueError):
    pass


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Could not read JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"Expected a JSON object in {path}.")
    return value


def write_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def canonical_architecture(value: str) -> str:
    aliases = {
        "arm64": "ARM64",
        "ARM64": "ARM64",
        "aarch64": "ARM64",
        "x86_64": "X64",
        "x64": "X64",
        "X64": "X64",
    }
    architecture = aliases.get(value)
    if architecture is None:
        raise ReleaseError(f"Unsupported release architecture: {value}")
    return architecture


def sparkle_architecture(value: str) -> str:
    architecture = canonical_architecture(value)
    return {"ARM64": "arm64", "X64": "x86_64"}[architecture]


def tag_version(tag: str) -> str:
    value = tag[1:] if tag.startswith(("v", "V")) else tag
    if not VERSION_PATTERN.fullmatch(value):
        raise ReleaseError(f"Release tag must be a numeric version such as v1.4.0: {tag}")
    return value


def validated_metadata(
    path: pathlib.Path,
    expected_architecture: str | None = None,
) -> dict[str, Any]:
    metadata = read_json(path)
    version = str(metadata.get("version", ""))
    build = str(metadata.get("build", ""))
    architecture = canonical_architecture(str(metadata.get("architecture", "")))

    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError(f"Invalid release version in {path}: {version!r}")
    if not BUILD_PATTERN.fullmatch(build):
        raise ReleaseError(f"Invalid 14-digit release build in {path}: {build!r}")
    if metadata.get("signing") != "developer-id":
        raise ReleaseError(f"Release metadata is not Developer ID signed: {metadata}")
    if metadata.get("notarized") is not True:
        raise ReleaseError(f"Release metadata is not notarized: {metadata}")
    if expected_architecture is not None:
        expected = canonical_architecture(expected_architecture)
        if architecture != expected:
            raise ReleaseError(
                f"Release architecture mismatch: metadata={architecture} expected={expected}"
            )

    metadata["version"] = version
    metadata["build"] = build
    metadata["architecture"] = architecture
    return metadata


def write_metadata(
    app_path: pathlib.Path,
    output_path: pathlib.Path,
    architecture: str,
) -> None:
    info_path = app_path / "Contents" / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ReleaseError(f"Could not read packaged app metadata from {info_path}: {error}") from error

    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError(f"Packaged app has an invalid version: {version!r}")
    if not BUILD_PATTERN.fullmatch(build):
        raise ReleaseError(f"Packaged app has an invalid 14-digit build: {build!r}")

    write_json(
        output_path,
        {
            "architecture": canonical_architecture(architecture),
            "build": build,
            "notarized": True,
            "schemaVersion": 1,
            "signing": "developer-id",
            "version": version,
        },
    )


def validate_artifact(
    metadata_path: pathlib.Path,
    dmg_path: pathlib.Path,
    architecture: str,
) -> None:
    validated_metadata(metadata_path, architecture)
    try:
        size = dmg_path.stat().st_size
    except OSError as error:
        raise ReleaseError(f"Release DMG is unavailable: {dmg_path}: {error}") from error
    if size <= 0:
        raise ReleaseError(f"Release DMG is empty: {dmg_path}")


def validate_notary_result(path: pathlib.Path, label: str) -> None:
    result = read_json(path)
    if result.get("status") != "Accepted":
        raise ReleaseError(f"{label} notarization was not accepted: {result}")


def validate_feed_order(
    metadata_path: pathlib.Path,
    current_feed_path: pathlib.Path,
    tag: str,
) -> None:
    metadata = validated_metadata(metadata_path)
    current = read_json(current_feed_path)
    expected_version = tag_version(tag)
    if metadata["version"] != expected_version:
        raise ReleaseError(
            f"Release tag and packaged version differ: {tag} != {metadata['version']}"
        )

    try:
        new_build = int(metadata["build"])
        current_build = int(str(current["build"]))
    except (KeyError, TypeError, ValueError) as error:
        raise ReleaseError(f"Published update feed has an invalid build: {current}") from error

    current_tag = str(current.get("tag", ""))
    if current_tag == tag:
        if new_build != current_build:
            raise ReleaseError(
                f"A rerun of {tag} changed CFBundleVersion: {new_build} != {current_build}"
            )
    elif new_build <= current_build:
        raise ReleaseError(
            f"New CFBundleVersion must exceed the published build: {new_build} <= {current_build}"
        )


def extract_release_notes(changelog_path: pathlib.Path, tag: str) -> str:
    version = tag_version(tag)
    try:
        lines = changelog_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ReleaseError(f"Could not read {changelog_path}: {error}") from error

    heading = f"## [{version}]"
    start = next((index for index, line in enumerate(lines) if line.startswith(heading)), None)
    if start is None:
        raise ReleaseError(f"{changelog_path} is missing a {heading} section")
    end = next(
        (index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")),
        len(lines),
    )
    body = "\n".join(lines[start + 1 : end]).strip()
    if not body:
        raise ReleaseError(f"{changelog_path} section {heading} is empty")
    return (
        f"# EasyTier {version}\n\n{body}\n\n"
        "This DMG is Developer ID signed, Apple-notarized, stapled, and verified with Gatekeeper.\n"
    )


def write_release_notes(changelog_path: pathlib.Path, tag: str, output_path: pathlib.Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(extract_release_notes(changelog_path, tag), encoding="utf-8")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_legacy_feed(
    metadata_path: pathlib.Path,
    dmg_path: pathlib.Path,
    tag: str,
    repository: str,
    output_path: pathlib.Path,
    minimum_system_version: str,
) -> None:
    metadata = validated_metadata(metadata_path, "ARM64")
    version = tag_version(tag)
    if metadata["version"] != version:
        raise ReleaseError(
            f"Release tag and packaged version differ: {tag} != {metadata['version']}"
        )
    if not dmg_path.is_file() or dmg_path.stat().st_size <= 0:
        raise ReleaseError(f"Release DMG is unavailable or empty: {dmg_path}")

    asset_url = f"https://github.com/{repository}/releases/download/{tag}/{dmg_path.name}"
    manifest = {
        "assets": {
            sparkle_architecture(metadata["architecture"]): {
                "sha256": sha256(dmg_path),
                "size": dmg_path.stat().st_size,
                "url": asset_url,
            }
        },
        "build": metadata["build"],
        "channel": "stable",
        "minimumSystemVersion": minimum_system_version,
        "releaseNotesURL": f"https://github.com/{repository}/releases/tag/{tag}",
        "schemaVersion": 1,
        "tag": tag,
        "version": metadata["version"],
    }
    write_json(output_path, manifest)


def local_name(name: str) -> str:
    return name.rsplit("}", 1)[-1]


def validate_appcast(
    appcast_path: pathlib.Path,
    metadata_path: pathlib.Path,
    dmg_path: pathlib.Path,
    tag: str,
    repository: str,
    minimum_system_version: str,
    architecture: str,
) -> str:
    metadata = validated_metadata(metadata_path, architecture)
    version = tag_version(tag)
    if metadata["version"] != version:
        raise ReleaseError(
            f"Release tag and packaged version differ: {tag} != {metadata['version']}"
        )

    try:
        root = ET.parse(appcast_path).getroot()
    except (OSError, ET.ParseError) as error:
        raise ReleaseError(f"Could not parse generated appcast {appcast_path}: {error}") from error

    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ReleaseError(f"Generated appcast must contain exactly one item; found {len(items)}")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ReleaseError("Generated appcast does not contain an enclosure")

    attributes = {local_name(key): value for key, value in enclosure.attrib.items()}
    elements = {local_name(child.tag): (child.text or "").strip() for child in item}
    expected = {
        "url": f"https://github.com/{repository}/releases/download/{tag}/{dmg_path.name}",
        "length": str(dmg_path.stat().st_size),
        "version": metadata["build"],
        "shortVersionString": metadata["version"],
        "minimumSystemVersion": minimum_system_version,
        "hardwareRequirements": sparkle_architecture(architecture),
    }
    actual = {
        "url": attributes.get("url"),
        "length": attributes.get("length"),
        "version": attributes.get("version") or elements.get("version"),
        "shortVersionString": (
            attributes.get("shortVersionString") or elements.get("shortVersionString")
        ),
        "minimumSystemVersion": elements.get("minimumSystemVersion"),
        "hardwareRequirements": elements.get("hardwareRequirements"),
    }
    for field, expected_value in expected.items():
        if actual[field] != expected_value:
            raise ReleaseError(
                f"Appcast {field} mismatch: {actual[field]!r} != {expected_value!r}"
            )

    signature = attributes.get("edSignature")
    if not signature:
        raise ReleaseError("Appcast enclosure is missing sparkle:edSignature")
    return signature


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    metadata = subparsers.add_parser("write-metadata")
    metadata.add_argument("--app", required=True, type=pathlib.Path)
    metadata.add_argument("--output", required=True, type=pathlib.Path)
    metadata.add_argument("--architecture", required=True)

    artifact = subparsers.add_parser("validate-artifact")
    artifact.add_argument("--metadata", required=True, type=pathlib.Path)
    artifact.add_argument("--dmg", required=True, type=pathlib.Path)
    artifact.add_argument("--architecture", required=True)

    notary = subparsers.add_parser("validate-notary")
    notary.add_argument("--input", required=True, type=pathlib.Path)
    notary.add_argument("--label", required=True)

    order = subparsers.add_parser("validate-order")
    order.add_argument("--metadata", required=True, type=pathlib.Path)
    order.add_argument("--current-feed", required=True, type=pathlib.Path)
    order.add_argument("--tag", required=True)

    notes = subparsers.add_parser("release-notes")
    notes.add_argument("--changelog", required=True, type=pathlib.Path)
    notes.add_argument("--tag", required=True)
    notes.add_argument("--output", required=True, type=pathlib.Path)

    legacy = subparsers.add_parser("legacy-feed")
    legacy.add_argument("--metadata", required=True, type=pathlib.Path)
    legacy.add_argument("--dmg", required=True, type=pathlib.Path)
    legacy.add_argument("--tag", required=True)
    legacy.add_argument("--repository", required=True)
    legacy.add_argument("--output", required=True, type=pathlib.Path)
    legacy.add_argument("--minimum-system-version", default="15.0")

    appcast = subparsers.add_parser("validate-appcast")
    appcast.add_argument("--appcast", required=True, type=pathlib.Path)
    appcast.add_argument("--metadata", required=True, type=pathlib.Path)
    appcast.add_argument("--dmg", required=True, type=pathlib.Path)
    appcast.add_argument("--tag", required=True)
    appcast.add_argument("--repository", required=True)
    appcast.add_argument("--minimum-system-version", default="15.0")
    appcast.add_argument("--architecture", default="ARM64")

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "write-metadata":
            write_metadata(args.app, args.output, args.architecture)
        elif args.command == "validate-artifact":
            validate_artifact(args.metadata, args.dmg, args.architecture)
        elif args.command == "validate-notary":
            validate_notary_result(args.input, args.label)
        elif args.command == "validate-order":
            validate_feed_order(args.metadata, args.current_feed, args.tag)
        elif args.command == "release-notes":
            write_release_notes(args.changelog, args.tag, args.output)
        elif args.command == "legacy-feed":
            write_legacy_feed(
                args.metadata,
                args.dmg,
                args.tag,
                args.repository,
                args.output,
                args.minimum_system_version,
            )
        elif args.command == "validate-appcast":
            print(
                validate_appcast(
                    args.appcast,
                    args.metadata,
                    args.dmg,
                    args.tag,
                    args.repository,
                    args.minimum_system_version,
                    args.architecture,
                )
            )
        else:
            raise AssertionError(f"Unhandled command: {args.command}")
    except ReleaseError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
