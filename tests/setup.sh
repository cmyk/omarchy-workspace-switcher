#!/bin/bash
set -euo pipefail

# The installer only executes fixed root-owned tools (/usr/bin/hyprctl,
# /usr/bin/omarchy) and never consults PATH, so the suite runs inside a user and
# mount namespace. The real /usr/bin is bound aside and a namespace-owned
# directory of symlinks to it, plus the two mock dispatchers, is bound over
# /usr/bin. Inside the namespace that directory and the mocks are owned by uid
# 0, which satisfies the helper's root-ownership checks.
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() {
  printf 'setup test: %s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} != --in-namespace ]]; then
  command -v unshare >/dev/null 2>&1 || fail "unshare is required to run the suite"
  unshare -Urm --propagation private true 2>/dev/null || fail "unprivileged user namespaces are unavailable"
  # The loader canary is compiled out here: inside the namespace /usr/bin is a
  # mock of symlinks and gcc cannot locate its own cc1 through it.
  if command -v cc >/dev/null 2>&1; then
    canary_dir=$(mktemp -d)
    {
      printf '%s\n' '#define _GNU_SOURCE' '#include <stdio.h>'
      printf '%s\n' 'extern char *program_invocation_short_name;'
      printf '%s\n' '__attribute__((constructor)) static void record(void) {'
      printf '%s\n' '  FILE *handle = fopen(CANARY_PATH, "a");'
      printf '%s\n' '  if (handle) {'
      printf '%s\n' '    fprintf(handle, "%s\n", program_invocation_short_name);'
      printf '%s\n' '    fclose(handle);'
      printf '%s\n' '  }'
      printf '%s\n' '}'
    } > "$canary_dir/canary.c"
    if cc -shared -fPIC -DCANARY_PATH="\"$canary_dir/canary.log\"" \
      -o "$canary_dir/canary.so" "$canary_dir/canary.c" 2> "$canary_dir/cc.log"; then
      export CANARY_DIR="$canary_dir"
    else
      printf 'setup test: skipping loader canary (build failed)\n' >&2
      rm -rf -- "$canary_dir"
    fi
  fi
  exec unshare -Urm --propagation private /bin/bash "${BASH_SOURCE[0]}" --in-namespace
fi

test_root=$(mktemp -d)
real_bin="$test_root/realbin"
mock_bin="$test_root/fakebin"
mkdir -p "$real_bin" "$mock_bin"
mount --bind /usr/bin "$real_bin"
mount -o remount,bind,ro "$real_bin"
cleanup() {
  umount /usr/bin 2>/dev/null || true
  umount "$real_bin" 2>/dev/null || true
  [[ -n ${CANARY_DIR:-} ]] && rm -rf -- "$CANARY_DIR"
  mountpoint -q "$real_bin" && return
  rm -rf -- "$test_root"
}
trap cleanup EXIT
while IFS= read -r -d '' name; do
  ln -s -- "$real_bin/$name" "$mock_bin/$name"
done < <(find "$real_bin" -mindepth 1 -maxdepth 1 -printf '%f\0')
rm -f -- "$mock_bin/hyprctl" "$mock_bin/omarchy"

# Dispatchers receive only the allowlisted environment, so every per-case knob
# lives in files under "$XDG_CONFIG_HOME/../mock". A per-case executable there
# replaces the default behaviour entirely.
write_dispatcher() {
  local name="$1"
  cat > "$mock_bin/$name" <<MOCK
#!/bin/bash
name=$name
case_root="\${XDG_CONFIG_HOME:?}/.."
mock_root="\$case_root/mock"
log="\$case_root/commands.log"
printf '%s\\n' "\$*" >> "\$log"
env | sort > "\$case_root/env.\$name.log"
if [[ -x \$mock_root/\$name ]]; then
  exec "\$mock_root/\$name" "\$@"
fi
MOCK
  chmod 755 "$mock_bin/$name"
}

write_dispatcher hyprctl
cat >> "$mock_bin/hyprctl" <<'MOCK'
if [[ ${1:-} == configerrors && -e $mock_root/config-errors ]]; then
  error_marker="$log.config-error-returned"
  if [[ ! -e $error_marker ]]; then
    cat "$mock_root/config-errors"
    : > "$error_marker"
  fi
fi
MOCK

write_dispatcher omarchy
cat >> "$mock_bin/omarchy" <<'MOCK'
if [[ $* == 'plugin list --json' ]]; then
  enabled=true
  [[ -e $mock_root/plugin-disabled ]] && enabled=false
  printf '[{"id":"reomarchy.workspace-switcher","enabled":%s}]\n' "$enabled"
elif [[ $* == 'plugin enable reomarchy.workspace-switcher' && -e $mock_root/enable-fail ]]; then
  printf '%s\n' 'synthetic enable failure' >&2
  exit 1
elif [[ $* == 'plugin enable reomarchy.workspace-switcher' ]]; then
  printf '%s\n' 'Enabled reomarchy.workspace-switcher'
elif [[ $* == 'plugin disable reomarchy.workspace-switcher' && -e $mock_root/disable-fail ]]; then
  printf '%s\n' 'synthetic disable failure' >&2
  exit 1
fi
MOCK

mount --bind "$mock_bin" /usr/bin
[[ $(stat -c '%u' /usr/bin /usr/bin/hyprctl /usr/bin/omarchy | sort -u) == 0 ]] || fail "namespace mount did not take ownership of /usr/bin"
/usr/bin/python3 -I -c 'pass' || fail "python is not reachable through the namespace /usr/bin"

new_case() {
  local name="$1"
  local case_dir="$test_root/$name"
  mkdir -p "$case_dir/config/hypr" "$case_dir/home" "$case_dir/mock"
  printf '%s\n' '-- Personal bindings' > "$case_dir/config/hypr/bindings.lua"
  printf '%s\n' "$case_dir"
}

# run_install CASE [config-errors] [plugin-enabled true|false] [enable-fail 0|1] [disable-fail 0|1]
run_install() {
  local case_dir="$1"
  rm -f -- "$case_dir/mock/config-errors" "$case_dir/mock/plugin-disabled" \
    "$case_dir/mock/enable-fail" "$case_dir/mock/disable-fail"
  [[ -n ${2:-} ]] && printf '%s\n' "$2" > "$case_dir/mock/config-errors"
  [[ ${3:-true} == false ]] && : > "$case_dir/mock/plugin-disabled"
  [[ ${4:-0} == 1 ]] && : > "$case_dir/mock/enable-fail"
  [[ ${5:-0} == 1 ]] && : > "$case_dir/mock/disable-fail"
  env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/config" "$repo_dir/install.sh" --yes
}

run_uninstall() {
  local case_dir="$1"
  shift
  env HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/config" "$repo_dir/uninstall.sh" --yes "$@"
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
[[ ! -e $case_dir/config/hypr/.workspace-switcher-transaction.json ]] || fail "marker left after a successful install"
if command -v luac >/dev/null 2>&1; then luac -p "$bindings"; fi

run_install "$case_dir"
[[ $(grep -Fc -- '-- Workspace Switcher: begin' "$bindings") == 1 ]] || fail "installer is not idempotent"

run_uninstall "$case_dir"
! grep -Fq -- '-- Workspace Switcher: begin' "$bindings" || fail "uninstaller left its marker block"
cmp -s -- "$original_bindings" "$bindings" || fail "remove and install did not round-trip byte for byte"
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

case_dir=$(new_case installed-enable-rollback-failure)
run_install "$case_dir"
if run_install "$case_dir" '' false 1 1 2> "$case_dir/error.log"; then
  fail "already-installed path accepted an enable and rollback failure"
fi
grep -Fq -- 'could not enable the plugin: synthetic enable failure' "$case_dir/error.log" || fail "already-installed path masked the enable error"
grep -Fq -- 'plugin state rollback also failed' "$case_dir/error.log" || fail "already-installed path masked the rollback error"

case_dir=$(new_case enable-disabled)
run_install "$case_dir" '' false
grep -Fq -- 'plugin enable reomarchy.workspace-switcher' "$case_dir/commands.log" || fail "installer did not enable a previously disabled plugin"

case_dir=$(new_case manual)
printf '%s\n' 'hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher")' > "$case_dir/config/hypr/old-setup.lua"
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer duplicated an existing manual setup"
fi
grep -Fq -- 'old-setup.lua' "$case_dir/error.log" || fail "manual setup file was not named"
! grep -Fq -- '-- Workspace Switcher: begin' "$case_dir/config/hypr/bindings.lua" || fail "manual setup detection changed bindings"

# A tree the scan cannot finish must block installation: an incomplete scan
# cannot show that no manual setup exists, and installing anyway would add a
# second set of bindings beside an existing one.
case_dir=$(new_case scan-truncated)
hypr="$case_dir/config/hypr"
mkdir -p "$hypr/many"
for i in $(seq 1 6000); do : > "$hypr/many/f$i.conf"; done
original=$(sha256sum "$hypr/bindings.lua" | cut -d' ' -f1)
start=$(date +%s)
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer proceeded after an incomplete scan"
fi
elapsed=$(( $(date +%s) - start ))
(( elapsed < 60 )) || fail "bounded scan took ${elapsed}s"
grep -Fq -- 'cannot be ruled out' "$case_dir/error.log" || fail "truncated scan error lacks guidance"
unchanged=$(sha256sum "$hypr/bindings.lua" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed bindings after an incomplete scan"

# A tree that fits inside the budget installs, and the scan neither follows
# symlinks nor descends past its depth limit.
case_dir=$(new_case scan-bounds)
hypr="$case_dir/config/hypr"
outside="$case_dir/outside"
mkdir -p "$outside/deep" "$hypr/a/b"
printf '%s\n' 'hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher")' > "$outside/deep/linked-setup.lua"
ln -s -- "$outside" "$hypr/linked-dir"
ln -s -- "$outside/deep/linked-setup.lua" "$hypr/linked-file.lua"
run_install "$case_dir" 2> "$case_dir/error.log"
grep -Fq -- '-- Workspace Switcher: begin' "$hypr/bindings.lua" || fail "install refused despite no reachable manual setup"
! grep -Fq -- 'linked' "$case_dir/error.log" || fail "scan followed a symlink"

# A manual setup nested past the depth limit cannot be ruled out, so the
# installer refuses rather than adding a second set of bindings.
case_dir=$(new_case scan-too-deep)
hypr="$case_dir/config/hypr"
deep="$hypr/d1/d2/d3/d4/d5/d6/d7/d8/d9"
mkdir -p "$deep"
printf '%s\n' 'hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher")' > "$deep/too-deep.lua"
original=$(sha256sum "$hypr/bindings.lua" | cut -d' ' -f1)
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer proceeded past an unscannable depth"
fi
grep -Fq -- 'nested deeper than' "$case_dir/error.log" || fail "depth limit error lacks the reason"
unchanged=$(sha256sum "$hypr/bindings.lua" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed bindings after a depth-limited scan"

# A Lua file well over a megabyte is still searched, so a manual setup hiding
# in a large file is found rather than skipped.
case_dir=$(new_case scan-large-file)
hypr="$case_dir/config/hypr"
{ head -c 2097152 /dev/zero | tr '\0' '-'; printf '\n%s\n' 'reomarchy.workspace-switcher'; } > "$hypr/big.lua"
original=$(sha256sum "$hypr/bindings.lua" | cut -d' ' -f1)
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer missed a manual setup inside a large Lua file"
fi
grep -Fq -- 'big.lua' "$case_dir/error.log" || fail "large-file manual setup was not named"
unchanged=$(sha256sum "$hypr/bindings.lua" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed bindings when a manual setup was present"


case_dir=$(new_case scan-depth-hit)
hypr="$case_dir/config/hypr"
mkdir -p "$hypr/conf.d/extra"
printf '%s\n' 'hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher")' > "$hypr/conf.d/extra/switcher.lua"
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer missed a nested manual setup"
fi
grep -Fq -- 'conf.d/extra/switcher.lua' "$case_dir/error.log" || fail "nested manual setup was not named"

case_dir=$(new_case hostile-environment)
evil="$case_dir/evil"
mkdir -p "$evil/py"
for tool in hyprctl omarchy jq python3 grep gum env bash unshare \
  dirname basename pwd cat sed head tr find realpath readlink; do
  printf '#!/bin/bash\n: > "%s/ran-%s"\nexit 1\n' "$evil" "$tool" > "$evil/$tool"
  chmod 755 "$evil/$tool"
done
printf '%s\n' 'raise SystemExit("hostile json module imported")' > "$evil/py/json.py"
printf '%s\n' ": > '$evil/bash-env-ran'" > "$evil/bash_env.sh"
if ! env PATH="$evil:$PATH" \
  LD_PRELOAD="$evil/nonexistent.so" \
  LD_LIBRARY_PATH="$evil" \
  PYTHONPATH="$evil/py" \
  PYTHONSTARTUP="$evil/py/json.py" \
  BASH_ENV="$evil/bash_env.sh" \
  ENV="$evil/bash_env.sh" \
  CDPATH="$evil" \
  IFS=$'\n' \
  HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/config" \
  "$repo_dir/install.sh" --yes 2> "$case_dir/error.log"; then
  cat "$case_dir/error.log" >&2
  fail "installer failed under a hostile environment"
fi
grep -Fq -- '-- Workspace Switcher: begin' "$case_dir/config/hypr/bindings.lua" || fail "hostile-environment install incomplete"
ran=$(find "$evil" -maxdepth 1 -name 'ran-*' -o -maxdepth 1 -name 'bash-env-ran')
[[ -z $ran ]] || fail "PATH or startup-file replacement was executed: $ran"
for name in hyprctl omarchy; do
  env_log="$case_dir/env.$name.log"
  [[ -f $env_log ]] || fail "$name env log missing"
  grep -qx 'PATH=/usr/bin:/bin' "$env_log" || fail "$name did not receive the fixed PATH"
  ! grep -Eq '^(LD_PRELOAD|LD_LIBRARY_PATH|PYTHONPATH|PYTHONSTARTUP|BASH_ENV|ENV|CDPATH)=' "$env_log" || fail "$name inherited a hostile variable"
done

# A real preloaded library, to measure the boundary honestly rather than assert
# a property the process cannot have. The dynamic loader maps it before the
# first line of install.sh runs, so it MUST appear in the launching shell. It
# must not reach any tool the scripts invoke, because those go through env -i.
if [[ -n ${CANARY_DIR:-} ]]; then
  case_dir=$(new_case loader-canary)
  canary_log="$CANARY_DIR/canary.log"
  env LD_PRELOAD="$CANARY_DIR/canary.so" \
    HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/config" \
    "$repo_dir/install.sh" --yes > /dev/null
  grep -Fq -- '-- Workspace Switcher: begin' "$case_dir/config/hypr/bindings.lua" || fail "canary run did not install"
  [[ -s $canary_log ]] || fail "loader canary never loaded; the test proves nothing"
  grep -qx 'bash' "$canary_log" || fail "loader canary did not load into the launching shell"
  [[ $(sort -u "$canary_log" | wc -l) == 1 ]] ||
    fail "preloaded library reached a child process: $(sort -u "$canary_log" | tr '\n' ' ')"
  for name in env python3 jq hyprctl omarchy gum; do
    ! grep -qx "$name" "$canary_log" || fail "preloaded library reached $name through the scrubbed environment"
  done
fi

case_dir=$(new_case group-writable-directory)
bindings="$case_dir/config/hypr/bindings.lua"
original=$(sha256sum "$bindings" | cut -d' ' -f1)
chmod g+w "$case_dir/config/hypr"
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer accepted a group-writable Hyprland config directory"
fi
grep -Fq -- 'writable by group or other' "$case_dir/error.log" || fail "group-writable directory error lacks guidance"
chmod g-w "$case_dir/config/hypr"
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a file in a group-writable directory"
run_install "$case_dir" > /dev/null
grep -Fq -- '-- Workspace Switcher: begin' "$bindings" || fail "installer refused a correctly permissioned directory"

case_dir=$(new_case world-writable-target)
bindings="$case_dir/config/hypr/bindings.lua"
original=$(sha256sum "$bindings" | cut -d' ' -f1)
chmod o+w "$bindings"
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer accepted a world-writable binding file"
fi
grep -Fq -- 'writable by group or other' "$case_dir/error.log" || fail "world-writable target error lacks guidance"
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a world-writable binding file"
if run_uninstall "$case_dir" --keep-plugin 2> "$case_dir/error.log"; then
  fail "uninstaller accepted a world-writable binding file"
fi
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "uninstaller changed a world-writable binding file"

case_dir=$(new_case untrusted-executable)
bindings="$case_dir/config/hypr/bindings.lua"
original=$(sha256sum "$bindings" | cut -d' ' -f1)
chmod o+w /usr/bin/hyprctl
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  chmod o-w /usr/bin/hyprctl
  fail "installer ran a world-writable hyprctl"
fi
chmod o-w /usr/bin/hyprctl
grep -Fq -- 'writable by other users' "$case_dir/error.log" || fail "untrusted executable error lacks guidance"
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a file with an untrusted executable"
[[ ! -e $case_dir/commands.log ]] || fail "installer invoked an untrusted hyprctl"

case_dir=$(new_case reversed-markers)
bindings="$case_dir/config/hypr/bindings.lua"
cat >> "$bindings" <<'LUA'
-- Workspace Switcher: end
-- content that must survive
-- Workspace Switcher: begin
-- trailing content that must survive
LUA
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if run_uninstall "$case_dir" --keep-plugin; then
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
if run_uninstall "$case_dir" --keep-plugin; then
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
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer followed a symlinked binding file"
fi
grep -Fq -- 'refusing symlinked bindings.lua' "$case_dir/error.log" || fail "symlinked binding error lacks guidance"
unchanged=$(sha256sum "$victim" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a symlink target"
if run_uninstall "$case_dir" --keep-plugin 2> "$case_dir/error.log"; then
  fail "uninstaller followed a symlinked binding file"
fi
unchanged=$(sha256sum "$victim" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "uninstaller changed a symlink target"

case_dir=$(new_case symlink-directory)
mv -- "$case_dir/config/hypr" "$case_dir/config/real-hypr"
ln -s -- "$case_dir/config/real-hypr" "$case_dir/config/hypr"
bindings="$case_dir/config/real-hypr/bindings.lua"
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer followed a symlinked Hyprland config directory"
fi
grep -Fq -- 'refusing a symlinked Hyprland config directory' "$case_dir/error.log" || fail "symlinked directory error lacks guidance"
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed a file through a symlinked directory"

case_dir=$(new_case oversize)
bindings="$case_dir/config/hypr/bindings.lua"
head -c 4194305 /dev/zero | tr '\0' '-' > "$bindings"
original=$(sha256sum "$bindings" | cut -d' ' -f1)
if run_install "$case_dir" 2> "$case_dir/error.log"; then
  fail "installer accepted an oversized binding file"
fi
grep -Fq -- 'larger than' "$case_dir/error.log" || fail "oversized binding file error lacks the bound"
unchanged=$(sha256sum "$bindings" | cut -d' ' -f1)
[[ $original == "$unchanged" ]] || fail "installer changed an oversized binding file"

/usr/bin/python3 -I "$repo_dir/tests/transaction.py"

! grep -Eq -- 'hl\.(un)?bind\("SUPER \+ mouse' "$repo_dir/bindings.lua" || fail "runtime bindings still replace Super+mouse mappings"
if command -v lua >/dev/null 2>&1; then
  lua "$repo_dir/tests/bindings.lua" "$repo_dir/bindings.lua"
else
  printf 'binding tests: skipped (lua unavailable)\n'
fi

printf 'setup tests: pass\n'
