#!/bin/bash -p
# Keep errors visible in the terminal opened by the first-run prompt.
PATH=/usr/bin:/bin
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_ORIGIN_PATH LD_DEBUG LD_DEBUG_OUTPUT
unset CDPATH BASH_ENV ENV
IFS=$' \t\n'
set -uo pipefail
case "${BASH_SOURCE[0]}" in
  */*) script_dir_raw="${BASH_SOURCE[0]%/*}" ;;
  *) script_dir_raw=. ;;
esac
script_dir=$(cd -- "$script_dir_raw" && pwd -P) || exit 1
/usr/bin/bash -p "$script_dir/install.sh"
result=$?
if ((result != 0)); then
  printf '\nSetup did not complete. Review the message above; press Enter to close.\n'
  read -r answer
fi
# Re-check after success or cancellation without opening workspace navigation.
# The installer may have reloaded the shell, so address the plugin by ID.
/usr/bin/omarchy-shell shell summon reomarchy.workspace-switcher '{"setup":true}' >/dev/null 2>&1 || true
exit "$result"
