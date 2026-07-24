#!/usr/bin/env python3

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT_DIR = pathlib.Path(__file__).resolve().parents[2]
PRESERVE_SCRIPT = ROOT_DIR / "scripts" / "with-preserved-file.sh"


class PreservedFileTests(unittest.TestCase):
    def run_mutating_command(self, exit_code: int) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = pathlib.Path(temporary_directory)
            tracked_file = temporary_path / "Cargo.lock"
            tracked_file.write_text("original\n", encoding="utf-8")

            mutating_command = temporary_path / "mutate-file"
            mutating_command.write_text(
                """#!/bin/bash
set -eu
printf 'changed\n' > "$1"
exit "$MUTATING_COMMAND_EXIT_CODE"
""",
                encoding="utf-8",
            )
            mutating_command.chmod(0o755)

            environment = os.environ.copy()
            environment["MUTATING_COMMAND_EXIT_CODE"] = str(exit_code)
            result = subprocess.run(
                [
                    str(PRESERVE_SCRIPT),
                    str(tracked_file),
                    str(mutating_command),
                    str(tracked_file),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(tracked_file.read_text(encoding="utf-8"), "original\n")
            return result

    def test_restores_the_file_after_a_successful_command(self) -> None:
        result = self.run_mutating_command(0)

        self.assertEqual(result.returncode, 0)

    def test_restores_the_file_after_a_failed_command(self) -> None:
        result = self.run_mutating_command(23)

        self.assertEqual(result.returncode, 23)

    def test_all_rust_builds_preserve_the_gui_lockfile(self) -> None:
        build_ffi = (ROOT_DIR / "scripts" / "build-ffi.sh").read_text(
            encoding="utf-8"
        )
        test_rust = (ROOT_DIR / "scripts" / "test-rust.sh").read_text(
            encoding="utf-8"
        )

        ffi_wrapper = (
            '"$ROOT_DIR/scripts/with-preserved-file.sh" '
            '"$GUI_FFI_DIR/Cargo.lock" cargo build'
        )
        test_wrapper = (
            '"$ROOT_DIR/scripts/with-preserved-file.sh" '
            '"$LOCKFILE_PATH" \\\n  cargo test'
        )

        self.assertEqual(build_ffi.count(ffi_wrapper), 2)
        self.assertIn(test_wrapper, test_rust)


if __name__ == "__main__":
    unittest.main()
