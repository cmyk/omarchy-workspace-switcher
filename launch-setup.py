#!/usr/bin/python3 -I
"""Keep the setup terminal alive if enabling the plugin reloads its QML."""
from pathlib import Path
import subprocess
import sys


def launch():
    wrapper = str(Path(__file__).resolve().with_name("setup-terminal.sh"))
    # A destroyed QML Process may terminate this supervisor, but the terminal
    # has its own session and no pipes tied to the supervisor's lifetime.
    process = subprocess.Popen(
        ["/usr/bin/xdg-terminal-exec", "--app-id=reomarchy.workspace-switcher.setup",
         "-e", "/usr/bin/bash", "-p", wrapper],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return process.wait()


if __name__ == "__main__":
    try:
        sys.exit(launch())
    except OSError as error:
        print(f"Could not launch setup terminal: {error}", file=sys.stderr)
        sys.exit(1)
