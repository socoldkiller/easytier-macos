#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import plistlib
import sys
import tempfile
import unittest


ROOT_DIR = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT_DIR / "scripts"))

import release_feed  # noqa: E402

GUI_COMMIT = "a" * 40
CORE_COMMIT = "b" * 40


class ReleaseFeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary_directory.name)
        self.app = self.root / "EasyTier.app"
        info_path = self.app / "Contents" / "Info.plist"
        info_path.parent.mkdir(parents=True)
        with info_path.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": "1.4.0",
                    "CFBundleVersion": "20260714010203",
                    "EasyTierBuildChannel": "stable",
                    "EasyTierBuildTime": "2026-07-14T01:02:03Z",
                    "EasyTierCoreCommit": CORE_COMMIT,
                    "EasyTierCoreTag": "v2.6.4",
                    "EasyTierGUICommit": GUI_COMMIT,
                },
                handle,
            )
        self.metadata = self.root / "EasyTier-macOS-ARM64.metadata.json"
        release_feed.write_metadata(self.app, self.metadata, "arm64")
        self.dmg = self.root / "EasyTier-macOS-ARM64.dmg"
        self.dmg.write_bytes(b"not-a-real-dmg-but-stable-test-bytes")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_writes_and_validates_release_metadata(self) -> None:
        release_feed.validate_artifact(self.metadata, self.dmg, "ARM64")
        value = json.loads(self.metadata.read_text(encoding="utf-8"))
        self.assertEqual(value["schemaVersion"], 2)
        self.assertEqual(value["architecture"], "ARM64")
        self.assertEqual(value["version"], "1.4.0")
        self.assertEqual(value["build"], "20260714010203")
        self.assertEqual(value["buildTime"], "2026-07-14T01:02:03Z")
        self.assertEqual(value["channel"], "stable")
        self.assertEqual(value["guiCommit"], GUI_COMMIT)
        self.assertEqual(value["coreCommit"], CORE_COMMIT)
        self.assertEqual(value["coreVersion"], "v2.6.4")
        self.assertEqual(value["signing"], "developer-id")
        self.assertIs(value["notarized"], True)

    def test_publication_context_comes_from_validated_metadata(self) -> None:
        self.assertEqual(
            release_feed.publication_context(self.metadata),
            f"stable\t2026-07-14T01:02:03Z\t{GUI_COMMIT}",
        )

    def test_rejects_unaccepted_notarization(self) -> None:
        result = self.root / "notary.json"
        result.write_text('{"status":"Invalid","id":"submission"}', encoding="utf-8")
        with self.assertRaisesRegex(release_feed.ReleaseError, "was not accepted"):
            release_feed.validate_notary_result(result, "EasyTier.app")

    def test_enforces_monotonic_builds_and_idempotent_tag_reruns(self) -> None:
        current = self.root / "update.json"
        current.write_text(
            json.dumps(
                {
                    "tag": "v1.4.0",
                    "build": "20260714010203",
                    "channel": "stable",
                    "guiCommit": GUI_COMMIT,
                    "coreCommit": CORE_COMMIT,
                }
            ),
            encoding="utf-8",
        )
        release_feed.validate_feed_order(self.metadata, current, "v1.4.0")

        current.write_text(
            json.dumps(
                {
                    "tag": "v1.3.3",
                    "build": "20260714010203",
                    "channel": "stable",
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(release_feed.ReleaseError, "must exceed"):
            release_feed.validate_feed_order(self.metadata, current, "v1.4.0")

        current.write_text(
            json.dumps(
                {
                    "tag": "v1.4.0",
                    "build": "20260714010204",
                    "channel": "stable",
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(release_feed.ReleaseError, "changed CFBundleVersion"):
            release_feed.validate_feed_order(self.metadata, current, "v1.4.0")

    def test_extracts_nonempty_changelog_section(self) -> None:
        changelog = self.root / "CHANGELOG.md"
        changelog.write_text(
            "# Changes\n\n## [1.4.0] - 2026-07-14\n\n- Shipped.\n\n## [1.3.3]\n\n- Older.\n",
            encoding="utf-8",
        )
        notes = release_feed.extract_release_notes(changelog, "v1.4.0")
        self.assertIn("# EasyTier 1.4.0", notes)
        self.assertIn("- Shipped.", notes)
        self.assertNotIn("- Older.", notes)
        self.assertIn("Apple-notarized", notes)

    def test_enforces_nightly_tag_and_source_identity(self) -> None:
        nightly_metadata = self.root / "nightly.metadata.json"
        metadata = json.loads(self.metadata.read_text(encoding="utf-8"))
        metadata.update(
            {
                "build": "20260715020000",
                "buildTime": "2026-07-15T02:00:00Z",
                "channel": "nightly",
            }
        )
        nightly_metadata.write_text(json.dumps(metadata), encoding="utf-8")
        current = self.root / "nightly.json"
        current.write_text(
            json.dumps(
                {
                    "build": "20260714020000",
                    "channel": "nightly",
                    "tag": "nightly-20260714020000",
                }
            ),
            encoding="utf-8",
        )

        release_feed.validate_feed_order(
            nightly_metadata,
            current,
            "nightly-20260715020000",
        )
        with self.assertRaisesRegex(release_feed.ReleaseError, "Nightly tag must match"):
            release_feed.validate_feed_order(
                nightly_metadata,
                current,
                "nightly-20260715020001",
            )

        current.write_text(
            json.dumps(
                {
                    "build": "20260715020000",
                    "channel": "nightly",
                    "coreCommit": "c" * 40,
                    "guiCommit": GUI_COMMIT,
                    "tag": "nightly-20260715020000",
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(release_feed.ReleaseError, "changed coreCommit"):
            release_feed.validate_feed_order(
                nightly_metadata,
                current,
                "nightly-20260715020000",
            )

    def test_generates_legacy_feed_from_the_canonical_dmg(self) -> None:
        output = self.root / "pages" / "update.json"
        release_feed.write_channel_feed(
            self.metadata,
            self.dmg,
            "v1.4.0",
            "socoldkiller/easytier-macos",
            output,
            "15.0",
        )
        value = json.loads(output.read_text(encoding="utf-8"))
        asset = value["assets"]["arm64"]
        self.assertEqual(value["version"], "1.4.0")
        self.assertEqual(value["build"], "20260714010203")
        self.assertEqual(value["channel"], "stable")
        self.assertEqual(value["guiCommit"], GUI_COMMIT)
        self.assertEqual(value["coreCommit"], CORE_COMMIT)
        self.assertEqual(value["minimumSystemVersion"], "15.0")
        self.assertEqual(asset["size"], self.dmg.stat().st_size)
        self.assertEqual(asset["sha256"], release_feed.sha256(self.dmg))
        self.assertTrue(asset["url"].endswith("/v1.4.0/EasyTier-macOS-ARM64.dmg"))

    def test_validates_all_security_relevant_appcast_fields(self) -> None:
        appcast = self.root / "appcast.xml"
        appcast.write_text(
            f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure
        url="https://github.com/socoldkiller/easytier-macos/releases/download/v1.4.0/{self.dmg.name}"
        length="{self.dmg.stat().st_size}"
        sparkle:version="20260714010203"
        sparkle:shortVersionString="1.4.0"
        sparkle:edSignature="test-signature" />
    </item>
  </channel>
</rss>
""",
            encoding="utf-8",
        )
        signature = release_feed.validate_appcast(
            appcast,
            self.metadata,
            self.dmg,
            "v1.4.0",
            "socoldkiller/easytier-macos",
            "15.0",
            "ARM64",
        )
        self.assertEqual(signature, "test-signature")

        invalid = appcast.read_text(encoding="utf-8").replace(
            "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>",
            "<sparkle:hardwareRequirements>x86_64</sparkle:hardwareRequirements>",
        )
        appcast.write_text(invalid, encoding="utf-8")
        with self.assertRaisesRegex(release_feed.ReleaseError, "hardwareRequirements mismatch"):
            release_feed.validate_appcast(
                appcast,
                self.metadata,
                self.dmg,
                "v1.4.0",
                "socoldkiller/easytier-macos",
                "15.0",
                "ARM64",
            )

    def test_validates_combined_stable_and_nightly_appcast(self) -> None:
        nightly_metadata = self.root / "nightly.metadata.json"
        nightly_value = json.loads(self.metadata.read_text(encoding="utf-8"))
        nightly_value.update(
            {
                "build": "20260715010203",
                "buildTime": "2026-07-15T01:02:03Z",
                "channel": "nightly",
                "coreCommit": "c" * 40,
                "guiCommit": "d" * 40,
            }
        )
        nightly_metadata.write_text(json.dumps(nightly_value), encoding="utf-8")
        nightly_dmg = self.root / "EasyTier-macOS-ARM64-nightly-20260715010203.dmg"
        nightly_dmg.write_bytes(b"nightly-dmg-bytes")
        appcast = self.root / "combined-appcast.xml"
        appcast.write_text(
            f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://github.com/socoldkiller/easytier-macos/releases/download/v1.4.0/{self.dmg.name}" length="{self.dmg.stat().st_size}" sparkle:version="20260714010203" sparkle:shortVersionString="1.4.0" sparkle:edSignature="stable-signature" />
    </item>
    <item>
      <sparkle:channel>nightly</sparkle:channel>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://github.com/socoldkiller/easytier-macos/releases/download/nightly-20260715010203/{nightly_dmg.name}" length="{nightly_dmg.stat().st_size}" sparkle:version="20260715010203" sparkle:shortVersionString="1.4.0" sparkle:edSignature="nightly-signature" />
    </item>
  </channel>
</rss>
""",
            encoding="utf-8",
        )

        signature = release_feed.validate_appcast(
            appcast,
            nightly_metadata,
            nightly_dmg,
            "nightly-20260715010203",
            "socoldkiller/easytier-macos",
            "15.0",
            "ARM64",
        )
        self.assertEqual(signature, "nightly-signature")

        output = self.root / "nightly.json"
        release_feed.write_channel_feed(
            nightly_metadata,
            nightly_dmg,
            "nightly-20260715010203",
            "socoldkiller/easytier-macos",
            output,
            "15.0",
        )
        manifest = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(manifest["channel"], "nightly")
        self.assertEqual(manifest["tag"], "nightly-20260715010203")
        self.assertEqual(manifest["guiCommit"], "d" * 40)

        explicit_stable = appcast.read_text(encoding="utf-8").replace(
            "    <item>\n      <sparkle:minimumSystemVersion>",
            "    <item>\n      <sparkle:channel>stable</sparkle:channel>\n      <sparkle:minimumSystemVersion>",
            1,
        )
        appcast.write_text(explicit_stable, encoding="utf-8")
        with self.assertRaisesRegex(release_feed.ReleaseError, "unsupported channel: stable"):
            release_feed.validate_appcast(
                appcast,
                nightly_metadata,
                nightly_dmg,
                "nightly-20260715010203",
                "socoldkiller/easytier-macos",
                "15.0",
                "ARM64",
            )

    def test_generates_nightly_release_notes_from_exact_sources(self) -> None:
        nightly_metadata = self.root / "nightly.metadata.json"
        value = json.loads(self.metadata.read_text(encoding="utf-8"))
        value["channel"] = "nightly"
        value["buildTime"] = "2026-07-14T18:00:00Z"
        nightly_metadata.write_text(json.dumps(value), encoding="utf-8")
        output = self.root / "NIGHTLY_NOTES.md"

        release_feed.write_nightly_release_notes(
            nightly_metadata,
            "socoldkiller/easytier-macos",
            "EasyTier/EasyTier",
            output,
        )

        notes = output.read_text(encoding="utf-8")
        self.assertIn("EasyTier Nightly 2026-07-15", notes)
        self.assertIn(GUI_COMMIT, notes)
        self.assertIn(CORE_COMMIT, notes)
        self.assertIn("Nightly builds may be unstable", notes)


if __name__ == "__main__":
    unittest.main()
