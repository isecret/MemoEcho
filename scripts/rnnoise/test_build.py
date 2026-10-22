#!/usr/bin/env python3
"""Verify source isolation with synthetic files; never invoke Git or a compiler."""

import hashlib
import importlib.util
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("rnnoise_build", Path(__file__).with_name("build.py"))
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class SourceSnapshotTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rnnoise-source-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / "original"
        self.destination = self.root / "snapshot"
        self.contents = {
            "src/rnnoise_data.c": b"/* synthetic model weights */\n",
            "include/rnnoise.h": b"/* synthetic RNNoise API */\n",
            "COPYING": b"Synthetic license fixture.\n",
        }
        for name, content in self.contents.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        hashes = {name: hashlib.sha256(content).hexdigest()
                  for name, content in self.contents.items()}
        self.lock = {"model_sha256": hashes["src/rnnoise_data.c"], "files": hashes}
        for method in ("run", "check_output"):
            patch = mock.patch.object(BUILD.subprocess, method,
                                      side_effect=AssertionError("External tools must not run in snapshot tests"))
            patch.start()
            self.addCleanup(patch.stop)

    def snapshot(self):
        return BUILD.snapshot_source(self.lock, self.source, self.destination)

    def test_verified_files_are_copied_exactly(self):
        self.assertEqual(self.snapshot(), self.destination)
        copied = {str(path.relative_to(self.destination)): path.read_bytes()
                  for path in self.destination.rglob("*") if path.is_file()}
        self.assertEqual(copied, self.contents)

    def test_unlocked_headers_cannot_enter_compilation_snapshot(self):
        (self.source / "src/math.h").write_text("#error Unverified SDK override\n")
        (self.source / "include/config.h").write_text("#define DISABLE_DEBUG_FLOAT 1\n")
        self.snapshot()
        self.assertFalse((self.destination / "src/math.h").exists())
        self.assertFalse((self.destination / "include/config.h").exists())
        self.assertEqual(len(list(self.destination.rglob("*.h"))), 1)

    def test_modified_locked_file_is_rejected(self):
        (self.source / "include/rnnoise.h").write_bytes(b"modified API\n")
        with self.assertRaisesRegex(SystemExit, "checksum mismatch: include/rnnoise.h"):
            self.snapshot()

    def test_missing_locked_file_is_rejected(self):
        (self.source / "src/rnnoise_data.c").unlink()
        with self.assertRaisesRegex(SystemExit, "checksum mismatch: src/rnnoise_data.c"):
            self.snapshot()

    def test_symlink_is_rejected_even_with_matching_content(self):
        target = self.root / "external-header.h"
        target.write_bytes(self.contents["include/rnnoise.h"])
        original = self.source / "include/rnnoise.h"
        original.unlink()
        original.symlink_to(target)
        with self.assertRaisesRegex(SystemExit, "checksum mismatch: include/rnnoise.h"):
            self.snapshot()

    def test_model_hash_must_match_locked_model_file(self):
        self.lock["model_sha256"] = hashlib.sha256(b"another model").hexdigest()
        with self.assertRaisesRegex(SystemExit, "model hash disagrees"):
            self.snapshot()
        self.assertFalse(self.destination.exists())

    def test_later_source_edits_do_not_change_verified_snapshot(self):
        self.snapshot()
        for name, expected in self.contents.items():
            original = self.source / name
            copied = self.destination / name
            self.assertNotEqual(original.stat().st_ino, copied.stat().st_ino)
            original.write_bytes(b"modified after verification\n")
            self.assertEqual(copied.read_bytes(), expected)


class FloatOutputGuardTests(unittest.TestCase):
    def test_float_cannot_replace_app_default_or_enter_bundled_subdirectory(self):
        for output in (None, BUILD.DEFAULT_OUTPUT, BUILD.DEFAULT_OUTPUT / "comparison"):
            argv = ["build.py", "--inference", "float"]
            if output is not None:
                argv += ["--output-dir", str(output)]
            with self.subTest(output=output), mock.patch.object(sys, "argv", argv), \
                    mock.patch.dict(BUILD.os.environ, {"RNNOISE_LIB_PATH": ""}), \
                    mock.patch.object(BUILD, "source_tree") as source, \
                    contextlib.redirect_stderr(io.StringIO()) as error:
                with self.assertRaises(SystemExit) as result:
                    BUILD.main()
                self.assertEqual(result.exception.code, 2)
                self.assertIn("outside the app RNNoise resources", error.getvalue())
                source.assert_not_called()


if __name__ == "__main__":
    unittest.main()
