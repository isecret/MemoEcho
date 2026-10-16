#!/usr/bin/env python3
"""Exercise release failure handling with fake Apple tools; no keys or network."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("notarize-macos-file.sh")
FAKE_XCRUN = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
state = pathlib.Path(os.environ["NOTARY_TEST_STATE"])
calls = json.loads(state.read_text())
command = sys.argv[1:3]
calls.append(command)
state.write_text(json.dumps(calls))
if command == ["notarytool", "submit"]:
    sys.stdout.buffer.write(plistlib.dumps({
        "id": "synthetic-submission",
        "status": os.environ.get("NOTARY_TEST_STATUS", "Accepted"),
    }))
elif command == ["notarytool", "log"]:
    pathlib.Path(sys.argv[4]).write_text("{}")
elif command == ["stapler", "staple"]:
    sequence = json.loads(os.environ["NOTARY_TEST_STAPLE_CODES"])
    index = calls.count(command) - 1
    sys.exit(sequence[min(index, len(sequence) - 1)])
elif command == ["stapler", "validate"]:
    sys.exit(int(os.environ.get("NOTARY_TEST_VALIDATE_CODE", "0")))
else:
    raise SystemExit("Unexpected tool call")
'''
FAKE_SLEEP = r'''#!/usr/bin/env python3
import os, pathlib, sys
with pathlib.Path(os.environ["NOTARY_TEST_DELAYS"]).open("a") as f:
    f.write(sys.argv[1] + "\n")
'''


class NotarizationRetryTests(unittest.TestCase):
    def run_notarize(self, codes, *, status="Accepted", validate_code=0):
        with tempfile.TemporaryDirectory(prefix="memoecho-notary-test-") as directory:
            root = Path(directory)
            for name, content in [("xcrun", FAKE_XCRUN), ("sleep", FAKE_SLEEP)]:
                tool = root / name
                tool.write_text(content)
                tool.chmod(0o755)
            state, delays = root / "calls.json", root / "delays.txt"
            state.write_text("[]")
            delays.touch()
            artifact = root / "Synthetic App.app"
            artifact.mkdir()
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       RUNNER_TEMP=str(root), NOTARY_TEST_STATE=str(state),
                       NOTARY_TEST_DELAYS=str(delays), NOTARY_TEST_STATUS=status,
                       NOTARY_TEST_STAPLE_CODES=json.dumps(codes),
                       NOTARY_TEST_VALIDATE_CODE=str(validate_code))
            result = subprocess.run(
                ["bash", str(SCRIPT), "--file", str(artifact), "--staple", str(artifact),
                 "--keychain-profile", "synthetic-profile"],
                env=env, capture_output=True, text=True, timeout=10,
            )
            return result, json.loads(state.read_text()), delays.read_text().splitlines()

    def test_success_does_not_retry(self):
        result, calls, delays = self.run_notarize([0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["notarytool", "submit"], ["stapler", "staple"],
                                 ["stapler", "validate"]])
        self.assertEqual(delays, [])

    def test_ticket_lookup_retries_without_resubmitting(self):
        result, calls, delays = self.run_notarize([68, 68, 0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count(["notarytool", "submit"]), 1)
        self.assertEqual(calls.count(["stapler", "staple"]), 3)
        self.assertEqual(calls[-1], ["stapler", "validate"])
        self.assertEqual(delays, ["5", "10"])

    def test_persistent_lookup_failure_stops_after_five_attempts(self):
        result, calls, delays = self.run_notarize([68])
        self.assertEqual(result.returncode, 68)
        self.assertEqual(calls.count(["notarytool", "submit"]), 1)
        self.assertEqual(calls.count(["stapler", "staple"]), 5)
        self.assertNotIn(["stapler", "validate"], calls)
        self.assertEqual(delays, ["5", "10", "20", "40"])

    def test_other_stapler_errors_fail_immediately(self):
        result, calls, delays = self.run_notarize([65])
        self.assertEqual(result.returncode, 65)
        self.assertEqual(calls.count(["stapler", "staple"]), 1)
        self.assertNotIn(["stapler", "validate"], calls)
        self.assertEqual(delays, [])

    def test_rejected_notarization_never_staples(self):
        result, calls, delays = self.run_notarize([0], status="Invalid")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, [["notarytool", "submit"], ["notarytool", "log"]])
        self.assertEqual(delays, [])

    def test_validation_failure_is_not_swallowed_or_retried(self):
        result, calls, delays = self.run_notarize([0], validate_code=65)
        self.assertEqual(result.returncode, 65)
        self.assertEqual(calls.count(["stapler", "staple"]), 1)
        self.assertEqual(calls[-1], ["stapler", "validate"])
        self.assertEqual(delays, [])


if __name__ == "__main__":
    unittest.main()
