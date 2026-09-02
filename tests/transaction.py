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
        self.state = os.path.join(self.dir, "plugin-enabled")
        self.set_enabled(enabled)
        self.write_mock("hyprctl", "")
        # The mock keeps real plugin state on disk, so a test can assert what
        # the state actually is after a crash and a recovery rather than
        # inferring it from the command log.
        self.write_mock(
            "omarchy",
            """
            state="$XDG_CONFIG_HOME/../plugin-enabled"
            if [[ $* == 'plugin list --json' ]]; then
              printf '[{"id":"reomarchy.workspace-switcher","enabled":%s}]\\n' "$(cat "$state")"
            elif [[ $* == 'plugin enable reomarchy.workspace-switcher' ]]; then
              [[ -e "$XDG_CONFIG_HOME/../enable-blocks" ]] && {
                printf 'true' > "$state"
                printf '%s' "$$" > "$XDG_CONFIG_HOME/../enable-pid"
                : > "$XDG_CONFIG_HOME/../enable-entered"
                # exec keeps this PID, so the test can kill exactly this
                # process instead of matching on a command line.
                exec sleep 300
              }
              printf 'true' > "$state"
            elif [[ $* == 'plugin disable reomarchy.workspace-switcher' ]]; then
              printf 'false' > "$state"
            fi
            """,
        )

    def set_enabled(self, enabled):
        with open(self.state, "w") as handle:
            handle.write("true" if enabled else "false")

    def enabled(self):
        with open(self.state) as handle:
            return handle.read().strip() == "true"

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

    def marker_phase(self):
        path = os.path.join(self.hypr, ".workspace-switcher-transaction.json")
        if not os.path.exists(path):
            return None
        with open(path) as handle:
            return json.load(handle).get("phase")

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
    ("after-backup", "after:create_backup"),
    ("after-marker", "after:write_marker"),
    ("after-replace", "after:replace_target"),
    ("after-validate", "after:validate_hyprland"),
    ("after-enable", "after:enable_plugin"),
]

CRASH_DRIVER = """
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("bt", sys.argv[1])
bt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bt)
mode, name = sys.argv[2].split(":", 1)
real = getattr(bt, name)
def crash(*args, **kwargs):
    if mode == "before":
        os._exit(137)
    real(*args, **kwargs)
    os._exit(137)
setattr(bt, name, crash)
bt.transact("install", sys.argv[3])
"""


def crash_at(case, spec):
    """Run an install that dies at one point, and return the process result."""
    return subprocess.run(
        ["/usr/bin/python3", "-I", "-c", CRASH_DRIVER, HELPER, spec, case.hypr],
        capture_output=True,
        text=True,
        env=case.env(),
    )


def test_crash_recovery(root):
    module = load_helper()
    for label, function in CRASH_POINTS:
        case = Case(root, f"crash-{label}", enabled=False)
        result = crash_at(case, function)
        expect(result.returncode == 137, f"{label}: driver did not crash ({result.stderr})")
        marker_path = os.path.join(case.hypr, ".workspace-switcher-transaction.json")
        function = function.split(":", 1)[1]
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
        # Recovery never undoes plugin state: a crash cannot establish who last
        # changed it. It restores the file it owns and reports the rest.
        expect("plugin disable" not in log, f"{label}: recovery changed plugin state")
        if function == "enable_plugin":
            expect(case.enabled(), f"{label}: recovery disabled a plugin it did not own")
            expect("plugin state was left unchanged" in recovery.stderr, f"{label}: no plugin-state notice")
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


def test_enable_window(root):
    """Every state around the plugin enable call, with an independent enable.

    The marker phase "enabling" is written before the call is issued, so it can
    never prove the transaction caused the change. Recovery must therefore
    leave plugin state alone in all of these, and only report it.
    """
    module = load_helper()

    # 1. Killed after the phase write but before the call was issued; the user
    #    then enables the plugin themselves.
    case = Case(root, "enable-window-before-call", enabled=False)
    expect(crash_at(case, "before:enable_plugin").returncode == 137, "before-call: no crash")
    expect(case.marker_phase() == "enabling", f"before-call: phase was {case.marker_phase()}")
    expect(not case.enabled(), "before-call: plugin enabled although the call never ran")
    case.set_enabled(True)
    recovery = case.run_helper("check")
    expect(recovery.returncode == 0, f"before-call: recovery failed: {recovery.stderr}")
    expect(case.enabled(), "before-call: recovery undid an independent enable")
    expect("plugin disable" not in case.logged(), "before-call: recovery issued a disable")
    expect(case.read_target() == ORIGINAL, "before-call: file not restored")

    # 2. Killed after the call returned but before the "enabled" phase write.
    case = Case(root, "enable-window-after-return", enabled=False)
    expect(crash_at(case, "after:enable_plugin").returncode == 137, "after-return: no crash")
    expect(case.marker_phase() == "enabling", f"after-return: phase was {case.marker_phase()}")
    expect(case.enabled(), "after-return: enable did not take effect")
    recovery = case.run_helper("check")
    expect(recovery.returncode == 0, f"after-return: recovery failed: {recovery.stderr}")
    expect(case.enabled(), "after-return: recovery disabled the plugin")
    expect("plugin state was left unchanged" in recovery.stderr, "after-return: no notice")
    expect(case.read_target() == ORIGINAL, "after-return: file not restored")

    # 3. Killed while the call was running, after it had already taken effect.
    case = Case(root, "enable-window-during-call", enabled=False)
    entered = os.path.join(case.dir, "enable-entered")
    open(os.path.join(case.dir, "enable-blocks"), "w").close()
    process = subprocess.Popen(
        ["/usr/bin/python3", "-I", HELPER, "install", case.hypr],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=case.env(),
    )
    try:
        deadline = time.monotonic() + 30
        while not os.path.exists(entered):
            expect(time.monotonic() < deadline, "during-call: enable was never entered")
            expect(process.poll() is None, "during-call: helper exited early")
            time.sleep(0.05)
        process.kill()
    finally:
        process.wait(timeout=30)
    os.remove(os.path.join(case.dir, "enable-blocks"))
    # The blocked mock is in its own session, so killing the helper does not
    # reach it. It recorded its own pid, which stays valid across its exec.
    with open(os.path.join(case.dir, "enable-pid")) as handle:
        blocked_pid = int(handle.read())
    try:
        os.kill(blocked_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    expect(case.marker_phase() == "enabling", f"during-call: phase was {case.marker_phase()}")
    expect(case.enabled(), "during-call: enable did not take effect before the kill")
    recovery = case.run_helper("check")
    expect(recovery.returncode == 0, f"during-call: recovery failed: {recovery.stderr}")
    expect(case.enabled(), "during-call: recovery disabled the plugin")
    expect(case.read_target() == ORIGINAL, "during-call: file not restored")

    # 4. Killed before the file was ever replaced, then an independent enable.
    case = Case(root, "enable-window-concurrent", enabled=False)
    expect(crash_at(case, "after:write_marker").returncode == 137, "concurrent: no crash")
    expect(case.marker_phase() == "staged", f"concurrent: phase was {case.marker_phase()}")
    case.set_enabled(True)
    recovery = case.run_helper("check")
    expect(recovery.returncode == 0, f"concurrent: recovery failed: {recovery.stderr}")
    expect(case.enabled(), "concurrent: recovery undid an independent enable")
    expect("plugin disable" not in case.logged(), "concurrent: recovery issued a disable")
    expect("plugin state was left unchanged" not in recovery.stderr,
           "concurrent: reported plugin state although the call was never reached")
    expect(case.read_target() == ORIGINAL, "concurrent: file changed")


def test_scan_bounds(root):
    """A wide, deep, heavy tree must not cost unbounded entries, memory or fds.

    Every directory entry counts toward the budget, not only the Lua files that
    are opened, and descriptors are released as each subtree finishes.
    """
    module = load_helper()
    case = Case(root, "scan-bounds")
    hypr = case.hypr

    # Wide: many non-Lua entries and many directories, none of which are
    # matches, so nothing but the entry budget can stop the walk.
    wide = os.path.join(hypr, "wide")
    os.makedirs(wide)
    for index in range(4000):
        open(os.path.join(wide, f"file{index}.conf"), "w").close()
    for index in range(400):
        os.makedirs(os.path.join(wide, f"dir{index}"))

    # Deep: past the depth limit, so the match below must not be reached.
    deep = os.path.join(hypr, "a", "b", "c", "d", "e")
    os.makedirs(deep)
    with open(os.path.join(deep, "too-deep.lua"), "w") as handle:
        handle.write(module.PLUGIN_ID)

    # Heavy: enough large Lua files to exceed the cumulative byte budget if it
    # were only enforced per file.
    heavy = os.path.join(hypr, "heavy")
    os.makedirs(heavy)
    payload = b"-" * (1024 * 1024)
    for index in range(64):
        with open(os.path.join(heavy, f"big{index}.lua"), "wb") as handle:
            handle.write(payload)

    open_directories = 0
    peak_directories = 0
    real_open = os.open
    real_close = os.close
    tracked = set()

    def counting_open(*args, **kwargs):
        nonlocal open_directories, peak_directories
        file_fd = real_open(*args, **kwargs)
        if kwargs.get("flags", args[1] if len(args) > 1 else 0) & os.O_DIRECTORY:
            tracked.add(file_fd)
            open_directories += 1
            peak_directories = max(peak_directories, open_directories)
        return file_fd

    def counting_close(file_fd):
        nonlocal open_directories
        if file_fd in tracked:
            tracked.discard(file_fd)
            open_directories -= 1
        return real_close(file_fd)

    directory_fd = module.open_directory(hypr)
    os.open = counting_open
    os.close = counting_close
    started = time.monotonic()
    try:
        matches, truncated = module.scan_manual_setup(directory_fd)
    finally:
        os.open = real_open
        os.close = real_close
        real_close(directory_fd)
    elapsed = time.monotonic() - started

    expect(truncated, "wide tree did not report a truncated scan")
    expect(elapsed < module.SCAN_MAX_SECONDS + 10, f"scan took {elapsed:.1f}s")
    expect(
        peak_directories <= module.SCAN_MAX_DEPTH + 1,
        f"scan held {peak_directories} directory descriptors at once",
    )
    expect(open_directories == 0, f"scan leaked {open_directories} directory descriptors")
    expect(
        all("too-deep" not in match for match in matches),
        f"scan descended past the depth limit: {matches}",
    )

    # A match inside the budget is still found, and the scan stays no-follow.
    case = Case(root, "scan-finds-match")
    nested = os.path.join(case.hypr, "conf.d")
    os.makedirs(nested)
    with open(os.path.join(nested, "old.lua"), "w") as handle:
        handle.write(module.PLUGIN_ID)
    outside = os.path.join(case.dir, "outside.lua")
    with open(outside, "w") as handle:
        handle.write(module.PLUGIN_ID)
    os.symlink(outside, os.path.join(case.hypr, "linked.lua"))
    directory_fd = module.open_directory(case.hypr)
    try:
        matches, truncated = module.scan_manual_setup(directory_fd)
    finally:
        real_close(directory_fd)
    expect(matches == ["conf.d/old.lua"], f"unexpected matches: {matches}")
    expect(not truncated, "small tree reported truncation")


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
        test_enable_window(root)
        test_scan_bounds(root)
        test_tampered_marker(root)
    print("transaction tests: pass")


if __name__ == "__main__":
    main()
