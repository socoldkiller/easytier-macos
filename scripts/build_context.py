#!/usr/bin/env python3
"""Resolve deterministic, non-secret build metadata for local and CI builds."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Mapping, Sequence


BUILD_PATTERN = re.compile(r"^[0-9]{14}$")
BUILD_TIME_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}(?:-dirty)?$")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")


class BuildContextError(ValueError):
    pass


@dataclass(frozen=True)
class BuildContext:
    mode: str
    release_channel: str
    should_publish: bool
    app_version: str
    build_number: str
    build_time: str
    tag_name: str
    gui_revision: str
    core_revision: str
    core_version: str
    gateway_version: str

    def environment(self) -> dict[str, str]:
        build_channel = self.release_channel if self.release_channel != "none" else "stable"
        gui_revision = "" if self.gui_revision.endswith("-dirty") else self.gui_revision
        core_revision = "" if self.core_revision.endswith("-dirty") else self.core_revision
        return {
            "EASYTIER_APP_VERSION": self.app_version,
            "EASYTIER_BUILD_CHANNEL": build_channel,
            "EASYTIER_BUILD_NUMBER": self.build_number,
            "EASYTIER_BUILD_TIME": self.build_time,
            "EASYTIER_CORE_COMMIT": self.core_revision,
            "EASYTIER_CORE_REVISION": core_revision,
            "EASYTIER_CORE_TAG": self.core_version,
            "EASYTIER_CORE_VERSION": self.core_version,
            "EASYTIER_GATEWAY_VERSION": self.gateway_version,
            "EASYTIER_GUI_COMMIT": self.gui_revision,
            "EASYTIER_GUI_REVISION": gui_revision,
            "EASYTIER_RELEASE_CHANNEL": self.release_channel,
            "EASYTIER_RELEASE_TAG": self.tag_name,
        }

    def github_outputs(self) -> dict[str, str]:
        return {
            "app_version": self.app_version,
            "build_number": self.build_number,
            "build_time": self.build_time,
            "core_revision": self.core_revision.removesuffix("-dirty"),
            "core_version": self.core_version,
            "gateway_version": self.gateway_version,
            "gui_revision": self.gui_revision.removesuffix("-dirty"),
            "release_channel": self.release_channel,
            "should_publish": str(self.should_publish).lower(),
            "tag_name": self.tag_name,
        }


def run_git(root: pathlib.Path, *arguments: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise BuildContextError(message)
    return result.stdout.strip()


def repository_revision(root: pathlib.Path, *, allow_dirty: bool) -> str:
    revision = run_git(root, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise BuildContextError(f"Could not resolve a full Git revision for {root}.")
    if allow_dirty:
        status = run_git(root, "status", "--short", "--untracked-files=no")
        if status:
            revision += "-dirty"
    return revision


def core_version(root: pathlib.Path, *, allow_dirty: bool) -> str:
    version = run_git(root, "describe", "--tags", "--always")
    if not version:
        raise BuildContextError("Could not resolve the EasyTier Core version.")
    if allow_dirty and run_git(root, "status", "--short", "--untracked-files=no"):
        version += "-dirty"
    return version


def gateway_version(root: pathlib.Path) -> str:
    cargo_toml = root / "Rust" / "EasyTierGuiFFI" / "Cargo.toml"
    match = re.search(
        r'^version\s*=\s*"([^"]+)"',
        cargo_toml.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if match is None:
        raise BuildContextError(f"Could not resolve Gateway version from {cargo_toml}.")
    return match.group(1)


def parse_time(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise BuildContextError(f"Invalid build time: {value}") from error
    return parsed.astimezone(timezone.utc)


def format_time(value: datetime) -> tuple[str, str]:
    utc = value.astimezone(timezone.utc)
    return utc.strftime("%Y-%m-%dT%H:%M:%SZ"), utc.strftime("%Y%m%d%H%M%S")


def normalized_time(build_time: str | None, build_number: str | None) -> tuple[str, str]:
    if build_time:
        parsed_time = parse_time(build_time)
    else:
        parsed_time = datetime.now(timezone.utc)
    resolved_time, time_number = format_time(parsed_time)
    resolved_number = build_number or time_number
    if not BUILD_PATTERN.fullmatch(resolved_number):
        raise BuildContextError(f"Build number must contain 14 UTC digits: {resolved_number}")
    return resolved_time, resolved_number


def validate_context(context: BuildContext) -> BuildContext:
    if context.release_channel not in {"none", "stable", "nightly"}:
        raise BuildContextError(f"Invalid release channel: {context.release_channel}")
    if context.app_version and not VERSION_PATTERN.fullmatch(context.app_version):
        raise BuildContextError(f"Invalid app version: {context.app_version}")
    if context.build_number and not BUILD_PATTERN.fullmatch(context.build_number):
        raise BuildContextError(f"Invalid build number: {context.build_number}")
    if context.build_time and not BUILD_TIME_PATTERN.fullmatch(context.build_time):
        raise BuildContextError(f"Invalid build time: {context.build_time}")
    for label, revision in (
        ("GUI", context.gui_revision),
        ("Core", context.core_revision),
    ):
        if not COMMIT_PATTERN.fullmatch(revision):
            raise BuildContextError(f"Invalid {label} revision: {revision}")
    if not context.core_version or context.core_version == "unknown":
        raise BuildContextError("EasyTier Core version must be known.")
    if not context.gateway_version:
        raise BuildContextError("Gateway version must be known.")
    return context


def resolve_local(
    root: pathlib.Path,
    *,
    mode: str,
    app_version: str | None = None,
    build_number: str | None = None,
    build_time: str | None = None,
    release_tag: str | None = None,
    require_release_version: bool = False,
) -> BuildContext:
    if mode not in {"debug", "release"}:
        raise BuildContextError(f"Unsupported local build mode: {mode}")
    resolved_tag = release_tag or ""
    resolved_version = app_version
    if mode == "release" and not resolved_version:
        if not resolved_tag:
            resolved_tag = run_git(root, "describe", "--tags", "--exact-match", "HEAD", check=False)
        if resolved_tag:
            if not re.fullmatch(r"[vV]?[0-9]+(?:\.[0-9]+){1,2}", resolved_tag):
                raise BuildContextError(f"Release tag must be numeric: {resolved_tag}")
            tag_commit = run_git(root, "rev-parse", f"{resolved_tag}^{{commit}}")
            head_commit = run_git(root, "rev-parse", "HEAD")
            if tag_commit != head_commit:
                raise BuildContextError(f"Release tag {resolved_tag} does not resolve to HEAD.")
            resolved_version = resolved_tag.removeprefix("v").removeprefix("V")
            if not build_number:
                tag_epoch = run_git(root, "show", "-s", "--format=%ct", resolved_tag)
                if not tag_epoch.isdigit():
                    raise BuildContextError(f"Could not resolve release timestamp for {resolved_tag}.")
                _, build_number = format_time(datetime.fromtimestamp(int(tag_epoch), timezone.utc))
        elif require_release_version:
            raise BuildContextError(
                "Release packaging requires an exact numeric tag or an explicit APP_VERSION."
            )
    resolved_time, resolved_number = normalized_time(build_time, build_number)
    return validate_context(
        BuildContext(
            mode=mode,
            release_channel="stable",
            should_publish=False,
            app_version=resolved_version or "0.1.0",
            build_number=resolved_number,
            build_time=resolved_time,
            tag_name=resolved_tag,
            gui_revision=repository_revision(root, allow_dirty=True),
            core_revision=repository_revision(root / "Vendor" / "EasyTier", allow_dirty=True),
            core_version=core_version(root / "Vendor" / "EasyTier", allow_dirty=True),
            gateway_version=gateway_version(root),
        )
    )


def latest_stable_tag(root: pathlib.Path) -> str:
    tags = run_git(
        root,
        "for-each-ref",
        "--merged=HEAD",
        "--sort=-creatordate",
        "--format=%(refname:short)",
        "refs/tags",
    ).splitlines()
    for tag in tags:
        if re.fullmatch(r"v[0-9]+(?:\.[0-9]+){1,2}", tag):
            return tag
    raise BuildContextError("Nightly requires a reachable numeric Stable tag.")


def github_run_created_at(repository: str, run_id: str, token: str) -> str:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/actions/runs/{run_id}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise BuildContextError(f"Could not read GitHub run metadata: {error}") from error
    value = str(payload.get("created_at", ""))
    if not value:
        raise BuildContextError("GitHub run metadata did not contain created_at.")
    return value


def fetch_text(url: str, token: str | None = None) -> str:
    headers = {"Cache-Control": "no-cache"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8")


def nightly_sources_changed(
    update_base_url: str,
    gui_revision: str,
    core_revision: str,
    cache_key: str,
) -> tuple[bool, bool]:
    nightly_url = f"{update_base_url.rstrip('/')}/nightly.json?source={cache_key}"
    try:
        payload = json.loads(fetch_text(nightly_url))
        if not isinstance(payload, dict):
            return False, False
        same = payload.get("guiCommit") == gui_revision and payload.get("coreCommit") == core_revision
        return not same, True
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        appcast_url = f"{update_base_url.rstrip('/')}/appcast.xml?source={cache_key}"
        try:
            appcast = fetch_text(appcast_url)
        except (OSError, urllib.error.URLError):
            return False, False
        if "<sparkle:channel>nightly</sparkle:channel>" in appcast:
            return False, False
        return True, True


def resolve_github(
    root: pathlib.Path,
    *,
    event_name: str,
    ref: str,
    ref_name: str,
    dispatch_mode: str,
    run_created_at: str,
    nightly_releases_enabled: bool,
    update_base_url: str,
    run_id: str,
    run_attempt: str,
    fetch_nightly_core: bool,
) -> BuildContext:
    gui_revision = repository_revision(root, allow_dirty=False)
    core_root = root / "Vendor" / "EasyTier"
    release_channel = "none"
    should_publish = False
    app_version = ""
    tag_name = ""
    build_time = ""
    build_number = ""

    if ref.startswith("refs/tags/"):
        release_channel = "stable"
        should_publish = True
        tag_name = ref_name
        app_version = ref_name.removeprefix("v").removeprefix("V")
        tag_epoch = run_git(root, "show", "-s", "--format=%ct", ref_name)
        if not tag_epoch.isdigit():
            raise BuildContextError(f"Could not resolve release timestamp for {ref_name}.")
        _, build_number = format_time(datetime.fromtimestamp(int(tag_epoch), timezone.utc))
        build_time, _ = format_time(parse_time(run_created_at))
    elif event_name == "schedule" or (event_name == "workflow_dispatch" and dispatch_mode == "nightly"):
        release_channel = "nightly"
        if fetch_nightly_core:
            run_git(core_root, "fetch", "--no-tags", "origin", "main")
            fetched = run_git(core_root, "rev-parse", "FETCH_HEAD")
            run_git(core_root, "checkout", "--detach", fetched)
        stable_tag = latest_stable_tag(root)
        app_version = stable_tag.removeprefix("v")
        build_time, build_number = format_time(parse_time(run_created_at))
        tag_name = f"nightly-{build_number}"

    core_revision = repository_revision(core_root, allow_dirty=False)
    resolved_core_version = core_version(core_root, allow_dirty=False)

    if release_channel == "nightly":
        sources_changed, source_state_available = nightly_sources_changed(
            update_base_url,
            gui_revision,
            core_revision,
            f"{run_id}-{run_attempt}",
        )
        publish_enabled = event_name == "workflow_dispatch" or nightly_releases_enabled
        should_publish = publish_enabled and source_state_available and sources_changed

    return validate_context(
        BuildContext(
            mode="github",
            release_channel=release_channel,
            should_publish=should_publish,
            app_version=app_version,
            build_number=build_number,
            build_time=build_time,
            tag_name=tag_name,
            gui_revision=gui_revision,
            core_revision=core_revision,
            core_version=resolved_core_version,
            gateway_version=gateway_version(root),
        )
    )


def write_pairs(path: str | None, values: Mapping[str, str]) -> None:
    if not path:
        return
    output_path = pathlib.Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("a", encoding="utf-8") as handle:
        for key, value in values.items():
            if "\n" in value or "\r" in value:
                raise BuildContextError(f"Multiline output is not supported for {key}.")
            handle.write(f"{key}={value}\n")


def write_json(path: str | None, context: BuildContext) -> None:
    if not path:
        return
    output_path = pathlib.Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(asdict(context), indent=2, sort_keys=True) + "\n", encoding="utf-8")


def boolean(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off", ""}:
        return False
    raise argparse.ArgumentTypeError(f"Expected a boolean value, got {value!r}.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    local = subparsers.add_parser("local", help="Resolve local Debug or Release metadata.")
    local.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[1]))
    local.add_argument("--mode", choices=("debug", "release"), required=True)
    local.add_argument("--app-version", default=os.environ.get("EASYTIER_APP_VERSION") or os.environ.get("APP_VERSION"))
    local.add_argument("--build-number", default=os.environ.get("EASYTIER_BUILD_NUMBER") or os.environ.get("BUILD_NUMBER"))
    local.add_argument("--build-time", default=os.environ.get("EASYTIER_BUILD_TIME"))
    local.add_argument("--release-tag", default=os.environ.get("EASYTIER_RELEASE_TAG") or os.environ.get("RELEASE_TAG"))
    local.add_argument("--require-release-version", action="store_true")
    local.add_argument("--env-file")
    local.add_argument("--json")

    github = subparsers.add_parser("github", help="Resolve GitHub Actions build and release metadata.")
    github.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[1]))
    github.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    github.add_argument("--ref", default=os.environ.get("GITHUB_REF", ""))
    github.add_argument("--ref-name", default=os.environ.get("GITHUB_REF_NAME", ""))
    github.add_argument("--dispatch-mode", choices=("ci", "nightly"), default="ci")
    github.add_argument("--run-created-at")
    github.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", "local"))
    github.add_argument("--run-attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    github.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "socoldkiller/easytier-macos"))
    github.add_argument("--token", default=os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", ""))
    github.add_argument("--nightly-releases-enabled", type=boolean, default=False)
    github.add_argument("--update-base-url", default="https://socoldkiller.github.io/easytier-macos")
    github.add_argument("--no-fetch-nightly-core", action="store_true")
    github.add_argument("--github-env")
    github.add_argument("--github-output")
    github.add_argument("--json")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        root = pathlib.Path(arguments.root).resolve()
        if arguments.command == "local":
            context = resolve_local(
                root,
                mode=arguments.mode,
                app_version=arguments.app_version,
                build_number=arguments.build_number,
                build_time=arguments.build_time,
                release_tag=arguments.release_tag,
                require_release_version=arguments.require_release_version,
            )
            write_pairs(arguments.env_file, context.environment())
            write_json(arguments.json, context)
        else:
            created_at = arguments.run_created_at
            if not created_at:
                if not arguments.token:
                    raise BuildContextError("GitHub build context requires GH_TOKEN or --run-created-at.")
                created_at = github_run_created_at(arguments.repository, arguments.run_id, arguments.token)
            context = resolve_github(
                root,
                event_name=arguments.event_name,
                ref=arguments.ref,
                ref_name=arguments.ref_name,
                dispatch_mode=arguments.dispatch_mode,
                run_created_at=created_at,
                nightly_releases_enabled=arguments.nightly_releases_enabled,
                update_base_url=arguments.update_base_url,
                run_id=arguments.run_id,
                run_attempt=arguments.run_attempt,
                fetch_nightly_core=not arguments.no_fetch_nightly_core,
            )
            write_pairs(arguments.github_env, context.environment())
            write_pairs(arguments.github_output, context.github_outputs())
            write_json(arguments.json, context)
        print(json.dumps(asdict(context), sort_keys=True))
    except BuildContextError as error:
        print(f"build context error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
