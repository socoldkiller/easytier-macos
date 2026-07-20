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

    def test_privileged_helpers_are_on_demand(self) -> None:
        with (
            ROOT_DIR / "Packaging" / "com.kkrainbow.easytier.mac.helper.plist"
        ).open("rb") as handle:
            modern = plistlib.load(handle)
        with (
            ROOT_DIR / "Packaging" / "com.coldkiller.gateway.helper.plist"
        ).open("rb") as handle:
            gateway = plistlib.load(handle)
        legacy_source = (
            ROOT_DIR
            / "Sources"
            / "EasyTierShared"
            / "Privilege"
            / "LegacyPrivilegedHelperService.swift"
        ).read_text(encoding="utf-8")

        self.assertIs(modern["RunAtLoad"], False)
        self.assertIs(gateway["RunAtLoad"], False)
        self.assertEqual(gateway["Label"], "com.coldkiller.gateway.helper")
        self.assertRegex(
            legacy_source,
            re.compile(r"<key>RunAtLoad</key>\s*<false/>", re.MULTILINE),
        )

    def test_gateway_uses_an_independent_xpc_protocol(self) -> None:
        source = (
            ROOT_DIR
            / "Sources"
            / "EasyTierShared"
            / "Privilege"
            / "GatewayHelperTypes.swift"
        ).read_text(encoding="utf-8")
        self.assertIn('bundleIdentifier = "com.coldkiller.gateway.helper"', source)
        self.assertIn('@objc(GatewayPrivilegedServiceProtocol)', source)

        easytier_source = (
            ROOT_DIR
            / "Sources"
            / "EasyTierShared"
            / "Privilege"
            / "PrivilegedHelperTypes.swift"
        ).read_text(encoding="utf-8")
        self.assertNotIn("func gatewayStart", easytier_source)
        self.assertNotIn("func gatewayApply", easytier_source)

    def test_helpers_have_independent_native_linkage_chains(self) -> None:
        package = (ROOT_DIR / "Package.swift").read_text(encoding="utf-8")
        build_script = (ROOT_DIR / "scripts" / "build-ffi.sh").read_text(
            encoding="utf-8"
        )
        core_client = (
            ROOT_DIR
            / "Sources"
            / "EasyTierCoreRuntime"
            / "StaticEasyTierFFIClient.swift"
        ).read_text(encoding="utf-8")
        gateway_client = (
            ROOT_DIR
            / "Sources"
            / "GatewayRuntime"
            / "StaticGatewayFFIClient.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('name: "EasyTierCoreRuntime"', package)
        self.assertIn('name: "GatewayRuntime"', package)
        self.assertIn('"-leasytier_core_ffi"', package)
        self.assertIn('"-lgateway_ffi"', package)
        self.assertIn("--features core", build_script)
        self.assertIn("--features gateway", build_script)
        self.assertIn("import CEasyTierCoreFFI", core_client)
        self.assertIn("import CGatewayFFI", gateway_client)

    def test_native_targets_share_swift_package_access_domain(self) -> None:
        base_configuration = (
            ROOT_DIR / "Configurations" / "Base.xcconfig"
        ).read_text(encoding="utf-8")

        package_name = ROOT_DIR.name.replace("-", "_").lower()

        self.assertIn(f"-package-name {package_name}", base_configuration)

    def test_shared_ffi_symbols_are_not_treated_as_core_only(self) -> None:
        verifier = (ROOT_DIR / "scripts" / "verify-app.sh").read_text(
            encoding="utf-8"
        )

        shared_symbols = re.search(
            r"REQUIRED_SHARED_FFI_SYMBOLS=\((.*?)\)", verifier, re.DOTALL
        )
        core_symbols = re.search(
            r"REQUIRED_FFI_SYMBOLS=\((.*?)\)", verifier, re.DOTALL
        )
        self.assertIsNotNone(shared_symbols)
        self.assertIsNotNone(core_symbols)
        self.assertIn("free_string", shared_symbols.group(1))
        self.assertNotIn("free_string", core_symbols.group(1))

    def test_debug_install_replaces_helpers_without_leaving_stale_daemons(self) -> None:
        install_script = (
            ROOT_DIR / "scripts" / "install-xcode-debug-app.sh"
        ).read_text(encoding="utf-8")

        unregister_index = install_script.index("--unregister-helper")
        replace_index = install_script.index('rm -rf "$DESTINATION_APP"')
        register_index = install_script.index("--register-helper")
        open_index = install_script.index('open "$DESTINATION_APP"')

        self.assertLess(unregister_index, replace_index)
        self.assertLess(replace_index, register_index)
        self.assertLess(register_index, open_index)
        self.assertIn("EASYTIER_SKIP_LEGACY_HELPER_UNINSTALL=1", install_script)


if __name__ == "__main__":
    unittest.main()
