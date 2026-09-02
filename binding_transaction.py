#!/usr/bin/env python3
"""Safely install or remove the Workspace Switcher Hyprland loader block."""

import argparse
import fcntl
import json
import os
import secrets
import signal
import stat
import subprocess
import sys


PLUGIN_ID = "reomarchy.workspace-switcher"
TARGET_NAME = "bindings.lua"
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


class TransactionError(Exception):
    pass


def fail(message):
    raise TransactionError(message)


def nofollow_flags():
    return getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)


def open_directory(path):
    flags = os.O_RDONLY | os.O_DIRECTORY | nofollow_flags()
    try:
        return os.open(path, flags)
    except OSError as error:
        fail(f"cannot securely open Hyprland config directory {path}: {error}")


def lock_descriptor(file_fd, description):
    try:
        fcntl.flock(file_fd, fcntl.LOCK_EX)
    except OSError as error:
        fail(f"cannot lock {description}: {error}")


def read_all(file_fd):
    chunks = []
    while True:
        chunk = os.read(file_fd, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
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


def open_target(directory_fd):
    try:
        file_fd = os.open(
            TARGET_NAME, os.O_RDONLY | nofollow_flags(), dir_fd=directory_fd
        )
    except OSError as error:
        fail(f"cannot securely open {TARGET_NAME}: {error}")

    file_stat_before = os.fstat(file_fd)
    if not stat.S_ISREG(file_stat_before.st_mode):
        os.close(file_fd)
        fail(f"refusing non-regular binding file: {TARGET_NAME}")
    lock_descriptor(file_fd, TARGET_NAME)
    contents = read_all(file_fd)
    file_stat_after = os.fstat(file_fd)
    if target_signature(file_stat_before) != target_signature(file_stat_after):
        os.close(file_fd)
        fail(f"{TARGET_NAME} changed while it was being read")
    return file_fd, file_stat_after, contents


def managed_block_state(contents):
    lines = contents.splitlines(keepends=True)
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


def replace_target(directory_fd, expected_stat, contents, mode):
    temp_name, temp_fd = create_unique(
        directory_fd, ".workspace-switcher-bindings.", mode
    )
    renamed = False
    try:
        os.fchmod(temp_fd, mode)
        write_durable(temp_fd, contents)
        current_target_matches(directory_fd, expected_stat)
        os.replace(
            temp_name,
            TARGET_NAME,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        renamed = True
        return temp_fd, os.fstat(temp_fd)
    except BaseException:
        os.close(temp_fd)
        if not renamed:
            try:
                os.unlink(temp_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        raise


def validate_hyprland():
    reload_result = subprocess.run(
        ["hyprctl", "reload"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
    )
    if reload_result.returncode != 0:
        fail("Hyprland reload failed")

    errors = subprocess.run(
        ["hyprctl", "configerrors"], capture_output=True, text=True
    )
    if errors.returncode != 0:
        fail("could not validate Hyprland configuration")
    if errors.stdout.strip() or errors.stderr.strip():
        detail = (errors.stdout + errors.stderr).strip()
        fail(f"Hyprland rejected the change: {detail}")


def plugin_is_enabled():
    result = subprocess.run(
        ["omarchy", "plugin", "list", "--json"], capture_output=True, text=True
    )
    if result.returncode != 0:
        fail("could not read the plugin's enabled state")
    try:
        plugins = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"could not parse the plugin's enabled state: {error}")
    for plugin in plugins:
        if plugin.get("id") == PLUGIN_ID:
            return plugin.get("enabled") is True
    fail(f"plugin {PLUGIN_ID} is not known; rescan plugins and try again")


def enable_plugin(previously_enabled):
    if previously_enabled:
        return
    result = subprocess.run(
        ["omarchy", "plugin", "enable", PLUGIN_ID], capture_output=True, text=True
    )
    if result.returncode == 0:
        return
    detail = (result.stdout + result.stderr).strip()
    suffix = f": {detail}" if detail else ""
    fail(f"could not enable the plugin{suffix}")


def restore_disabled_plugin_state():
    result = subprocess.run(
        ["omarchy", "plugin", "disable", PLUGIN_ID],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        fail("could not restore the plugin's previous disabled state")


def restored_contents(directory_fd, current_stat, original_contents, original_mode):
    restored_fd, restored_stat = replace_target(
        directory_fd, current_stat, original_contents, original_mode
    )
    os.close(restored_fd)
    os.fsync(directory_fd)
    try:
        validate_hyprland()
    except TransactionError as error:
        fail(f"binding file was restored, but Hyprland reload failed: {error}")
    return restored_stat


def edited_contents(action, original_contents, lines, begin_index, end_index):
    if action == "install":
        separator = b"\n" if original_contents.endswith(b"\n") else b"\n\n"
        return original_contents + separator + MANAGED_BLOCK
    return b"".join(lines[:begin_index] + lines[end_index + 1 :])


def check(hyprland_directory):
    directory_fd = open_directory(hyprland_directory)
    target_fd = None
    try:
        lock_descriptor(directory_fd, "Hyprland config directory")
        target_fd, _, contents = open_target(directory_fd)
        state, _, _, _ = managed_block_state(contents)
        print(state)
    finally:
        if target_fd is not None:
            os.close(target_fd)
        os.close(directory_fd)


def transact(action, hyprland_directory):
    directory_fd = open_directory(hyprland_directory)
    target_fd = None
    replacement_fd = None
    enable_attempted = False
    try:
        lock_descriptor(directory_fd, "Hyprland config directory")
        target_fd, original_stat, original_contents = open_target(directory_fd)
        state, lines, begin_index, end_index = managed_block_state(original_contents)
        previously_enabled = plugin_is_enabled() if action == "install" else None

        if action == "install" and state == "installed":
            if not previously_enabled:
                try:
                    enable_plugin(previously_enabled)
                except BaseException:
                    restore_disabled_plugin_state()
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
        replacement_fd, replacement_stat = replace_target(
            directory_fd, original_stat, new_contents, original_mode
        )

        try:
            os.fsync(directory_fd)
            validate_hyprland()
            if action == "install":
                enable_attempted = not previously_enabled
                enable_plugin(previously_enabled)
        except BaseException as error:
            plugin_rollback_error = None
            if enable_attempted:
                try:
                    restore_disabled_plugin_state()
                except BaseException as state_error:
                    plugin_rollback_error = state_error
            try:
                restored_contents(
                    directory_fd,
                    replacement_stat,
                    original_contents,
                    original_mode,
                )
            except BaseException as rollback_error:
                fail(
                    f"{error}; automatic rollback also failed: {rollback_error}; "
                    f"durable backup: {os.path.join(hyprland_directory, backup_name)}"
                )
            if plugin_rollback_error is not None:
                fail(
                    f"{error}; restored {TARGET_NAME}, but plugin state rollback failed: "
                    f"{plugin_rollback_error}"
                )
            fail(f"{error}; restored {TARGET_NAME} from the transaction copy")

        print(f"changed\t{os.path.join(hyprland_directory, backup_name)}")
    finally:
        if replacement_fd is not None:
            os.close(replacement_fd)
        if target_fd is not None:
            os.close(target_fd)
        os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "install", "remove"))
    parser.add_argument("hyprland_directory")
    args = parser.parse_args()

    def interrupted(signum, _frame):
        raise TransactionError(f"interrupted by signal {signum}")

    for signal_name in ("SIGINT", "SIGTERM", "SIGHUP"):
        if hasattr(signal, signal_name):
            signal.signal(getattr(signal, signal_name), interrupted)

    if args.action == "check":
        check(args.hyprland_directory)
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
