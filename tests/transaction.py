#!/usr/bin/env python3
"""Regression tests for binding_transaction.py boundaries.

Covers hung and flooding subprocesses, concurrent replacement of the target
between validation and exchange, and process death at every phase of the
transaction followed by recovery on the next run.
"""

import hashlib
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(REPO, "binding_transaction.py")
ORIGINAL = b"-- Personal bindings\n"


def load_helper():
    spec = importlib.util.spec_from_file_location("binding_transaction", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fail(message):
    print(f"transaction test: {message}", file=sys.stderr)
    sys.exit(1)


def expect(condition, message):
    if not condition:
        fail(message)


class Case:
    """One scenario. The suite runs inside tests/setup.sh's namespace, where
    /usr/bin/hyprctl and /usr/bin/omarchy are dispatchers that exec the
    per-case scripts written under mock/ and log every call to commands.log."""

    def __init__(self, root, name, enabled=True):
        self.dir = os.path.join(root, name)
        self.hypr = os.path.join(self.dir, "config", "hypr")
        self.mock = os.path.join(self.dir, "mock")
        self.log = os.path.join(self.dir, "commands.log")
        os.makedirs(self.hypr)
        os.makedirs(self.mock)
        self.target = os.path.join(self.hypr, "bindings.lua")
        with open(self.target, "wb") as handle:
            handle.write(ORIGINAL)
        self.set_enabled(enabled)
        self.write_mock("hyprctl", "")

    def set_enabled(self, enabled):
        self.write_mock(
            "omarchy",
            f"""
            if [[ $* == 'plugin list --json' ]]; then
              printf '[{{"id":"reomarchy.workspace-switcher","enabled":{str(enabled).lower()}}}]\\n'
            fi
            """,
        )

    def write_mock(self, name, body):
        path = os.path.join(self.mock, name)
        with open(path, "w") as handle:
            handle.write("#!/bin/bash\n" + textwrap.dedent(body))
        os.chmod(path, 0o755)

    def env(self):
        env = dict(os.environ)
        env["XDG_CONFIG_HOME"] = os.path.join(self.dir, "config")
        env["HOME"] = self.dir
        return env

    def apply_env(self):
        for key, value in self.env().items():
            os.environ[key] = value

    def read_target(self):
        with open(self.target, "rb") as handle:
            return handle.read()

    def marker_exists(self):
        return os.path.exists(os.path.join(self.hypr, ".workspace-switcher-transaction.json"))

    def temp_files(self):
        return [n for n in os.listdir(self.hypr) if n.startswith(".workspace-switcher-bindings.")]

    def logged(self):
        if not os.path.exists(self.log):
            return ""
        with open(self.log) as handle:
            return handle.read()

    def run_helper(self, action, env_extra=None):
        env = self.env()
        env.update(env_extra or {})
        return subprocess.run(
            ["/usr/bin/python3", "-I", HELPER, action, self.hypr],
            capture_output=True,
            text=True,
            env=env,
        )


def installed_contents(module):
    return ORIGINAL + b"\n" + module.MANAGED_BLOCK


def in_process(case, action, patch=None):
    """Run a transaction in-process so functions can be monkeypatched."""
    module = load_helper()
    module.COMMAND_TIMEOUTS = {"hyprctl": 1.0, "omarchy": 1.0}
    module.TERMINATE_GRACE_SECONDS = 0.2
    if patch:
        patch(module)
    case.apply_env()
    try:
        module.transact(action, case.hypr)
    except module.TransactionError as error:
        return module, str(error)
    return module, None


def test_hung_command(root):
    case = Case(root, "hung")
    pgid_file = os.path.join(case.dir, "pgid")
    case.write_mock(
        "hyprctl",
        f"""
        if [[ $1 == reload ]]; then
          ps -o pgid= -p $$ | tr -d ' ' > {pgid_file}
          sleep 300 &
          sleep 300
        fi
        """,
    )
    started = time.monotonic()
    module, error = in_process(case, "install")
    elapsed = time.monotonic() - started
    expect(error and "did not finish" in error, f"hung reload was not detected: {error}")
    expect(elapsed < 10, f"hung reload took {elapsed:.1f}s to fail")
    expect(case.read_target() == ORIGINAL, "hung reload left the edited file in place")
    # The restore's own validation hangs too, so the marker must stay for retry.
    expect("rollback also failed" in error, f"hung rollback validation not reported: {error}")
    expect(case.marker_exists(), "marker discarded although restore validation never completed")
    with open(pgid_file) as handle:
        pgid = int(handle.read().strip())
    time.sleep(0.2)
    try:
        os.killpg(pgid, 0)
        fail("process group of the hung command survived")
    except ProcessLookupError:
        pass
    # Once hyprctl responds again, the next run finishes the recovery.
    case.write_mock("hyprctl", "")
    recovery = case.run_helper("check")
    expect(recovery.returncode == 0 and recovery.stdout.strip() == "absent", f"recovery after hang failed: {recovery.stderr}")
    expect(not case.marker_exists(), "marker not cleared after recovery from hang")


def test_output_flood(root):
    case = Case(root, "flood")
    case.write_mock(
        "hyprctl",
        """
        flooded="$XDG_CONFIG_HOME/../flooded"
        if [[ $1 == configerrors && ! -e $flooded ]]; then
          : > "$flooded"
          yes 'error' | head -c 8000000
        fi
        """,
    )
    module, error = in_process(case, "install")
    expect(error and "more than" in error, f"output flood was not capped: {error}")
    expect(case.read_target() == ORIGINAL, "output flood left the edited file in place")
    expect(not case.marker_exists(), "output flood left the transaction marker behind")


def test_concurrent_replace(root):
    case = Case(root, "concurrent")
    intruder = b"-- Concurrent edit by another tool\n"

    def patch(module):
        real = module.current_target_matches

        def race(directory_fd, expected_stat):
            real(directory_fd, expected_stat)
            # Another editor atomically replaces the target after the check
            # and before the exchange.
            temp = case.target + ".other"
            with open(temp, "wb") as handle:
                handle.write(intruder)
            os.replace(temp, case.target)

        module.current_target_matches = race

    module, error = in_process(case, "install", patch)
    expect(error and "replaced concurrently" in error, f"concurrent replace not detected: {error}")
    expect(case.read_target() == intruder, "concurrent edit was overwritten")
    expect(not case.temp_files(), "staging file left behind after concurrent replace")
    expect(not case.marker_exists(), "marker left behind after concurrent replace")
    expect("plugin enable" not in case.logged(), "plugin enabled despite failed replace")


CRASH_POINTS = [
    ("after-backup", "create_backup"),
    ("after-marker", "write_marker"),
    ("after-replace", "replace_target"),
    ("after-validate", "validate_hyprland"),
    ("after-enable", "enable_plugin"),
]

CRASH_DRIVER = """
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("bt", sys.argv[1])
bt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bt)
name = sys.argv[2]
real = getattr(bt, name)
def crash(*args, **kwargs):
    result = real(*args, **kwargs)
    os._exit(137)
setattr(bt, name, crash)
bt.transact("install", sys.argv[3])
"""


def test_crash_recovery(root):
    module = load_helper()
    for label, function in CRASH_POINTS:
        case = Case(root, f"crash-{label}", enabled=False)
        result = subprocess.run(
            ["/usr/bin/python3", "-I", "-c", CRASH_DRIVER, HELPER, function, case.hypr],
            capture_output=True,
            text=True,
            env=case.env(),
        )
        expect(result.returncode == 137, f"{label}: driver did not crash ({result.stderr})")
        marker_path = os.path.join(case.hypr, ".workspace-switcher-transaction.json")
        if function in ("create_backup",):
            expect(not os.path.exists(marker_path), f"{label}: marker present before it was written")
            expect(case.read_target() == ORIGINAL, f"{label}: target changed before marker")
        else:
            expect(os.path.exists(marker_path), f"{label}: durable marker missing after crash")
            with open(marker_path) as handle:
                record = json.load(handle)
            expect(record["previously_enabled"] is False, f"{label}: marker lost plugin state")
        if function in ("replace_target", "validate_hyprland", "enable_plugin"):
            expect(case.read_target() == installed_contents(module), f"{label}: edit not applied")

        # Recovery runs on the next invocation, here the read-only check path.
        log_before = case.logged()
        recovery = case.run_helper("check")
        expect(recovery.returncode == 0, f"{label}: recovery failed: {recovery.stderr}")
        expect(recovery.stdout.strip() == "absent", f"{label}: state after recovery was {recovery.stdout!r}")
        expect(case.read_target() == ORIGINAL, f"{label}: original content not restored")
        expect(not os.path.exists(marker_path), f"{label}: marker not cleared after recovery")
        expect(not case.temp_files(), f"{label}: staging files left after recovery")
        log = case.logged()
        if function == "enable_plugin":
            expect("plugin disable" in log, f"{label}: plugin state not restored on recovery")
        else:
            expect("plugin disable" not in log, f"{label}: plugin disabled although enable was never reached")
        if function in ("replace_target", "validate_hyprland", "enable_plugin"):
            expect("reload" in log[len(log_before):], f"{label}: Hyprland not reloaded after restore")
        backups = [n for n in os.listdir(case.hypr) if ".bak.workspace-switcher-install." in n]
        expect(len(backups) == 1, f"{label}: expected one durable backup, found {backups}")
        with open(os.path.join(case.hypr, backups[0]), "rb") as handle:
            expect(handle.read() == ORIGINAL, f"{label}: backup content mismatch")

        # A clean install must succeed after recovery.
        rerun = case.run_helper("install")
        expect(rerun.returncode == 0, f"{label}: install after recovery failed: {rerun.stderr}")
        expect(case.read_target() == installed_contents(module), f"{label}: install after recovery incomplete")


def test_replace_after_exchange(root):
    """A non-cooperating editor replaces bindings.lua after the exchange."""
    intruder = b"-- Replaced after the exchange\n"
    for stage in ("validate_hyprland", "enable_plugin"):
        case = Case(root, f"post-exchange-{stage}", enabled=False)

        def patch(module, stage=stage):
            real = getattr(module, stage)

            def race(*args, **kwargs):
                result = real(*args, **kwargs)
                temp = case.target + ".other"
                with open(temp, "wb") as handle:
                    handle.write(intruder)
                os.replace(temp, case.target)
                return result

            setattr(module, stage, race)

        module, error = in_process(case, "install", patch)
        expect(error and "replaced by another program" in error, f"{stage}: replacement not detected: {error}")
        expect(case.read_target() == intruder, f"{stage}: foreign file was overwritten")
        expect(not case.marker_exists(), f"{stage}: marker left behind")
        expect(not case.temp_files(), f"{stage}: staging files left behind")
        log = case.logged()
        if stage == "enable_plugin":
            expect("plugin enable" in log and "plugin disable" in log, f"{stage}: enable not undone")
        else:
            expect("plugin enable" not in log, f"{stage}: plugin enabled against a foreign file")
        # Nothing is pending, so a later check reports the foreign file as-is.
        check = case.run_helper("check")
        expect(check.returncode == 0 and check.stdout.strip() == "absent", f"{stage}: post-state check failed: {check.stderr}")
        expect(case.read_target() == intruder, f"{stage}: recovery touched the foreign file")


def test_independent_enable_after_crash(root):
    """A crash before replacement, then the user enables the plugin themselves.
    Recovery must not undo that enable."""
    case = Case(root, "independent-enable", enabled=False)
    result = subprocess.run(
        ["/usr/bin/python3", "-I", "-c", CRASH_DRIVER, HELPER, "write_marker", case.hypr],
        capture_output=True,
        text=True,
        env=case.env(),
    )
    expect(result.returncode == 137, f"driver did not crash ({result.stderr})")
    expect(case.marker_exists(), "marker missing after crash")
    expect(case.read_target() == ORIGINAL, "target changed before replacement")
    # The user enables the plugin independently.
    case.set_enabled(True)
    log_before = case.logged()
    recovery = case.run_helper("check")
    expect(recovery.returncode == 0, f"recovery failed: {recovery.stderr}")
    expect("plugin disable" not in case.logged()[len(log_before):], "recovery undid an independent enable")
    expect(not case.marker_exists(), "marker not cleared")
    expect(case.read_target() == ORIGINAL, "target changed by recovery")


def test_tampered_marker(root):
    module = load_helper()
    case = Case(root, "tampered-marker")
    marker_path = os.path.join(case.hypr, ".workspace-switcher-transaction.json")
    with open(marker_path, "w") as handle:
        json.dump(
            {
                "action": "install",
                "backup": "../outside",
                "original_sha256": hashlib.sha256(ORIGINAL).hexdigest(),
                "new_sha256": "0" * 64,
                "mode": 0o644,
                "previously_enabled": True,
                "phase": "staged",
            },
            handle,
        )
    result = case.run_helper("check")
    expect(result.returncode == 1 and "unexpected backup" in result.stderr, "path traversal in marker accepted")
    expect(case.read_target() == ORIGINAL, "tampered marker changed the target")

    # An unrecognised target state is refused rather than guessed at.
    with open(marker_path, "w") as handle:
        json.dump(
            {
                "action": "install",
                "backup": "bindings.lua.bak.workspace-switcher-install.deadbeef",
                "original_sha256": "1" * 64,
                "new_sha256": "2" * 64,
                "mode": 0o644,
                "previously_enabled": True,
                "phase": "replaced",
            },
            handle,
        )
    result = case.run_helper("check")
    expect(result.returncode == 1 and "matches neither" in result.stderr, "unknown marker state was not refused")
    expect(case.read_target() == ORIGINAL, "unknown marker state changed the target")
    expect(os.path.exists(marker_path), "unresolved marker was deleted")


def main():
    with tempfile.TemporaryDirectory(prefix="workspace-switcher-transaction.") as root:
        test_hung_command(root)
        test_output_flood(root)
        test_concurrent_replace(root)
        test_crash_recovery(root)
        test_replace_after_exchange(root)
        test_independent_enable_after_crash(root)
        test_tampered_marker(root)
    print("transaction tests: pass")


if __name__ == "__main__":
    main()
