#!/usr/bin/env python3

from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT_DIR = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT_DIR / "scripts" / "build_context.py"
SPEC = importlib.util.spec_from_file_location("easytier_build_context", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
build_context = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = build_context
SPEC.loader.exec_module(build_context)


class BuildContextTests(unittest.TestCase):
    def test_local_context_resolves_metadata_once_without_credentials(self) -> None:
        with (
            mock.patch.object(
                build_context,
                "repository_revision",
                side_effect=["a" * 40 + "-dirty", "b" * 40],
            ),
            mock.patch.object(build_context, "core_version", return_value="v2.6.4"),
            mock.patch.object(build_context, "gateway_version", return_value="0.1.0"),
        ):
            context = build_context.resolve_local(
                ROOT_DIR,
                mode="debug",
                app_version="1.4.1",
                build_number="20260721120304",
                build_time="2026-07-21T12:03:04Z",
            )

        self.assertEqual(context.gui_revision, "a" * 40 + "-dirty")
        self.assertEqual(context.core_revision, "b" * 40)
        self.assertEqual(context.gateway_version, "0.1.0")
        self.assertEqual(context.environment()["EASYTIER_GUI_COMMIT"], "a" * 40 + "-dirty")
        self.assertEqual(context.environment()["EASYTIER_GUI_REVISION"], "")
        serialized = build_context.asdict(context)
        self.assertNotIn("password", serialized)
        self.assertNotIn("private_key", serialized)
        self.assertNotIn("codesign_identity", serialized)

    def test_nightly_context_uses_run_creation_time_and_exact_sources(self) -> None:
        with (
            mock.patch.object(
                build_context,
                "repository_revision",
                side_effect=["a" * 40, "b" * 40],
            ),
            mock.patch.object(build_context, "core_version", return_value="v2.6.4-41-gb"),
            mock.patch.object(build_context, "gateway_version", return_value="0.1.0"),
            mock.patch.object(build_context, "latest_stable_tag", return_value="v1.4.1"),
            mock.patch.object(build_context, "nightly_sources_changed", return_value=(True, True)),
        ):
            context = build_context.resolve_github(
                ROOT_DIR,
                event_name="workflow_dispatch",
                ref="refs/heads/main",
                ref_name="main",
                dispatch_mode="nightly",
                run_created_at="2026-07-21T14:16:28Z",
                nightly_releases_enabled=False,
                update_base_url="https://example.invalid",
                run_id="123",
                run_attempt="1",
                fetch_nightly_core=False,
            )

        self.assertEqual(context.release_channel, "nightly")
        self.assertTrue(context.should_publish)
        self.assertEqual(context.app_version, "1.4.1")
        self.assertEqual(context.build_number, "20260721141628")
        self.assertEqual(context.tag_name, "nightly-20260721141628")
        self.assertEqual(context.gui_revision, "a" * 40)
        self.assertEqual(context.core_revision, "b" * 40)

    def test_nightly_fetches_the_pinned_stable_core(self) -> None:
        pinned_revision = build_context.NIGHTLY_CORE_REVISION

        def git_result(root: pathlib.Path, *arguments: str, check: bool = True) -> str:
            del root, check
            if arguments == ("fetch", "--no-tags", "origin", build_context.NIGHTLY_CORE_REF):
                return ""
            if arguments == ("rev-parse", "FETCH_HEAD^{commit}"):
                return pinned_revision
            if arguments == ("checkout", "--detach", pinned_revision):
                return ""
            self.fail(f"Unexpected git invocation: {arguments}")

        with (
            mock.patch.object(build_context, "run_git", side_effect=git_result) as run_git,
            mock.patch.object(
                build_context,
                "repository_revision",
                side_effect=["a" * 40, pinned_revision],
            ),
            mock.patch.object(build_context, "core_version", return_value="v2.6.4"),
            mock.patch.object(build_context, "gateway_version", return_value="0.1.0"),
            mock.patch.object(build_context, "latest_stable_tag", return_value="v1.4.1"),
            mock.patch.object(build_context, "nightly_sources_changed", return_value=(True, True)),
        ):
            context = build_context.resolve_github(
                ROOT_DIR,
                event_name="schedule",
                ref="refs/heads/main",
                ref_name="main",
                dispatch_mode="ci",
                run_created_at="2026-07-21T18:00:00Z",
                nightly_releases_enabled=True,
                update_base_url="https://example.invalid",
                run_id="123",
                run_attempt="1",
                fetch_nightly_core=True,
            )

        self.assertEqual(context.core_revision, pinned_revision)
        self.assertEqual(context.core_version, "v2.6.4")
        self.assertEqual(run_git.call_count, 3)

    def test_dev_push_publishes_exact_checked_out_sources(self) -> None:
        with (
            mock.patch.object(
                build_context,
                "repository_revision",
                side_effect=["d" * 40, "c" * 40],
            ),
            mock.patch.object(build_context, "core_version", return_value="v2.6.4-dev"),
            mock.patch.object(build_context, "gateway_version", return_value="0.1.0"),
            mock.patch.object(build_context, "latest_stable_tag", return_value="v1.4.1"),
            mock.patch.object(build_context, "run_git") as run_git,
        ):
            context = build_context.resolve_github(
                ROOT_DIR,
                event_name="push",
                ref="refs/heads/dev",
                ref_name="dev",
                dispatch_mode="ci",
                run_created_at="2026-07-26T03:04:05Z",
                nightly_releases_enabled=False,
                update_base_url="https://example.invalid",
                run_id="456",
                run_attempt="1",
                fetch_nightly_core=True,
            )

        self.assertEqual(context.release_channel, "dev")
        self.assertTrue(context.should_publish)
        self.assertEqual(context.app_version, "1.4.1")
        self.assertEqual(context.build_number, "20260726030405")
        self.assertEqual(context.tag_name, "dev-20260726030405")
        self.assertEqual(context.gui_revision, "d" * 40)
        self.assertEqual(context.core_revision, "c" * 40)
        run_git.assert_not_called()

    def test_manual_dev_dispatch_uses_dev_release_identity(self) -> None:
        with (
            mock.patch.object(
                build_context,
                "repository_revision",
                side_effect=["a" * 40, "b" * 40],
            ),
            mock.patch.object(build_context, "core_version", return_value="v2.6.4"),
            mock.patch.object(build_context, "gateway_version", return_value="0.1.0"),
            mock.patch.object(build_context, "latest_stable_tag", return_value="v1.4.1"),
        ):
            context = build_context.resolve_github(
                ROOT_DIR,
                event_name="workflow_dispatch",
                ref="refs/heads/dev",
                ref_name="dev",
                dispatch_mode="dev",
                run_created_at="2026-07-26T03:04:05Z",
                nightly_releases_enabled=False,
                update_base_url="https://example.invalid",
                run_id="456",
                run_attempt="2",
                fetch_nightly_core=False,
            )

        self.assertEqual(context.release_channel, "dev")
        self.assertTrue(context.should_publish)
        self.assertEqual(context.tag_name, "dev-20260726030405")

    def test_scheduled_nightly_does_not_publish_unchanged_sources(self) -> None:
        with (
            mock.patch.object(
                build_context,
                "repository_revision",
                side_effect=["a" * 40, "b" * 40],
            ),
            mock.patch.object(build_context, "core_version", return_value="v2.6.4"),
            mock.patch.object(build_context, "gateway_version", return_value="0.1.0"),
            mock.patch.object(build_context, "latest_stable_tag", return_value="v1.4.1"),
            mock.patch.object(build_context, "nightly_sources_changed", return_value=(False, True)),
        ):
            context = build_context.resolve_github(
                ROOT_DIR,
                event_name="schedule",
                ref="refs/heads/main",
                ref_name="main",
                dispatch_mode="ci",
                run_created_at="2026-07-21T18:00:00Z",
                nightly_releases_enabled=True,
                update_base_url="https://example.invalid",
                run_id="123",
                run_attempt="1",
                fetch_nightly_core=False,
            )

        self.assertFalse(context.should_publish)

    def test_context_outputs_are_single_line_and_appendable(self) -> None:
        context = build_context.BuildContext(
            mode="debug",
            release_channel="stable",
            should_publish=False,
            app_version="1.4.1",
            build_number="20260721120304",
            build_time="2026-07-21T12:03:04Z",
            tag_name="",
            gui_revision="a" * 40,
            core_revision="b" * 40,
            core_version="v2.6.4",
            gateway_version="0.1.0",
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_path = pathlib.Path(temporary_directory) / "environment"
            build_context.write_pairs(str(output_path), context.environment())
            lines = output_path.read_text(encoding="utf-8").splitlines()

        self.assertIn("EASYTIER_BUILD_NUMBER=20260721120304", lines)
        self.assertTrue(all("\n" not in line and "\r" not in line for line in lines))

    def test_release_packaging_requires_a_tag_or_explicit_version(self) -> None:
        with mock.patch.object(build_context, "run_git", return_value=""):
            with self.assertRaisesRegex(
                build_context.BuildContextError,
                "exact numeric tag or an explicit APP_VERSION",
            ):
                build_context.resolve_local(
                    ROOT_DIR,
                    mode="release",
                    require_release_version=True,
                )

    def test_format_time_uses_utc(self) -> None:
        build_time, build_number = build_context.format_time(
            datetime(2026, 7, 21, 14, 16, 28, tzinfo=timezone.utc)
        )
        self.assertEqual(build_time, "2026-07-21T14:16:28Z")
        self.assertEqual(build_number, "20260721141628")

    def test_workflow_delegates_release_decisions_to_build_context(self) -> None:
        workflow = (ROOT_DIR / ".github" / "workflows" / "macos-app.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("./scripts/build.sh context github", workflow)
        self.assertNotIn('git -C Vendor/EasyTier fetch --no-tags origin main', workflow)
        self.assertNotIn('release_channel=none', workflow)

    def test_workflow_skips_automated_tests_for_nightly_releases(self) -> None:
        workflow = (ROOT_DIR / ".github" / "workflows" / "macos-app.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            "if: steps.context.outputs.release_channel != 'nightly'\n"
            "        run: make test",
            workflow,
        )
        self.assertIn("      - dev\n", workflow)
        self.assertIn("inputs.mode == 'dev'", workflow)
        self.assertIn("run: ./scripts/build.sh prune-devs", workflow)

    def test_release_fixtures_do_not_inherit_build_context(self) -> None:
        fixture = (
            ROOT_DIR / "Tests" / "PackagingTests" / "release-pipeline-tests.sh"
        ).read_text(encoding="utf-8")
        context = build_context.BuildContext(
            mode="release",
            release_channel="nightly",
            should_publish=True,
            app_version="1.4.1",
            build_number="20260721153610",
            build_time="2026-07-21T15:36:10Z",
            tag_name="nightly-20260721153610",
            gui_revision="a" * 40,
            core_revision="b" * 40,
            core_version="v2.6.4",
            gateway_version="0.1.0",
        )

        for key in context.environment():
            self.assertIn(key, fixture)


if __name__ == "__main__":
    unittest.main()
