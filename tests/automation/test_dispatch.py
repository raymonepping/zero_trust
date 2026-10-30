from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "automation"))
from cli import main, parse_goals
from common import WorkshopError, manifest


class Dispatch(unittest.TestCase):
    def test_valid_aliases(self):
        self.assertEqual(parse_goals(["resolve", "lab", "03"], ""), ("resolve", "03"))
        self.assertEqual(parse_goals(["resolve"], "03"), ("resolve", "03"))

    def test_invalid_never_discovers_runtime(self):
        for goals, lab in [
            (["resolve"], ""),
            (["resolve", "lab", "00"], ""),
            (["resolve", "lab", "3"], ""),
            (["resolve", "lab", "03"], "03"),
            (["up", "down"], ""),
            (["typo"], ""),
            (["resolve", "lab", "03", "04"], ""),
            (["up"], "03"),
        ]:
            with self.subTest(goals=goals), patch("cli.discover") as discover:
                with self.assertRaises(WorkshopError):
                    main(["--goals", *goals, "--lab", lab])
                discover.assert_not_called()

    def test_make_dispatch_once_parallel_and_sequential(self):
        # Use a fake Python executable to count dispatches without loading runtime code.
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "python"
            log = Path(tmp) / "calls"
            fake.write_text('#!/bin/sh\nprintf "call\\n" >> "' + str(log) + '"\n')
            fake.chmod(0o700)
            for jobs in ["-j1", "-j8"]:
                for goals in [["resolve", "lab", "03"], ["resolve", "LAB=03"]]:
                    log.unlink(missing_ok=True)
                    result = subprocess.run(
                        ["make", jobs, "PYTHON=" + str(fake), *goals],
                        capture_output=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(log.read_text().splitlines(), ["call"])

    def test_all_manifest_connectors_exist(self):
        self.assertEqual(len(manifest()["labs"]), 10)


if __name__ == "__main__":
    unittest.main()
