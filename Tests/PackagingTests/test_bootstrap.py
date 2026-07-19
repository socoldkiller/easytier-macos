#!/usr/bin/env python3

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT_DIR = pathlib.Path(__file__).resolve().parents[2]


class BootstrapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary_directory.name)
        self.scripts = self.root / "scripts"
        self.core = self.root / "Vendor" / "EasyTier"
        self.fake_bin = self.root / "bin"
        self.scripts.mkdir(parents=True)
        self.core.mkdir(parents=True)
        self.fake_bin.mkdir()
        shutil.copy2(ROOT_DIR / "scripts" / "bootstrap.sh", self.scripts / "bootstrap.sh")
        self._install_fake_toolchain()

        self._git("init", cwd=self.core)
        self._git("config", "user.email", "ci@example.invalid", cwd=self.core)
        self._git("config", "user.name", "CI", cwd=self.core)
        (self.core / "Cargo.toml").write_text("[workspace]\n", encoding="utf-8")
        self._git("add", "Cargo.toml", cwd=self.core)
        self._git("commit", "-m", "Pinned core", cwd=self.core)
        self.pinned_revision = self._git("rev-parse", "HEAD", cwd=self.core).stdout.strip()

        (self.core / "Cargo.toml").write_text("[workspace]\nresolver = \"2\"\n", encoding="utf-8")
        self._git("commit", "-am", "Nightly core", cwd=self.core)
        self.nightly_revision = self._git("rev-parse", "HEAD", cwd=self.core).stdout.strip()

        self._git("init", cwd=self.root)
        self._git(
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.pinned_revision},Vendor/EasyTier",
            cwd=self.root,
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_explicit_nightly_core_revision(self) -> None:
        result = self._run_bootstrap(EASYTIER_CORE_REVISION=self.nightly_revision)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Bootstrap complete.", result.stdout)

    def test_rejects_core_revision_that_matches_neither_override_nor_gitlink(self) -> None:
        result = self._run_bootstrap(EASYTIER_CORE_REVISION=self.pinned_revision)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the expected revision", result.stderr)

    def test_requires_gitlink_without_explicit_revision(self) -> None:
        result = self._run_bootstrap()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the expected revision", result.stderr)

    def test_rejects_invalid_explicit_revision(self) -> None:
        result = self._run_bootstrap(EASYTIER_CORE_REVISION="latest")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be a full lowercase Git SHA", result.stderr)

    def _run_bootstrap(self, **environment: str) -> subprocess.CompletedProcess[str]:
        process_environment = os.environ.copy()
        process_environment.update(environment)
        process_environment["PATH"] = f"{self.fake_bin}:{process_environment['PATH']}"
        return subprocess.run(
            [str(self.scripts / "bootstrap.sh")],
            cwd=self.root,
            env=process_environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def _install_fake_toolchain(self) -> None:
        versions = {
            "swift": "Swift version 6.0",
            "xcodebuild": "Xcode 16.0",
            "cargo": "cargo 1.80.0",
            "rustc": "rustc 1.80.0",
            "protoc": "libprotoc 29.0",
        }
        for command, version in versions.items():
            path = self.fake_bin / command
            path.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' '{version}'\n", encoding="utf-8")
            path.chmod(0o755)

    @staticmethod
    def _git(*arguments: str, cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            text=True,
            capture_output=True,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
