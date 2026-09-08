#!/usr/bin/env python3
"""Read-only startup detection must not invoke transaction recovery."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bindings", ROOT / "binding_transaction.py")
bindings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bindings)


class ProbeTest(unittest.TestCase):
    def check_state(self, contents, expected, journal=None):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "bindings.lua"
            target.write_bytes(contents)
            if journal is not None:
                (Path(directory) / bindings.MARKER_NAME).write_bytes(journal)
            before = {p.name: p.read_bytes() for p in Path(directory).iterdir()}
            output = io.StringIO()
            with patch.object(bindings, "Commands", side_effect=AssertionError("No commands allowed")), \
                 patch.object(bindings, "recover", side_effect=AssertionError("No recovery allowed")), \
                 contextlib.redirect_stdout(output):
                bindings.probe(directory)
            self.assertEqual(output.getvalue().strip(), expected)
            self.assertEqual(before, {p.name: p.read_bytes() for p in Path(directory).iterdir()})

    def test_fresh_setup(self):
        self.check_state(b"-- personal bindings\n", "absent")

    def test_managed_setup(self):
        self.check_state(bindings.MANAGED_BLOCK, "installed")

    def test_legacy_setup(self):
        self.check_state(b'hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher")\n', "manual")

    def test_pending_transaction_is_not_recovered(self):
        self.check_state(bindings.MANAGED_BLOCK, "pending", b"incomplete journal")

    def test_truncated_scan_is_not_absent(self):
        with patch.object(bindings, "scan_manual_setup", return_value=([], True, "test limit")):
            self.check_state(b"-- bindings\n", "unknown")

    def test_symlink_refused_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "real.lua"
            target.write_bytes(b"-- private\n")
            (Path(directory) / "bindings.lua").symlink_to(target)
            with self.assertRaises(bindings.TransactionError):
                bindings.probe(directory)
            self.assertEqual(target.read_bytes(), b"-- private\n")

    def test_terminal_is_independent_of_qml_lifetime(self):
        spec = importlib.util.spec_from_file_location("launcher", ROOT / "launch-setup.py")
        launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launcher)
        with patch.object(launcher.subprocess, "Popen") as popen:
            popen.return_value.wait.return_value = 7
            self.assertEqual(launcher.launch(), 7)
            args, kwargs = popen.call_args
            self.assertEqual(args[0][0], "/usr/bin/xdg-terminal-exec")
            self.assertEqual(args[0][-1], str(ROOT / "setup-terminal.sh"))
            self.assertTrue(kwargs["start_new_session"])
            for stream in ("stdin", "stdout", "stderr"):
                self.assertEqual(kwargs[stream], launcher.subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
