#!/usr/bin/env python3
"""Exercise runtime packaging with real universal Mach-O fixtures; no credentials."""
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "strip_asr_runtime", Path(__file__).with_name("strip-asr-runtime.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class StripASRRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_directory = tempfile.TemporaryDirectory(prefix="memoecho-strip-fixture-")
        cls.addClassCleanup(cls.fixture_directory.cleanup)
        root = Path(cls.fixture_directory.name)
        source = root / "fixture.c"
        source.write_text("static int local_helper(int x) { return x + 1; }\n"
                          "int exported_entry(int x) { return local_helper(x); }\n")
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        slices = []
        for architecture in ("arm64", "x86_64"):
            output = root / f"{architecture}.dylib"
            subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-isysroot", sdk,
                            "-dynamiclib", "-g", "-O0",
                            "-arch", architecture, "-mmacosx-version-min=14.0",
                            str(source), "-o", str(output)], check=True, capture_output=True)
            slices.append(str(output))
        cls.fixture = root / "universal.dylib"
        subprocess.run(["xcrun", "lipo", "-create", *slices, "-output", str(cls.fixture)],
                       check=True, capture_output=True)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="memoecho-strip-test-")
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name) / "Synthetic App.app"
        self.root = self.app / "Contents/Resources/sherpa-onnx/lib"
        self.root.mkdir(parents=True)
        for name in MODULE.LIBRARIES:
            shutil.copy2(self.fixture, self.root / name)
        self.alias = self.root / "libonnxruntime.dylib"
        self.alias.symlink_to(MODULE.LIBRARIES[0])

    def test_strips_local_symbols_preserving_both_architectures_and_public_api(self):
        source_hash = digest(self.fixture)
        original = MODULE.exported_api(self.fixture)
        MODULE.strip_runtime(self.app)
        for name in MODULE.LIBRARIES:
            library = self.root / name
            self.assertEqual(MODULE.exported_api(library), original)
            for architecture in ("arm64", "x86_64"):
                self.assertNotIn("_local_helper", MODULE.run_tool(
                    "nm", "-arch", architecture, "-j", library))
            first_hash = digest(library)
            MODULE.strip_runtime(self.app)
            self.assertEqual(digest(library), first_hash)
        self.assertEqual(digest(self.fixture), source_hash)
        self.assertTrue(self.alias.is_symlink())
        self.assertEqual(self.alias.readlink(), Path(MODULE.LIBRARIES[0]))

    def test_missing_second_library_leaves_first_untouched(self):
        first = self.root / MODULE.LIBRARIES[0]
        before = digest(first)
        (self.root / MODULE.LIBRARIES[1]).unlink()
        with self.assertRaisesRegex(ValueError, "regular runtime"):
            MODULE.strip_runtime(self.app)
        self.assertEqual(digest(first), before)

    def test_rejects_library_symlink_without_touching_target(self):
        path = self.root / MODULE.LIBRARIES[0]
        path.unlink()
        path.symlink_to(self.fixture)
        before = digest(self.fixture)
        with self.assertRaisesRegex(ValueError, "regular runtime"):
            MODULE.strip_runtime(self.app)
        self.assertEqual(digest(self.fixture), before)

    def test_api_change_in_second_candidate_keeps_both_originals(self):
        originals = {name: digest(self.root / name) for name in MODULE.LIBRARIES}
        inspect = MODULE.exported_api

        def changed_exports(path):
            result = inspect(path)
            if path.parent.name.startswith(".strip-asr-") and path.name == MODULE.LIBRARIES[1]:
                result["arm64"] = ["_unexpected_api"]
            return result

        with patch.object(MODULE, "exported_api", side_effect=changed_exports):
            with self.assertRaisesRegex(ValueError, "exported runtime API"):
                MODULE.strip_runtime(self.app)
        self.assertEqual({name: digest(self.root / name) for name in MODULE.LIBRARIES}, originals)
        self.assertEqual(list(self.root.glob(".strip-asr-*")), [])


if __name__ == "__main__":
    unittest.main()
