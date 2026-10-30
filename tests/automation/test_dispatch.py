from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "automation"))
from cli import confirm_reset, main, parse_goals, reset_instance
from common import WorkshopError, manifest


class FakeEngine:
    """Records calls; resources disappear once removed, unless told to survive."""

    def __init__(self, survivors=()):
        self.calls = []
        self.survivors = set(survivors)
        self.removed = False

    def __call__(self, argv, capture=False):
        self.calls.append(argv[1:])
        if argv[1] in ("rm", "rmi") or argv[1:3] in (["volume", "rm"], ["network", "rm"]):
            self.removed = True
            return ""
        if argv[1] == "images":
            return "abc"
        if "--filter" in argv:
            kind = argv[1]
            if self.removed and kind not in self.survivors:
                return ""
            return kind + "-one"
        return ""


class Reset(unittest.TestCase):
    def test_refuses_without_exact_confirmation(self):
        for value in [None, "", "other", "WORKSHOP"]:
            with patch("sys.stdin.isatty", return_value=False):
                with self.assertRaises(WorkshopError):
                    confirm_reset("workshop", value)
        confirm_reset("workshop", "workshop")
        with patch("sys.stdin.isatty", return_value=True):
            with patch("builtins.input", side_effect=EOFError):
                with self.assertRaises(WorkshopError):
                    confirm_reset("workshop")
            # Make exports an unset CONFIRM as an empty string.
            for unset in [None, ""]:
                with patch("builtins.input", return_value="workshop"):
                    confirm_reset("workshop", unset)

    def test_removes_only_the_exact_project_then_private_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            mine, other = Path(tmp) / "mine", Path(tmp) / "mine-two"
            mine.mkdir()
            other.mkdir()
            engine = FakeEngine()
            reset_instance("podman", "zt-mine", [mine], runner=engine)
            self.assertFalse(mine.exists())
            self.assertTrue(other.exists())
        lists = [c for c in engine.calls if "--filter" in c]
        self.assertTrue(lists)
        for call in lists:
            self.assertIn("label=com.docker.compose.project=zt-mine", call)
        self.assertIn(["rmi", "-f", "zt-mine-backend"], engine.calls)

    def test_keeps_unseal_keys_when_a_volume_survives(self):
        with tempfile.TemporaryDirectory() as tmp:
            private = Path(tmp) / "private"
            private.mkdir()
            with self.assertRaises(WorkshopError):
                reset_instance(
                    "podman", "zt-x", [private], runner=FakeEngine(["volume"])
                )
            self.assertTrue(private.exists())


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
