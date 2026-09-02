#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'setup test: %s\n' "$*" >&2
  exit 1
}

mock_bin="$test_root/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/omarchy" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
if [[ $* == 'plugin list --json' ]]; then
  printf '[{"id":"reomarchy.workspace-switcher","enabled":%s}]\n' "${MOCK_PLUGIN_ENABLED:-true}"
elif [[ $* == 'plugin enable reomarchy.workspace-switcher' && ${MOCK_ENABLE_FAIL:-0} == 1 ]]; then
  printf '%s\n' 'synthetic enable failure' >&2
  exit 1
elif [[ $* == 'plugin enable reomarchy.workspace-switcher' ]]; then
  printf '%s\n' 'Enabled reomarchy.workspace-switcher'
fi
MOCK

cat > "$mock_bin/hyprctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
if [[ ${1:-} == configerrors && -n ${MOCK_CONFIG_ERRORS:-} ]]; then
  error_marker="${MOCK_LOG}.config-error-returned"
  if [[ ! -e $error_marker ]]; then
    printf '%s\n' "$MOCK_CONFIG_ERRORS"
    : > "$error_marker"
  fi
fi
MOCK

chmod +x "$mock_bin/omarchy" "$mock_bin/hyprctl"

new_case() {
  local name="$1"
  local case_dir="$test_root/$name"
  mkdir -p "$case_dir/config/hypr" "$case_dir/home"
  printf '%s\n' '-- Personal bindings' > "$case_dir/config/hypr/bindings.lua"
  printf '%s\n' "$case_dir"
}

run_install() {
  local case_dir="$1"
  env PATH="$mock_bin:$PATH" \
    HOME="$case_dir/home" \
    XDG_CONFIG_HOME="$case_dir/config" \
    MOCK_LOG="$case_dir/commands.log" \
    MOCK_CONFIG_ERRORS="${2:-}" \
    MOCK_PLUGIN_ENABLED="${3:-true}" \
    MOCK_ENABLE_FAIL="${4:-0}" \
    "$repo_dir/install.sh" --yes
}

case_dir=$(new_case success)
original_bindings="$case_dir/original-bindings.lua"
cp -- "$case_dir/config/hypr/bindings.lua" "$original_bindings"
chmod 0640 "$case_dir/config/hypr/bindings.lua"
run_install "$case_dir"
bindings="$case_dir/config/hypr/bindings.lua"
[[ $(grep -Fc -- '-- Workspace Switcher: begin' "$bindings") == 1 ]] || fail "installer did not add one marker block"
grep -Fq -- '/omarchy/plugins/reomarchy.workspace-switcher/bindings.lua' "$bindings" || fail "loader path missing"
backup=$(find "$case_dir/config/hypr" -maxdepth 1 -name 'bindings.lua.bak.workspace-switcher-install.*' -print -quit)
[[ -n $backup ]] || fail "install backup missing"
cmp -s -- "$original_bindings" "$backup" || fail "install backup does not match the original"
[[ $(stat -c '%a' "$bindings") == 640 ]] || fail "installer did not preserve binding file mode"
if command -v luac >/dev/null 2>&1; then luac -p "$bindings"; fi

run_install "$case_dir"
[[ $(grep -Fc -- '-- Workspace Switcher: begin' "$bindings") == 1 ]] || fail "installer is not idempotent"

env PATH="$mock_bin:$PATH" \
  HOME="$case_dir/home" \
  XDG_CONFIG_HOME="$case_dir/config" \
  MOCK_LOG="$case_dir/commands.log" \
  "$repo_dir/uninstall.sh" --yes
! grep -Fq -- '-- Workspace Switcher: begin' "$bindings" || fail "uninstaller left its marker block"
grep -Fq -- 'plugin remove reomarchy.workspace-switcher --yes' "$case_dir/commands.log" || fail "plugin removal was not delegated"

case_dir=$(new_case rollback)
original=$(sha256sum "$case_dir/config/hypr/bindings.lua" | cut -d' ' -f1)
if run_install "$case_dir" 'synthetic config error'; then
  fail "installer accepted Hyprland config errors"
fi
restored=$(sha256sum "$case_dir/config/hypr/bindings.lua" | cut -d' ' -f1)
[[ $original == "$restored" ]] || fail "installer did not roll back a rejected change"

case_dir=$(new_case enable-rollback)
original=$(sha256sum "$case_dir/config/hypr/bindings.lua" | cut -d' ' -f1)
if run_install "$case_dir" '' false 1; then
  fail "installer accepted a plugin enable failure"
fi
restored=$(sha256sum "$case_dir/config/hypr/bindings.lua" | cut -d' ' -f1)
[[ $original == "$restored" ]] || fail "installer did not roll back after plugin enable failure"
grep -Fq -- 'plugin disable reomarchy.workspace-switcher' "$case_dir/commands.log" || fail "installer did not restore disabled plugin state"

case_dir=$(new_case enable-disabled)
run_install "$case_dir" '' false
grep -Fq -- 'plugin enable reomarchy.workspace-switcher' "$case_dir/commands.log" || fail "installer did not enable a previously disabled plugin"

case_dir=$(new_case manual)
printf '%s\n' 'hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher")' > "$case_dir/config/hypr/old-setup.lua"
if run_install "$case_dir"; then
  fail "installer duplicated an existing manual setup"
fi
! grep -Fq -- '-- Workspace Switcher: begin' "$case_dir/config/hypr/bindings.lua" || fail "manual setup detection changed bindings"

case_dir=$(new_case reversed-markers)
bindings="$case_dir/config/hypr/bindings.lua"
cat >> "$bindings" <<'LUA'
-- Workspace Switcher: end
-- content that must survive
-- Workspace Switcher: begin
-- trailing content that must survive
LUA
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if env PATH="$mock_bin:$PATH" \
  HOME="$case_dir/home" \
  XDG_CONFIG_HOME="$case_dir/config" \
  MOCK_LOG="$case_dir/commands.log" \
  "$repo_dir/uninstall.sh" --yes --keep-plugin; then
  fail "uninstaller accepted reversed binding markers"
fi
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "uninstaller changed a file with reversed markers"

case_dir=$(new_case nested-markers)
bindings="$case_dir/config/hypr/bindings.lua"
cat >> "$bindings" <<'LUA'
-- Workspace Switcher: begin
-- Workspace Switcher: begin
-- Workspace Switcher: end
LUA
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if env PATH="$mock_bin:$PATH" \
  HOME="$case_dir/home" \
  XDG_CONFIG_HOME="$case_dir/config" \
  MOCK_LOG="$case_dir/commands.log" \
  "$repo_dir/uninstall.sh" --yes --keep-plugin; then
  fail "uninstaller accepted nested binding markers"
fi
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "uninstaller changed a file with nested markers"

case_dir=$(new_case truncated-install)
bindings="$case_dir/config/hypr/bindings.lua"
printf '%s\n' '-- Workspace Switcher: begin' >> "$bindings"
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if run_install "$case_dir"; then
  fail "installer accepted a truncated managed block"
fi
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a file with a truncated block"

case_dir=$(new_case altered-block)
bindings="$case_dir/config/hypr/bindings.lua"
cat >> "$bindings" <<'LUA'
-- Workspace Switcher: begin
-- unexpected content
-- Workspace Switcher: end
LUA
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if run_install "$case_dir"; then
  fail "installer accepted an altered managed block"
fi
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a file with an altered block"

case_dir=$(new_case symlink-target)
bindings="$case_dir/config/hypr/bindings.lua"
victim="$case_dir/victim.lua"
printf '%s\n' '-- Content outside Hyprland config' > "$victim"
rm -- "$bindings"
ln -s -- "$victim" "$bindings"
original=$(sha256sum "$victim" | cut -d' ' -f1)
if run_install "$case_dir"; then
  fail "installer followed a symlinked binding file"
fi
unchanged=$(sha256sum "$victim" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a symlink target"

case_dir=$(new_case symlink-directory)
mv -- "$case_dir/config/hypr" "$case_dir/config/real-hypr"
ln -s -- "$case_dir/config/real-hypr" "$case_dir/config/hypr"
bindings="$case_dir/config/real-hypr/bindings.lua"
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if run_install "$case_dir"; then
  fail "installer followed a symlinked Hyprland config directory"
fi
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a file through a symlinked directory"

! grep -Eq -- 'hl\.(un)?bind\("SUPER \+ mouse' "$repo_dir/bindings.lua" || fail "runtime bindings still replace Super+mouse mappings"
grep -Fq -- 'hl.dsp.submap(workspace_switcher_submap)' "$repo_dir/bindings.lua" || fail "runtime bindings do not isolate switcher input"
grep -Fq -- 'release_watchdog = hl.timer' "$repo_dir/bindings.lua" || fail "runtime bindings have no missed-release cleanup"

printf 'setup tests: pass\n'
