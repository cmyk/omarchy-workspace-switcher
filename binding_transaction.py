#!/usr/bin/python3 -I
"""Safely install or remove the Workspace Switcher Hyprland loader block."""

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time


PLUGIN_ID = "reomarchy.workspace-switcher"
TARGET_NAME = "bindings.lua"
MARKER_NAME = ".workspace-switcher-transaction.json"
TEMP_PREFIX = ".workspace-switcher-bindings."
BEGIN_MARKER = b"-- Workspace Switcher: begin"
END_MARKER = b"-- Workspace Switcher: end"
MANAGED_BLOCK = b"""-- Workspace Switcher: begin
do
  local config_home = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
  local path = config_home .. "/omarchy/plugins/reomarchy.workspace-switcher/bindings.lua"
  local file = io.open(path, "r")
  if file then
    file:close()
    dofile(path)
  end
end
-- Workspace Switcher: end
"""

# Resource bounds. A Hyprland binding file is hand-written configuration; a
# file beyond these limits is refused before it is materialized in memory.
MAX_TARGET_BYTES = 4 * 1024 * 1024
MAX_TARGET_LINES = 100_000
MAX_MARKER_BYTES = 64 * 1024
MAX_COMMAND_OUTPUT_BYTES = 1024 * 1024
COMMAND_TIMEOUTS = {
    "hyprctl": 20.0,
    "omarchy": 60.0,
}
TERMINATE_GRACE_SECONDS = 2.0
RENAME_EXCHANGE = 1 << 1

# Fixed, root-owned tool locations. Nothing is resolved through PATH.
# "descriptor": executed through the verified descriptor (ELF binaries).
# "path": executed by its fixed pathname after the same inode verification,
# because the tool is a script that locates its helpers via BASH_SOURCE and
# must see its real path. Its directory is verified root-owned and not writable
# by others, so only root could swap the entry after verification.
TRUSTED_TOOLS = {
    "hyprctl": ("/usr/bin/hyprctl", "descriptor"),
    "omarchy": ("/usr/bin/omarchy", "path"),
}
# Fixed values handed to children; never inherited.
CHILD_FIXED_ENVIRONMENT = {
    "PATH": "/usr/bin:/bin",
    "OMARCHY_PATH": "/usr/share/omarchy",
}
# The only variables a child process inherits.
ENVIRONMENT_ALLOWLIST = (
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "TERM",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_STATE_HOME",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
    "HYPRLAND_INSTANCE_SIGNATURE",
    "WAYLAND_DISPLAY",
    "DBUS_SESSION_BUS_ADDRESS",
)

# Bounds for the manual-setup scan of the Hyprland config tree. Every directory
# entry counts, not only the Lua files that are opened, and the walk stops at
# the first budget that runs out.
SCAN_MAX_DEPTH = 4
SCAN_MAX_ENTRIES = 5000
SCAN_MAX_FILES = 2000
SCAN_MAX_FILE_BYTES = 1024 * 1024
SCAN_MAX_TOTAL_BYTES = 32 * 1024 * 1024
SCAN_MAX_SECONDS = 10.0
SCAN_MAX_MATCHES = 20
SUPER_TAB_PATTERN = re.compile(rb"SUPER\s*\+\s*(SHIFT\s*\+\s*)?TAB", re.IGNORECASE)


class TransactionError(Exception):
    pass


def fail(message):
    raise TransactionError(message)


def nofollow_flags():
    return getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)


# --- trusted executables and bounded subprocesses ---------------------------


def require_private_to_user(info, what):
    """Refuse anything another unprivileged user could rewrite underneath us.

    The transaction relies on advisory locks and on inode identity, and both
    assume no second writer outside this user's control.
    """
    if info.st_uid != os.geteuid():
        fail(f"refusing {what}: not owned by the current user")
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail(
            f"refusing {what}: writable by group or other; tighten its "
            "permissions (chmod go-w) before running setup"
        )


def require_root_owned(info, what):
    if info.st_uid != 0:
        fail(f"refusing {what}: not owned by root")
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail(f"refusing {what}: writable by other users")


def open_trusted_executable(name):
    """Open a fixed root-owned tool and return (descriptor, argv0).

    The descriptor is bound to the verified inode. For descriptor-mode tools
    argv0 is the /proc path of that descriptor, so the identity that was
    verified is the identity that runs. For path-mode tools argv0 is the fixed
    pathname, and the containing directory is verified as well.
    """
    path, mode = TRUSTED_TOOLS[name]
    directory, _ = os.path.split(path)
    try:
        directory_info = os.stat(directory, follow_symlinks=False)
    except OSError as error:
        fail(f"cannot inspect {directory}: {error}")
    if not stat.S_ISDIR(directory_info.st_mode):
        fail(f"refusing {name}: {directory} is not a directory")
    require_root_owned(directory_info, f"{name} directory {directory}")
    try:
        file_fd = os.open(path, os.O_RDONLY | nofollow_flags())
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail(f"refusing {name}: {path} is a symlink")
        fail(f"required command unavailable: {path}: {error}")
    try:
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
            fail(f"refusing non-executable {name} at {path}")
        require_root_owned(info, f"{name} at {path}")
    except BaseException:
        os.close(file_fd)
        raise
    argv0 = f"/proc/self/fd/{file_fd}" if mode == "descriptor" else path
    return file_fd, argv0


def child_environment():
    env = dict(CHILD_FIXED_ENVIRONMENT)
    for key in ENVIRONMENT_ALLOWLIST:
        value = os.environ.get(key)
        if value is not None:
            env[key] = value
    return env


def terminate_process_tree(process):
    for signal_number, grace in ((signal.SIGTERM, TERMINATE_GRACE_SECONDS), (signal.SIGKILL, None)):
        try:
            os.killpg(process.pid, signal_number)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=grace)
            break
        except subprocess.TimeoutExpired:
            continue
    # The leader is reaped; sweep any remaining members of its process group.
    for _ in range(50):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        time.sleep(0.05)


def run_command(name, executable_fd, argv0, arguments, timeout):
    argv = [argv0, *arguments]
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_environment(),
            start_new_session=True,
            close_fds=True,
            pass_fds=(executable_fd,),
        )
    except OSError as error:
        fail(f"cannot run {name}: {error}")

    outputs = {process.stdout: bytearray(), process.stderr: bytearray()}
    deadline = time.monotonic() + timeout
    description = " ".join([name, *arguments])
    selector = selectors.DefaultSelector()
    for stream in outputs:
        selector.register(stream, selectors.EVENT_READ)
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(f"{description} did not finish within {timeout:.0f}s")
            for key, _ in selector.select(remaining):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffer = outputs[key.fileobj]
                buffer.extend(chunk)
                if len(buffer) > MAX_COMMAND_OUTPUT_BYTES:
                    fail(f"{description} produced more than {MAX_COMMAND_OUTPUT_BYTES} bytes of output")
        remaining = max(deadline - time.monotonic(), 0)
        try:
            returncode = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            fail(f"{description} did not exit within {timeout:.0f}s")
    except BaseException:
        terminate_process_tree(process)
        raise
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()

    stdout = bytes(outputs[process.stdout]).decode(errors="replace")
    stderr = bytes(outputs[process.stderr]).decode(errors="replace")
    return returncode, stdout, stderr


class Commands:
    def __init__(self):
        self.hyprctl = open_trusted_executable("hyprctl")
        self.omarchy = open_trusted_executable("omarchy")

    def run_hyprctl(self, *arguments):
        return run_command("hyprctl", *self.hyprctl, arguments, COMMAND_TIMEOUTS["hyprctl"])

    def run_omarchy(self, *arguments):
        return run_command("omarchy", *self.omarchy, arguments, COMMAND_TIMEOUTS["omarchy"])


# --- descriptor-relative file access ---------------------------------------


def open_directory(path):
    flags = os.O_RDONLY | os.O_DIRECTORY | nofollow_flags()
    try:
        directory_fd = os.open(path, flags)
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            fail(
                "refusing a symlinked Hyprland config directory; point "
                "XDG_CONFIG_HOME at the real config root before running setup"
            )
        fail(f"cannot securely open Hyprland config directory {path}: {error}")
    try:
        require_private_to_user(os.fstat(directory_fd), f"Hyprland config directory {path}")
    except BaseException:
        os.close(directory_fd)
        raise
    return directory_fd


def lock_descriptor(file_fd, description):
    try:
        fcntl.flock(file_fd, fcntl.LOCK_EX)
    except OSError as error:
        fail(f"cannot lock {description}: {error}")


def read_bounded(file_fd, limit, description):
    chunks = []
    total = 0
    while True:
        chunk = os.read(file_fd, min(1024 * 1024, limit + 1 - total))
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > limit:
            fail(f"{description} is larger than {limit} bytes; refusing to process it")
        chunks.append(chunk)


def target_signature(file_stat):
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_mode,
        file_stat.st_uid,
        file_stat.st_gid,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def open_regular(directory_fd, name, limit, description, missing_ok=False):
    try:
        file_fd = os.open(name, os.O_RDONLY | nofollow_flags(), dir_fd=directory_fd)
    except OSError as error:
        if missing_ok and error.errno == errno.ENOENT:
            return None
        if error.errno == errno.ELOOP:
            fail(
                f"refusing symlinked {name}; replace it with a regular "
                "file or configure the loader manually"
            )
        fail(f"cannot securely open {name}: {error}")
    try:
        file_stat_before = os.fstat(file_fd)
        if not stat.S_ISREG(file_stat_before.st_mode):
            fail(f"refusing non-regular {description}: {name}")
        require_private_to_user(file_stat_before, f"{description} {name}")
        if file_stat_before.st_size > limit:
            fail(f"{description} is larger than {limit} bytes; refusing to process it")
        lock_descriptor(file_fd, name)
        contents = read_bounded(file_fd, limit, description)
        file_stat_after = os.fstat(file_fd)
        if target_signature(file_stat_before) != target_signature(file_stat_after):
            fail(f"{name} changed while it was being read")
    except BaseException:
        os.close(file_fd)
        raise
    return file_fd, file_stat_after, contents


def open_target(directory_fd):
    return open_regular(directory_fd, TARGET_NAME, MAX_TARGET_BYTES, "binding file")


def split_lines(contents):
    if contents.count(b"\n") > MAX_TARGET_LINES:
        fail(f"binding file has more than {MAX_TARGET_LINES} lines; refusing to process it")
    return contents.splitlines(keepends=True)


def managed_block_state(contents):
    lines = split_lines(contents)
    begin_lines = [
        index for index, line in enumerate(lines) if line.rstrip(b"\r\n") == BEGIN_MARKER
    ]
    end_lines = [
        index for index, line in enumerate(lines) if line.rstrip(b"\r\n") == END_MARKER
    ]

    if not begin_lines and not end_lines:
        return "absent", lines, None, None
    if len(begin_lines) != 1 or len(end_lines) != 1 or begin_lines[0] >= end_lines[0]:
        fail("expected one complete, correctly ordered managed binding block")

    begin_index = begin_lines[0]
    end_index = end_lines[0]
    block = b"".join(lines[begin_index : end_index + 1])
    if block != MANAGED_BLOCK:
        fail("managed binding block does not match the installed block exactly")
    return "installed", lines, begin_index, end_index


def current_target_matches(directory_fd, expected_stat):
    try:
        current = os.stat(TARGET_NAME, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as error:
        fail(f"cannot revalidate {TARGET_NAME}: {error}")
    if not stat.S_ISREG(current.st_mode):
        fail(f"refusing changed non-regular binding file: {TARGET_NAME}")
    if target_signature(current) != target_signature(expected_stat):
        fail(f"{TARGET_NAME} changed during the transaction; refusing to overwrite it")


def published_target_matches(directory_fd, published_fd):
    """Confirm bindings.lua still names the inode this transaction published."""
    try:
        current = os.stat(TARGET_NAME, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as error:
        fail(f"cannot revalidate {TARGET_NAME}: {error}")
    published = os.fstat(published_fd)
    if target_signature(current)[:7] != target_signature(published)[:7]:
        fail(f"{TARGET_NAME} was replaced by another program after the edit was applied")


def create_unique(directory_fd, prefix, mode):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow_flags()
    for _ in range(100):
        name = f"{prefix}{secrets.token_hex(8)}"
        try:
            return name, os.open(name, flags, mode, dir_fd=directory_fd)
        except FileExistsError:
            continue
        except OSError as error:
            fail(f"cannot create transaction file in Hyprland config directory: {error}")
    fail("cannot allocate a unique transaction file")


def write_durable(file_fd, contents):
    view = memoryview(contents)
    while view:
        written = os.write(file_fd, view)
        if written <= 0:
            fail("short write while creating transaction file")
        view = view[written:]
    os.fsync(file_fd)


def create_backup(directory_fd, contents, mode, action):
    prefix = f"{TARGET_NAME}.bak.workspace-switcher-{action}."
    backup_name, backup_fd = create_unique(directory_fd, prefix, mode)
    try:
        write_durable(backup_fd, contents)
    finally:
        os.close(backup_fd)
    os.fsync(directory_fd)
    return backup_name


def unlink_quietly(directory_fd, name):
    try:
        os.unlink(name, dir_fd=directory_fd)
    except FileNotFoundError:
        pass


_libc = None


def exchange_names(directory_fd, first, second):
    """Atomically swap two directory entries with renameat2(RENAME_EXCHANGE)."""
    global _libc
    if _libc is None:
        try:
            _libc = ctypes.CDLL(None, use_errno=True)
            _libc.renameat2.argtypes = (
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint,
            )
            _libc.renameat2.restype = ctypes.c_int
        except (OSError, AttributeError) as error:
            fail(f"renameat2 is unavailable; cannot perform an atomic exchange: {error}")
    result = _libc.renameat2(
        directory_fd,
        os.fsencode(first),
        directory_fd,
        os.fsencode(second),
        RENAME_EXCHANGE,
    )
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), first)


def replace_target(directory_fd, expected_stat, contents, mode):
    """Replace bindings.lua only if it is still the validated inode.

    The staged file is exchanged with the target atomically. After the
    exchange the previous target inode sits at the staging name, so its
    identity is checked against the expected signature; if another writer
    replaced the target in the meantime the exchange is reverted and the
    transaction fails without discarding their file.
    """
    temp_name, temp_fd = create_unique(directory_fd, TEMP_PREFIX, mode)
    exchanged = False
    try:
        os.fchmod(temp_fd, mode)
        write_durable(temp_fd, contents)
        current_target_matches(directory_fd, expected_stat)
        exchange_names(directory_fd, temp_name, TARGET_NAME)
        exchanged = True
        displaced = os.stat(temp_name, dir_fd=directory_fd, follow_symlinks=False)
        # An exchange updates ctime on both inodes; compare the immutable identity
        # and content-bearing fields instead.
        expected_identity = target_signature(expected_stat)[:7]
        if target_signature(displaced)[:7] != expected_identity:
            exchange_names(directory_fd, temp_name, TARGET_NAME)
            exchanged = False
            fail(f"{TARGET_NAME} was replaced concurrently; the concurrent edit was kept")
        os.fsync(directory_fd)
        unlink_quietly(directory_fd, temp_name)
        os.fsync(directory_fd)
        return temp_fd, os.fstat(temp_fd)
    except BaseException:
        os.close(temp_fd)
        if not exchanged:
            unlink_quietly(directory_fd, temp_name)
        raise


# --- transaction marker and recovery ---------------------------------------


def digest(contents):
    return hashlib.sha256(contents).hexdigest()


def write_marker(directory_fd, record):
    payload = json.dumps(record, sort_keys=True).encode()
    temp_name, temp_fd = create_unique(directory_fd, MARKER_NAME + ".", 0o600)
    try:
        write_durable(temp_fd, payload)
    finally:
        os.close(temp_fd)
    try:
        os.replace(temp_name, MARKER_NAME, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    except BaseException:
        unlink_quietly(directory_fd, temp_name)
        raise
    os.fsync(directory_fd)


def advance_phase(directory_fd, record, phase):
    record["phase"] = phase
    write_marker(directory_fd, record)


def clear_marker(directory_fd):
    unlink_quietly(directory_fd, MARKER_NAME)
    os.fsync(directory_fd)


def read_marker(directory_fd):
    opened = open_regular(
        directory_fd, MARKER_NAME, MAX_MARKER_BYTES, "transaction marker", missing_ok=True
    )
    if opened is None:
        return None
    marker_fd, _, payload = opened
    os.close(marker_fd)
    try:
        record = json.loads(payload)
    except json.JSONDecodeError as error:
        fail(f"transaction marker {MARKER_NAME} is unreadable ({error}); resolve it manually")
    required = {
        "action", "backup", "original_sha256", "new_sha256", "mode", "previously_enabled", "phase",
    }
    if not isinstance(record, dict) or not required <= set(record):
        fail(f"transaction marker {MARKER_NAME} is incomplete; resolve it manually")
    if os.sep in str(record["backup"]) or not str(record["backup"]).startswith(TARGET_NAME + ".bak."):
        fail(f"transaction marker {MARKER_NAME} names an unexpected backup; resolve it manually")
    if record["phase"] not in PHASES:
        fail(f"transaction marker {MARKER_NAME} records an unknown phase; resolve it manually")
    return record


# Durable phases. "staged": backup and marker exist, target untouched.
# "replaced": exchange done. "validated": Hyprland accepted the change.
# "enabling": the enable call is about to be issued, so the plugin may or may
# not have been enabled by it. "enabled": the call returned successfully.
# Recovery uses these to describe plugin state, never to undo it.
PHASES = ("staged", "replaced", "validated", "enabling", "enabled")


def plugin_state_notice(record, commands):
    """Describe, without changing, the plugin state after an interrupted run.

    A crash cannot establish who last changed an external state, so recovery
    never disables the plugin: between writing the "enabling" phase and the
    enable call returning, the change may have come from this transaction or
    from the user. Recovery restores the file it owns and reports the rest.
    """
    if record["action"] != "install" or record["previously_enabled"] is not False:
        return None
    if record["phase"] not in ("enabling", "enabled"):
        return None
    try:
        currently_enabled = plugin_is_enabled(commands)
    except TransactionError:
        currently_enabled = None
    if currently_enabled is False:
        return None
    state = "is enabled" if currently_enabled else "may be enabled"
    return (
        f"workspace-switcher binding transaction: the interrupted setup was disabled "
        f"beforehand and {state} now; plugin state was left unchanged. Run "
        f"'omarchy plugin disable {PLUGIN_ID}' if you did not want it enabled."
    )


def recover(directory_fd, hyprland_directory, commands):
    """Finish or undo a transaction that died before it was committed.

    Only the binding file is rolled back, and only when it still carries the
    staged content. Plugin state is reported, never inferred and undone.
    """
    record = read_marker(directory_fd)
    if record is None:
        return
    backup_path = os.path.join(hyprland_directory, record["backup"])
    target_fd, target_stat, contents = open_target(directory_fd)
    try:
        current_sha = digest(contents)
        if current_sha == record["original_sha256"]:
            pass
        elif current_sha == record["new_sha256"]:
            backup_fd, _, backup_contents = open_regular(
                directory_fd, record["backup"], MAX_TARGET_BYTES, "transaction backup"
            )
            os.close(backup_fd)
            if digest(backup_contents) != record["original_sha256"]:
                fail(
                    f"interrupted transaction found, but backup {record['backup']} does not "
                    f"match the recorded original; resolve {MARKER_NAME} manually"
                )
            restored_fd, _ = replace_target(
                directory_fd, target_stat, backup_contents, int(record["mode"])
            )
            os.close(restored_fd)
            validate_hyprland(commands)
        else:
            fail(
                f"interrupted transaction found, but {TARGET_NAME} matches neither the original "
                f"nor the staged content; backup: {backup_path}; remove {MARKER_NAME} after "
                "resolving it manually"
            )
        notice = plugin_state_notice(record, commands)
    finally:
        os.close(target_fd)
    clear_marker(directory_fd)
    print(f"recovered\t{backup_path}", file=sys.stderr)
    if notice:
        print(notice, file=sys.stderr)


# --- Hyprland and plugin state ---------------------------------------------


def validate_hyprland(commands):
    returncode, _, _ = commands.run_hyprctl("reload")
    if returncode != 0:
        fail("Hyprland reload failed")

    returncode, stdout, stderr = commands.run_hyprctl("configerrors")
    if returncode != 0:
        fail("could not validate Hyprland configuration")
    if stdout.strip() or stderr.strip():
        detail = (stdout + stderr).strip()
        fail(f"Hyprland rejected the change: {detail}")


def plugin_is_enabled(commands):
    returncode, stdout, _ = commands.run_omarchy("plugin", "list", "--json")
    if returncode != 0:
        fail("could not read the plugin's enabled state")
    try:
        plugins = json.loads(stdout)
    except json.JSONDecodeError as error:
        fail(f"could not parse the plugin's enabled state: {error}")
    if not isinstance(plugins, list):
        fail("could not parse the plugin's enabled state: expected a list")
    for plugin in plugins:
        if isinstance(plugin, dict) and plugin.get("id") == PLUGIN_ID:
            return plugin.get("enabled") is True
    fail(f"plugin {PLUGIN_ID} is not known; rescan plugins and try again")


def enable_plugin(commands, previously_enabled):
    if previously_enabled:
        return
    returncode, stdout, stderr = commands.run_omarchy("plugin", "enable", PLUGIN_ID)
    if returncode == 0:
        return
    detail = (stdout + stderr).strip()
    suffix = f": {detail}" if detail else ""
    fail(f"could not enable the plugin{suffix}")


def restore_disabled_plugin_state(commands):
    returncode, _, _ = commands.run_omarchy("plugin", "disable", PLUGIN_ID)
    if returncode != 0:
        fail("could not restore the plugin's previous disabled state")


def restored_contents(directory_fd, current_stat, original_contents, original_mode, commands):
    restored_fd, restored_stat = replace_target(
        directory_fd, current_stat, original_contents, original_mode
    )
    os.close(restored_fd)
    try:
        validate_hyprland(commands)
    except TransactionError as error:
        fail(f"binding file was restored, but Hyprland reload failed: {error}")
    return restored_stat


def edited_contents(action, original_contents, lines, begin_index, end_index):
    if action == "install":
        separator = b"\n" if original_contents.endswith(b"\n") else b"\n\n"
        return original_contents + separator + MANAGED_BLOCK
    # Drop the single blank separator that install adds before the block.
    if begin_index > 0 and lines[begin_index - 1].strip() == b"":
        begin_index -= 1
    return b"".join(lines[:begin_index] + lines[end_index + 1 :])


# --- entry points -----------------------------------------------------------


class ScanBudget:
    """Every limit the manual-setup scan is allowed to spend."""

    def __init__(self):
        self.entries = 0
        self.files = 0
        self.total_bytes = 0
        self.deadline = time.monotonic() + SCAN_MAX_SECONDS
        self.truncated = False

    def exhausted(self):
        if (
            self.entries >= SCAN_MAX_ENTRIES
            or self.files >= SCAN_MAX_FILES
            or self.total_bytes >= SCAN_MAX_TOTAL_BYTES
            or time.monotonic() > self.deadline
        ):
            self.truncated = True
            return True
        return False

    def remaining_bytes(self):
        return min(SCAN_MAX_FILE_BYTES, SCAN_MAX_TOTAL_BYTES - self.total_bytes)


def scan_lua_file(parent_fd, name, relative, budget, matches):
    try:
        file_fd = os.open(name, os.O_RDONLY | nofollow_flags(), dir_fd=parent_fd)
    except OSError:
        return
    try:
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode):
            return
        budget.files += 1
        limit = budget.remaining_bytes()
        if info.st_size > limit:
            # Too large to inspect within the remaining budget; report it as a
            # file that was not cleared rather than silently skipping it.
            budget.truncated = True
            return
        contents = read_bounded(file_fd, limit, relative)
        budget.total_bytes += len(contents)
        if PLUGIN_ID.encode() in contents:
            if len(matches) >= SCAN_MAX_MATCHES:
                budget.truncated = True
                return
            matches.append(relative)
    except (OSError, TransactionError):
        return
    finally:
        os.close(file_fd)


def scan_directory(parent_fd, prefix, depth, budget, matches):
    """Walk one directory. Child descriptors are closed as each subtree ends,
    so at most SCAN_MAX_DEPTH + 1 descriptors are open at any moment, and the
    entries are consumed lazily instead of being materialized as a list."""
    try:
        entries = os.scandir(parent_fd)
    except OSError:
        return
    with entries:
        for entry in entries:
            if budget.exhausted():
                return
            budget.entries += 1
            try:
                if entry.is_symlink():
                    continue
                is_directory = entry.is_dir(follow_symlinks=False)
                is_file = entry.is_file(follow_symlinks=False)
            except OSError:
                continue
            relative = prefix + entry.name
            if is_directory:
                if depth + 1 > SCAN_MAX_DEPTH:
                    budget.truncated = True
                    continue
                try:
                    child_fd = os.open(
                        entry.name,
                        os.O_RDONLY | os.O_DIRECTORY | nofollow_flags(),
                        dir_fd=parent_fd,
                    )
                except OSError:
                    continue
                try:
                    scan_directory(child_fd, relative + "/", depth + 1, budget, matches)
                finally:
                    os.close(child_fd)
                continue
            if is_file and entry.name.endswith(".lua"):
                scan_lua_file(parent_fd, entry.name, relative, budget, matches)


def scan_manual_setup(directory_fd):
    """Bounded, no-follow search of the config tree for an older manual setup."""
    matches = []
    budget = ScanBudget()
    scan_directory(directory_fd, "", 0, budget, matches)
    return sorted(matches), budget.truncated


def super_tab_lines(lines):
    found = []
    for number, line in enumerate(lines, start=1):
        if SUPER_TAB_PATTERN.search(line):
            text = line.rstrip(b"\r\n").decode(errors="replace")
            found.append(f"{number}: {text[:200]}")
            if len(found) >= SCAN_MAX_MATCHES:
                break
    return found


def inspect(hyprland_directory):
    commands = Commands()
    directory_fd = open_directory(hyprland_directory)
    target_fd = None
    try:
        lock_descriptor(directory_fd, "Hyprland config directory")
        recover(directory_fd, hyprland_directory, commands)
        target_fd, _, contents = open_target(directory_fd)
        state, lines, _, _ = managed_block_state(contents)
        manual, truncated = scan_manual_setup(directory_fd)
        report = {
            "state": state,
            "manual_setup": manual,
            "manual_setup_truncated": truncated,
            "super_tab_lines": super_tab_lines(lines) if state == "absent" else [],
        }
        print(json.dumps(report))
    finally:
        if target_fd is not None:
            os.close(target_fd)
        os.close(directory_fd)


def check(hyprland_directory):
    commands = Commands()
    directory_fd = open_directory(hyprland_directory)
    target_fd = None
    try:
        lock_descriptor(directory_fd, "Hyprland config directory")
        recover(directory_fd, hyprland_directory, commands)
        target_fd, _, contents = open_target(directory_fd)
        state, _, _, _ = managed_block_state(contents)
        print(state)
    finally:
        if target_fd is not None:
            os.close(target_fd)
        os.close(directory_fd)


def transact(action, hyprland_directory):
    commands = Commands()
    directory_fd = open_directory(hyprland_directory)
    target_fd = None
    replacement_fd = None
    enable_attempted = False
    try:
        lock_descriptor(directory_fd, "Hyprland config directory")
        recover(directory_fd, hyprland_directory, commands)
        target_fd, original_stat, original_contents = open_target(directory_fd)
        state, lines, begin_index, end_index = managed_block_state(original_contents)
        previously_enabled = plugin_is_enabled(commands) if action == "install" else None

        if action == "install" and state == "installed":
            if not previously_enabled:
                try:
                    enable_plugin(commands, previously_enabled)
                except BaseException as enable_error:
                    try:
                        restore_disabled_plugin_state(commands)
                    except BaseException as state_error:
                        fail(
                            f"{enable_error}; plugin state rollback also failed: "
                            f"{state_error}"
                        )
                    raise
            print("already-installed")
            return
        if action == "remove" and state == "absent":
            print("already-removed")
            return

        new_contents = edited_contents(
            action, original_contents, lines, begin_index, end_index
        )
        original_mode = stat.S_IMODE(original_stat.st_mode)
        backup_name = create_backup(
            directory_fd, original_contents, original_mode, action
        )
        record = {
            "action": action,
            "backup": backup_name,
            "original_sha256": digest(original_contents),
            "new_sha256": digest(new_contents),
            "mode": original_mode,
            "previously_enabled": previously_enabled,
            "phase": "staged",
        }
        write_marker(directory_fd, record)
        try:
            replacement_fd, replacement_stat = replace_target(
                directory_fd, original_stat, new_contents, original_mode
            )
        except BaseException:
            # A refused or failed exchange never applied the edit; nothing to recover.
            clear_marker(directory_fd)
            raise
        advance_phase(directory_fd, record, "replaced")

        foreign_replacement = False
        try:
            published_target_matches(directory_fd, replacement_fd)
            validate_hyprland(commands)
            published_target_matches(directory_fd, replacement_fd)
            advance_phase(directory_fd, record, "validated")
            if action == "install":
                enable_attempted = not previously_enabled
                if enable_attempted:
                    advance_phase(directory_fd, record, "enabling")
                enable_plugin(commands, previously_enabled)
                if enable_attempted:
                    advance_phase(directory_fd, record, "enabled")
            published_target_matches(directory_fd, replacement_fd)
        except BaseException as error:
            plugin_rollback_error = None
            if enable_attempted:
                try:
                    restore_disabled_plugin_state(commands)
                except BaseException as state_error:
                    plugin_rollback_error = state_error
            try:
                published_target_matches(directory_fd, replacement_fd)
            except TransactionError:
                foreign_replacement = True
            if foreign_replacement:
                # Another program owns bindings.lua now; leave its file alone.
                clear_marker(directory_fd)
                fail(
                    f"{error}; the switcher block may be missing from the replaced file; "
                    f"durable backup of the original: {os.path.join(hyprland_directory, backup_name)}"
                )
            try:
                restored_contents(
                    directory_fd,
                    replacement_stat,
                    original_contents,
                    original_mode,
                    commands,
                )
            except BaseException as rollback_error:
                fail(
                    f"{error}; automatic rollback also failed: {rollback_error}; "
                    f"durable backup: {os.path.join(hyprland_directory, backup_name)}; "
                    f"the next run will retry recovery from {MARKER_NAME}"
                )
            if plugin_rollback_error is not None:
                fail(
                    f"{error}; restored {TARGET_NAME}, but plugin state rollback failed: "
                    f"{plugin_rollback_error}"
                )
            clear_marker(directory_fd)
            fail(f"{error}; restored {TARGET_NAME} from the transaction copy")

        clear_marker(directory_fd)
        print(f"changed\t{os.path.join(hyprland_directory, backup_name)}")
    finally:
        if replacement_fd is not None:
            os.close(replacement_fd)
        if target_fd is not None:
            os.close(target_fd)
        os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "inspect", "install", "remove"))
    parser.add_argument("hyprland_directory")
    args = parser.parse_args()

    def interrupted(signum, _frame):
        raise TransactionError(f"interrupted by signal {signum}")

    for signal_name in ("SIGINT", "SIGTERM", "SIGHUP"):
        if hasattr(signal, signal_name):
            signal.signal(getattr(signal, signal_name), interrupted)

    if args.action == "check":
        check(args.hyprland_directory)
    elif args.action == "inspect":
        inspect(args.hyprland_directory)
    else:
        transact(args.action, args.hyprland_directory)


if __name__ == "__main__":
    try:
        main()
    except TransactionError as error:
        print(f"workspace-switcher binding transaction: {error}", file=sys.stderr)
        sys.exit(1)
    except OSError as error:
        print(f"workspace-switcher binding transaction: system error: {error}", file=sys.stderr)
        sys.exit(1)
