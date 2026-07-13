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
        self.assertEqual(value["schemaVersion"], 1)
        self.assertEqual(value["architecture"], "ARM64")
        self.assertEqual(value["version"], "1.4.0")
        self.assertEqual(value["build"], "20260714010203")
        self.assertEqual(value["signing"], "developer-id")
        self.assertIs(value["notarized"], True)

    def test_rejects_unaccepted_notarization(self) -> None:
        result = self.root / "notary.json"
        result.write_text('{"status":"Invalid","id":"submission"}', encoding="utf-8")
        with self.assertRaisesRegex(release_feed.ReleaseError, "was not accepted"):
            release_feed.validate_notary_result(result, "EasyTier.app")

    def test_enforces_monotonic_builds_and_idempotent_tag_reruns(self) -> None:
        current = self.root / "update.json"
        current.write_text(
            json.dumps({"tag": "v1.4.0", "build": "20260714010203"}),
            encoding="utf-8",
        )
        release_feed.validate_feed_order(self.metadata, current, "v1.4.0")

        current.write_text(
            json.dumps({"tag": "v1.3.3", "build": "20260714010203"}),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(release_feed.ReleaseError, "must exceed"):
            release_feed.validate_feed_order(self.metadata, current, "v1.4.0")

        current.write_text(
            json.dumps({"tag": "v1.4.0", "build": "20260714010204"}),
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

    def test_generates_legacy_feed_from_the_canonical_dmg(self) -> None:
        output = self.root / "pages" / "update.json"
        release_feed.write_legacy_feed(
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


if __name__ == "__main__":
    unittest.main()
