#!/usr/bin/env python3
"""Pure release metadata and Sparkle feed validation helpers."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
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
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
BUILD_TIME_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
RELEASE_CHANNELS = {"stable", "nightly"}


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


def validate_release_tag(tag: str, metadata: dict[str, Any]) -> None:
    channel = metadata["channel"]
    if channel == "stable":
        version = tag_version(tag)
        if metadata["version"] != version:
            raise ReleaseError(
                f"Release tag and packaged version differ: {tag} != {metadata['version']}"
            )
        return

    expected = f"nightly-{metadata['build']}"
    if tag != expected:
        raise ReleaseError(f"Nightly tag must match the packaged build: {tag} != {expected}")


def validated_metadata(
    path: pathlib.Path,
    expected_architecture: str | None = None,
) -> dict[str, Any]:
    metadata = read_json(path)
    version = str(metadata.get("version", ""))
    build = str(metadata.get("build", ""))
    architecture = canonical_architecture(str(metadata.get("architecture", "")))
    channel = str(metadata.get("channel", ""))
    build_time = str(metadata.get("buildTime", ""))
    gui_commit = str(metadata.get("guiCommit", ""))
    core_commit = str(metadata.get("coreCommit", ""))
    core_version = str(metadata.get("coreVersion", ""))

    if metadata.get("schemaVersion") != 2:
        raise ReleaseError(f"Unsupported release metadata schema in {path}: {metadata}")
    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError(f"Invalid release version in {path}: {version!r}")
    if not BUILD_PATTERN.fullmatch(build):
        raise ReleaseError(f"Invalid 14-digit release build in {path}: {build!r}")
    if channel not in RELEASE_CHANNELS:
        raise ReleaseError(f"Invalid release channel in {path}: {channel!r}")
    if not BUILD_TIME_PATTERN.fullmatch(build_time):
        raise ReleaseError(f"Invalid UTC build time in {path}: {build_time!r}")
    if not COMMIT_PATTERN.fullmatch(gui_commit):
        raise ReleaseError(f"Invalid GUI commit in {path}: {gui_commit!r}")
    if not COMMIT_PATTERN.fullmatch(core_commit):
        raise ReleaseError(f"Invalid Core commit in {path}: {core_commit!r}")
    if not core_version or core_version == "unknown":
        raise ReleaseError(f"Invalid Core version in {path}: {core_version!r}")
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
    metadata["channel"] = channel
    metadata["buildTime"] = build_time
    metadata["guiCommit"] = gui_commit
    metadata["coreCommit"] = core_commit
    metadata["coreVersion"] = core_version
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
    channel = str(info.get("EasyTierBuildChannel", ""))
    build_time = str(info.get("EasyTierBuildTime", ""))
    gui_commit = str(info.get("EasyTierGUICommit", ""))
    core_commit = str(info.get("EasyTierCoreCommit", ""))
    core_version = str(info.get("EasyTierCoreTag", ""))
    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError(f"Packaged app has an invalid version: {version!r}")
    if not BUILD_PATTERN.fullmatch(build):
        raise ReleaseError(f"Packaged app has an invalid 14-digit build: {build!r}")
    if channel not in RELEASE_CHANNELS:
        raise ReleaseError(f"Packaged app has an invalid build channel: {channel!r}")
    if not BUILD_TIME_PATTERN.fullmatch(build_time):
        raise ReleaseError(f"Packaged app has an invalid UTC build time: {build_time!r}")
    if not COMMIT_PATTERN.fullmatch(gui_commit):
        raise ReleaseError(f"Packaged app has an invalid GUI commit: {gui_commit!r}")
    if not COMMIT_PATTERN.fullmatch(core_commit):
        raise ReleaseError(f"Packaged app has an invalid Core commit: {core_commit!r}")
    if not core_version or core_version == "unknown":
        raise ReleaseError(f"Packaged app has an invalid Core version: {core_version!r}")

    write_json(
        output_path,
        {
            "architecture": canonical_architecture(architecture),
            "build": build,
            "buildTime": build_time,
            "channel": channel,
            "coreCommit": core_commit,
            "coreVersion": core_version,
            "guiCommit": gui_commit,
            "notarized": True,
            "schemaVersion": 2,
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
    validate_release_tag(tag, metadata)
    if current.get("channel") != metadata["channel"]:
        raise ReleaseError(
            f"Published feed channel differs from artifact: {current.get('channel')!r} != {metadata['channel']!r}"
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
        for field in ("guiCommit", "coreCommit"):
            current_value = current.get(field)
            if current_value is not None and current_value != metadata[field]:
                raise ReleaseError(
                    f"A rerun of {tag} changed {field}: {current_value!r} != {metadata[field]!r}"
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


def write_nightly_release_notes(
    metadata_path: pathlib.Path,
    repository: str,
    core_repository: str,
    output_path: pathlib.Path,
) -> None:
    metadata = validated_metadata(metadata_path)
    if metadata["channel"] != "nightly":
        raise ReleaseError("Nightly release notes require nightly artifact metadata.")
    build_time = datetime.strptime(metadata["buildTime"], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    )
    build_date = (build_time + timedelta(hours=8)).strftime("%Y-%m-%d")
    gui_commit = metadata["guiCommit"]
    core_commit = metadata["coreCommit"]
    notes = (
        f"# EasyTier Nightly {build_date}\n\n"
        "This build packages the latest tested GUI and EasyTier Core revisions captured by the nightly workflow.\n\n"
        f"- GUI: [`{gui_commit[:8]}`](https://github.com/{repository}/commit/{gui_commit})\n"
        f"- Core: [`{core_commit[:8]}`](https://github.com/{core_repository}/commit/{core_commit})\n"
        f"- Core version: `{metadata['coreVersion']}`\n"
        f"- Build: `{metadata['build']}`\n\n"
        "Nightly builds may be unstable. This DMG is Developer ID signed, Apple-notarized, "
        "stapled, and verified with Gatekeeper.\n"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(notes, encoding="utf-8")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_channel_feed(
    metadata_path: pathlib.Path,
    dmg_path: pathlib.Path,
    tag: str,
    repository: str,
    output_path: pathlib.Path,
    minimum_system_version: str,
) -> None:
    metadata = validated_metadata(metadata_path, "ARM64")
    validate_release_tag(tag, metadata)
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
        "buildTime": metadata["buildTime"],
        "channel": metadata["channel"],
        "coreCommit": metadata["coreCommit"],
        "coreVersion": metadata["coreVersion"],
        "guiCommit": metadata["guiCommit"],
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
    validate_release_tag(tag, metadata)

    try:
        root = ET.parse(appcast_path).getroot()
    except (OSError, ET.ParseError) as error:
        raise ReleaseError(f"Could not parse generated appcast {appcast_path}: {error}") from error

    items = root.findall("./channel/item")
    if not 1 <= len(items) <= 2:
        raise ReleaseError(f"Generated appcast must contain one or two items; found {len(items)}")

    items_by_channel: dict[str, ET.Element] = {}
    for candidate in items:
        candidate_elements = {
            local_name(child.tag): (child.text or "").strip() for child in candidate
        }
        raw_channel = candidate_elements.get("channel")
        if raw_channel:
            if raw_channel != "nightly":
                raise ReleaseError(f"Generated appcast has an unsupported channel: {raw_channel}")
            candidate_channel = "nightly"
        else:
            candidate_channel = "stable"
        if candidate_channel in items_by_channel:
            raise ReleaseError(f"Generated appcast has duplicate {candidate_channel} items")
        candidate_enclosure = candidate.find("enclosure")
        if candidate_enclosure is None:
            raise ReleaseError(f"Generated appcast {candidate_channel} item has no enclosure")
        candidate_attributes = {
            local_name(key): value for key, value in candidate_enclosure.attrib.items()
        }
        if not candidate_attributes.get("edSignature"):
            raise ReleaseError(
                f"Generated appcast {candidate_channel} enclosure has no EdDSA signature"
            )
        if not (candidate_attributes.get("version") or candidate_elements.get("version")):
            raise ReleaseError(f"Generated appcast {candidate_channel} item has no build version")
        if candidate_elements.get("minimumSystemVersion") != minimum_system_version:
            raise ReleaseError(
                f"Generated appcast {candidate_channel} minimumSystemVersion mismatch"
            )
        if candidate_elements.get("hardwareRequirements") != sparkle_architecture(architecture):
            raise ReleaseError(
                f"Generated appcast {candidate_channel} hardwareRequirements mismatch"
            )
        items_by_channel[candidate_channel] = candidate

    item = items_by_channel.get(metadata["channel"])
    if item is None:
        raise ReleaseError(
            f"Generated appcast does not contain the published {metadata['channel']} item"
        )
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

    nightly_notes = subparsers.add_parser("nightly-release-notes")
    nightly_notes.add_argument("--metadata", required=True, type=pathlib.Path)
    nightly_notes.add_argument("--repository", required=True)
    nightly_notes.add_argument("--core-repository", default="EasyTier/EasyTier")
    nightly_notes.add_argument("--output", required=True, type=pathlib.Path)

    channel_feed = subparsers.add_parser("channel-feed")
    channel_feed.add_argument("--metadata", required=True, type=pathlib.Path)
    channel_feed.add_argument("--dmg", required=True, type=pathlib.Path)
    channel_feed.add_argument("--tag", required=True)
    channel_feed.add_argument("--repository", required=True)
    channel_feed.add_argument("--output", required=True, type=pathlib.Path)
    channel_feed.add_argument("--minimum-system-version", default="15.0")

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
        elif args.command == "nightly-release-notes":
            write_nightly_release_notes(
                args.metadata,
                args.repository,
                args.core_repository,
                args.output,
            )
        elif args.command == "channel-feed":
            write_channel_feed(
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
