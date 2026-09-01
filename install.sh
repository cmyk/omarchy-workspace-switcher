#!/usr/bin/env bash
set -euo pipefail

plugin_id="reomarchy.workspace-switcher"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
hypr_dir="$config_home/hypr"
bindings_file="$hypr_dir/bindings.lua"
begin_marker="-- Workspace Switcher: begin"
end_marker="-- Workspace Switcher: end"
assume_yes=0
temp_file=""

cleanup() {
  if [[ -n $temp_file && -f $temp_file ]]; then rm -f -- "$temp_file"; fi
}
trap cleanup EXIT

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
[[ $(jq -r '.id // empty' "$script_dir/manifest.json") == "$plugin_id" ]] ||
  fail "this script is not inside the $plugin_id plugin"
[[ -d $hypr_dir ]] || fail "Hyprland config directory not found: $hypr_dir"
[[ -f $bindings_file ]] || fail "Hyprland bindings file not found: $bindings_file"
[[ ! -L $bindings_file ]] || fail "refusing to replace symlinked bindings file: $bindings_file"

if grep -Fq -- "$begin_marker" "$bindings_file"; then
  printf 'Workspace Switcher bindings are already installed in %s.\n' "$bindings_file"
  omarchy plugin enable "$plugin_id"
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

omarchy plugin enable "$plugin_id"

backup=$(mktemp "${bindings_file}.bak.workspace-switcher.XXXXXXXX")
cp -p -- "$bindings_file" "$backup"

temp_file=$(mktemp "$hypr_dir/.workspace-switcher-bindings.XXXXXX")
cp -- "$bindings_file" "$temp_file"
cat >> "$temp_file" <<'LUA'

-- Workspace Switcher: begin
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
LUA
chmod --reference="$bindings_file" "$temp_file"
mv -- "$temp_file" "$bindings_file"
temp_file=""

if ! hyprctl reload >/dev/null; then
  cp -p -- "$backup" "$bindings_file"
  hyprctl reload >/dev/null || true
  fail "Hyprland reload failed; restored $bindings_file from $backup"
fi
if ! config_errors=$(hyprctl configerrors 2>&1); then
  cp -p -- "$backup" "$bindings_file"
  hyprctl reload >/dev/null || true
  fail "could not validate Hyprland; restored $bindings_file from $backup"
fi
if [[ $config_errors =~ [^[:space:]] ]]; then
  cp -p -- "$backup" "$bindings_file"
  hyprctl reload >/dev/null || true
  printf '%s\n' "$config_errors" >&2
  fail "Hyprland rejected the change; restored $bindings_file from $backup"
fi

printf 'Workspace Switcher bindings installed. Backup: %s\n' "$backup"
printf 'Press Super+Tab to use the switcher.\n'
