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
MOCK

cat > "$mock_bin/hyprctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
if [[ ${1:-} == configerrors && -n ${MOCK_CONFIG_ERRORS:-} ]]; then
  printf '%s\n' "$MOCK_CONFIG_ERRORS"
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
    "$repo_dir/install.sh" --yes
}

case_dir=$(new_case success)
run_install "$case_dir"
bindings="$case_dir/config/hypr/bindings.lua"
[[ $(grep -Fc -- '-- Workspace Switcher: begin' "$bindings") == 1 ]] || fail "installer did not add one marker block"
grep -Fq -- '/omarchy/plugins/reomarchy.workspace-switcher/bindings.lua' "$bindings" || fail "loader path missing"
find "$case_dir/config/hypr" -maxdepth 1 -name 'bindings.lua.bak.workspace-switcher.*' | grep -q . || fail "install backup missing"
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

printf 'setup tests: pass\n'
