#!/usr/bin/env bash
set -euo pipefail

plugin_id="reomarchy.workspace-switcher"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
hypr_dir="$config_home/hypr"
bindings_file="$hypr_dir/bindings.lua"
begin_marker="-- Workspace Switcher: begin"
end_marker="-- Workspace Switcher: end"
assume_yes=0
keep_plugin=0
temp_file=""

cleanup() {
  if [[ -n $temp_file && -f $temp_file ]]; then rm -f -- "$temp_file"; fi
}
trap cleanup EXIT

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

if [[ -f $bindings_file ]]; then
  [[ ! -L $bindings_file ]] || fail "refusing to replace symlinked bindings file: $bindings_file"
  read -r begin_count begin_line end_count end_line < <(
    awk -v begin="$begin_marker" -v end="$end_marker" '
      $0 == begin { begin_count++; begin_line = NR }
      $0 == end { end_count++; end_line = NR }
      END { print begin_count + 0, begin_line + 0, end_count + 0, end_line + 0 }
    ' "$bindings_file"
  )

  if (( begin_count == 1 && end_count == 1 && begin_line < end_line )); then
    backup=$(mktemp "${bindings_file}.bak.workspace-switcher-remove.XXXXXXXX")
    cp -p -- "$bindings_file" "$backup"

    temp_file=$(mktemp "$hypr_dir/.workspace-switcher-bindings.XXXXXX")
    awk -v begin="$begin_marker" -v end="$end_marker" '
      $0 == begin { skipping = 1; next }
      $0 == end { skipping = 0; next }
      !skipping { print }
    ' "$bindings_file" > "$temp_file"
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
    printf 'Removed Workspace Switcher bindings. Backup: %s\n' "$backup"
  elif (( begin_count != 0 || end_count != 0 )); then
    fail "expected one correctly ordered binding block; refusing to edit $bindings_file"
  else
    printf 'No managed Workspace Switcher binding block found in %s.\n' "$bindings_file"
  fi
fi

if (( ! keep_plugin )); then
  remove_args=(plugin remove "$plugin_id")
  (( assume_yes )) && remove_args+=(--yes)
  omarchy "${remove_args[@]}"
fi
