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
unset CDPATH
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
keep_plugin=0

# Fixed tool locations; nothing is resolved through PATH.
env_bin=/usr/bin/env
python_bin=/usr/bin/python3
omarchy_bin=/usr/bin/omarchy

fail() {
  printf 'workspace-switcher removal: %s\n' "$*" >&2
  exit 1
}

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

while (( $# > 0 )); do
  case "$1" in
    --yes | -y) assume_yes=1 ;;
    --keep-plugin) keep_plugin=1 ;;
    -h | --help)
      printf 'Usage: %s [--yes] [--keep-plugin]\n' "$0"
      exit 0
      ;;
    *) fail "unknown option '$1'" ;;
  esac
  shift
done

for tool in "$env_bin" "$python_bin"; do
  [[ -f $tool && -x $tool ]] || fail "required system tool is missing: $tool"
done
[[ -f $transaction_helper ]] || fail "binding transaction helper is missing"

if [[ -e $bindings_file || -L $bindings_file ]]; then
  transaction_result=$(run_helper remove "$hypr_dir") || fail "binding transaction failed"
  IFS=$'\t' read -r transaction_status backup <<< "$transaction_result"

  if [[ $transaction_status == changed && -n ${backup:-} ]]; then
    printf 'Removed Workspace Switcher bindings. Backup: %s\n' "$backup"
  elif [[ $transaction_status == already-removed ]]; then
    printf 'No managed Workspace Switcher binding block found in %s.\n' "$bindings_file"
  else
    fail "unexpected binding transaction result"
  fi
fi

if (( ! keep_plugin )); then
  [[ -f $omarchy_bin && -x $omarchy_bin ]] || fail "required system tool is missing: $omarchy_bin"
  remove_args=(plugin remove "$plugin_id")
  (( assume_yes )) && remove_args+=(--yes)
  run_clean "$omarchy_bin" "${remove_args[@]}"
fi
