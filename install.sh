#!/usr/bin/env bash
set -euo pipefail

plugin_id="reomarchy.workspace-switcher"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
hypr_dir="$config_home/hypr"
bindings_file="$hypr_dir/bindings.lua"
transaction_helper="$script_dir/binding_transaction.py"
assume_yes=0

fail() {
  printf 'workspace-switcher setup: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  (( assume_yes )) && return 0
  [[ -t 0 && -t 1 ]] || fail "confirmation required; rerun with --yes"
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
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

[[ -f $script_dir/manifest.json ]] || fail "manifest.json is missing beside this script"
[[ -x $transaction_helper ]] || fail "binding transaction helper is missing or not executable"
[[ $(jq -r '.id // empty' "$script_dir/manifest.json") == "$plugin_id" ]] ||
  fail "this script is not inside the $plugin_id plugin"
[[ -d $hypr_dir ]] || fail "Hyprland config directory not found: $hypr_dir"
binding_state=$(
  "$transaction_helper" check "$hypr_dir"
) || fail "could not validate the existing binding block"
if [[ $binding_state == installed ]]; then
  "$transaction_helper" install "$hypr_dir" >/dev/null || fail "could not enable the existing installation"
  printf 'Workspace Switcher bindings are already installed in %s.\n' "$bindings_file"
  exit 0
fi

existing_files=$(grep -RFl --include='*.lua' -- "$plugin_id" "$hypr_dir" 2>/dev/null || true)
if [[ -n $existing_files ]]; then
  printf 'An existing manual Workspace Switcher setup was found:\n%s\n' "$existing_files" >&2
  fail "remove the old binding block before running this installer"
fi

if grep -Eiq -- 'SUPER[[:space:]]*\+[[:space:]]*(SHIFT[[:space:]]*\+[[:space:]]*)?TAB' "$bindings_file"; then
  printf 'Existing Super+Tab lines in %s:\n' "$bindings_file" >&2
  grep -Ein -- 'SUPER[[:space:]]*\+[[:space:]]*(SHIFT[[:space:]]*\+[[:space:]]*)?TAB' "$bindings_file" >&2 || true
  confirm "Replace these bindings with Workspace Switcher?" || fail "cancelled"
fi

printf '%s\n' \
  'Workspace Switcher replaces vanilla Super+Tab/Shift+Tab workspace cycling.' \
  "It will add a marked loader block to $bindings_file and keep a backup."
confirm "Install the Workspace Switcher bindings?" || fail "cancelled"

transaction_result=$(
  "$transaction_helper" install "$hypr_dir"
) || fail "binding transaction failed"
IFS=$'\t' read -r transaction_status backup <<< "$transaction_result"
[[ $transaction_status == changed && -n ${backup:-} ]] || fail "unexpected binding transaction result"

printf 'Workspace Switcher bindings installed. Backup: %s\n' "$backup"
printf 'Press Super+Tab to use the switcher.\n'
