#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import plistlib
import re
import unittest


ROOT_DIR = pathlib.Path(__file__).resolve().parents[2]


class GatewayPackagingTests(unittest.TestCase):
    def test_app_disables_automatic_and_sudden_termination(self) -> None:
        with (ROOT_DIR / "Packaging" / "EasyTierMac-Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertIs(info["NSSupportsAutomaticTermination"], False)
        self.assertIs(info["NSSupportsSuddenTermination"], False)

    def test_modern_and_legacy_helpers_are_both_on_demand(self) -> None:
        with (
            ROOT_DIR / "Packaging" / "com.kkrainbow.easytier.mac.helper.plist"
        ).open("rb") as handle:
            modern = plistlib.load(handle)
        legacy_source = (
            ROOT_DIR
            / "Sources"
            / "EasyTierShared"
            / "Privilege"
            / "LegacyPrivilegedHelperService.swift"
        ).read_text(encoding="utf-8")

        self.assertIs(modern["RunAtLoad"], False)
        self.assertRegex(
            legacy_source,
            re.compile(r"<key>RunAtLoad</key>\s*<false/>", re.MULTILINE),
        )

    def test_gateway_xpc_change_bumps_helper_protocol(self) -> None:
        source = (
            ROOT_DIR
            / "Sources"
            / "EasyTierShared"
            / "Privilege"
            / "PrivilegedHelperTypes.swift"
        ).read_text(encoding="utf-8")
        self.assertIn('protocolVersion = "11"', source)


if __name__ == "__main__":
    unittest.main()
