#!/bin/bash -p
# -p makes bash ignore BASH_ENV, ENV, SHELLOPTS and inherited shell functions.
# PATH, CDPATH and IFS are replaced before anything is looked up, and this
# script runs no external command until it has done so, so nothing here is
# resolved through a caller-controlled search path.
#
# Scope: the dynamic loader acts before the first line of this script, so
# LD_PRELOAD and friends cannot be neutralized from inside the process they
# affect. Anyone who can set them in your environment can already run code as
# you; see the README.
PATH=/usr/bin:/bin
# Dropping the loader variables here cannot unmap what is already loaded into
# this shell, but it does keep them out of every process the script starts,
# including /usr/bin/env itself, whose own environment `env -i` cannot change.
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_ORIGIN_PATH LD_DEBUG LD_DEBUG_OUTPUT
unset CDPATH BASH_ENV ENV
IFS=$' \t\n'
set -euo pipefail

plugin_id="reomarchy.workspace-switcher"
# cd and pwd are builtins; dirname is not, so the directory is derived with
# parameter expansion instead of an external command.
case "${BASH_SOURCE[0]}" in
  */*) script_dir_raw="${BASH_SOURCE[0]%/*}" ;;
  *) script_dir_raw="." ;;
esac
script_dir=$(cd -- "$script_dir_raw" && pwd -P)
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
hypr_dir="$config_home/hypr"
bindings_file="$hypr_dir/bindings.lua"
transaction_helper="$script_dir/binding_transaction.py"
assume_yes=0

# Fixed tool locations; nothing is resolved through PATH.
env_bin=/usr/bin/env
jq_bin=/usr/bin/jq
gum_bin=/usr/bin/gum
python_bin=/usr/bin/python3

fail() {
  printf 'workspace-switcher setup: %s\n' "$*" >&2
  exit 1
}

# Children run with an explicit allowlisted environment only.
clean_env=(PATH=/usr/bin:/bin OMARCHY_PATH=/usr/share/omarchy)
for name in HOME USER LOGNAME LANG LC_ALL TERM XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME \
  XDG_STATE_HOME XDG_RUNTIME_DIR XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY \
  DBUS_SESSION_BUS_ADDRESS; do
  [[ -n ${!name:-} ]] && clean_env+=("$name=${!name}")
done

run_clean() {
  "$env_bin" -i "${clean_env[@]}" "$@"
}

run_helper() {
  run_clean "$python_bin" -I "$transaction_helper" "$@"
}

confirm() {
  local prompt="$1"
  (( assume_yes )) && return 0
  [[ -t 0 && -t 1 ]] || fail "confirmation required; rerun with --yes"
  if [[ -x $gum_bin ]]; then
    run_clean "$gum_bin" confirm "$prompt"
    return
  fi
  local answer
  read -r -p "$prompt [y/N] " answer
  [[ $answer == [Yy] || $answer == [Yy][Ee][Ss] ]]
}

while (( $# > 0 )); do
  case "$1" in
    --yes | -y) assume_yes=1 ;;
    -h | --help)
      printf 'Usage: %s [--yes]\n' "$0"
      exit 0
      ;;
    *) fail "unknown option '$1'" ;;
  esac
  shift
done

for tool in "$env_bin" "$jq_bin" "$python_bin"; do
  [[ -f $tool && -x $tool ]] || fail "required system tool is missing: $tool"
done
[[ -f $script_dir/manifest.json ]] || fail "manifest.json is missing beside this script"
[[ -f $transaction_helper ]] || fail "binding transaction helper is missing"
[[ $(run_clean "$jq_bin" -r '.id // empty' "$script_dir/manifest.json") == "$plugin_id" ]] ||
  fail "this script is not inside the $plugin_id plugin"
[[ -d $hypr_dir ]] || fail "Hyprland config directory not found: $hypr_dir"

report=$(run_helper inspect "$hypr_dir") || fail "could not inspect the existing Hyprland configuration"
binding_state=$(run_clean "$jq_bin" -r '.state' <<< "$report")
if [[ $binding_state == installed ]]; then
  run_helper install "$hypr_dir" >/dev/null || fail "could not enable the existing installation"
  printf 'Workspace Switcher bindings are already installed in %s.\n' "$bindings_file"
  exit 0
fi
[[ $binding_state == absent ]] || fail "unexpected binding state '$binding_state'"

manual_files=$(run_clean "$jq_bin" -r '.manual_setup[]' <<< "$report")
scan_truncated=$(run_clean "$jq_bin" -r '.manual_setup_truncated' <<< "$report")
if [[ -n $manual_files ]]; then
  printf 'An existing manual Workspace Switcher setup was found under %s:\n%s\n' "$hypr_dir" "$manual_files" >&2
  [[ $scan_truncated == true ]] && printf '(scan was capped; more files may match)\n' >&2
  fail "remove the old binding block before running this installer"
fi
if [[ $scan_truncated == true ]]; then
  # An incomplete scan cannot show that no manual setup exists, and installing
  # anyway would add a second set of bindings beside an existing one.
  scan_limit=$(run_clean "$jq_bin" -r '.manual_setup_limit // "its limits"' <<< "$report")
  fail "the scan of $hypr_dir stopped because it found $scan_limit, so an existing manual setup cannot be ruled out; simplify the tree under $hypr_dir or configure the loader manually"
fi

super_tab=$(run_clean "$jq_bin" -r '.super_tab_lines[]' <<< "$report")
if [[ -n $super_tab ]]; then
  printf 'Existing Super+Tab lines in %s:\n%s\n' "$bindings_file" "$super_tab" >&2
  confirm "Replace these bindings with Workspace Switcher?" || fail "cancelled"
fi

printf '%s\n' \
  'Workspace Switcher replaces vanilla Super+Tab/Shift+Tab workspace cycling.' \
  "It will add a marked loader block to $bindings_file and keep a backup."
confirm "Install the Workspace Switcher bindings?" || fail "cancelled"

transaction_result=$(run_helper install "$hypr_dir") || fail "binding transaction failed"
IFS=$'\t' read -r transaction_status backup <<< "$transaction_result"
[[ $transaction_status == changed && -n ${backup:-} ]] || fail "unexpected binding transaction result"

printf 'Workspace Switcher bindings installed. Backup: %s\n' "$backup"
printf 'Press Super+Tab to use the switcher.\n'
