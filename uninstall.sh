#!/usr/bin/env bash
set -euo pipefail

plugin_id="reomarchy.workspace-switcher"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
hypr_dir="$config_home/hypr"
bindings_file="$hypr_dir/bindings.lua"
transaction_helper="$script_dir/binding_transaction.py"
assume_yes=0
keep_plugin=0

fail() {
  printf 'workspace-switcher removal: %s\n' "$*" >&2
  exit 1
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

[[ -x $transaction_helper ]] || fail "binding transaction helper is missing or not executable"

if [[ -f $bindings_file ]]; then
  transaction_result=$(
    "$transaction_helper" remove "$hypr_dir"
  ) || fail "binding transaction failed"
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
  remove_args=(plugin remove "$plugin_id")
  (( assume_yes )) && remove_args+=(--yes)
  omarchy "${remove_args[@]}"
fi
