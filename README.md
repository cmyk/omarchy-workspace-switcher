# Omarchy Workspace Switcher

A Mac-style visual workspace switcher for Omarchy. It presents occupied
Hyprland workspaces as cached visual previews in stable numeric positions,
cycles first to the most-recently used workspace, then moves left or right
through the visible cards while Command/Super is held. It activates the
selection when the modifier is released. A quick Command-Tab switches without
flashing the overlay; holding Command briefly reveals the visual switcher.
Mouse hover provides a subtle visual rollover without changing the keyboard
selection, while clicking a preview activates that workspace.

Each workspace receives one in-memory screenshot shortly after it becomes
active. The switcher never records continuously and never writes previews to
disk. Until a workspace has been visited, its card uses a lightweight window
layout as a fallback.

To keep the always-loaded overlay bounded, it displays and retains previews for
at most 10 occupied workspaces, and uses at most 24 windows per workspace in
the fallback layout. When more than 10 workspaces are occupied, the current and
most recently used workspaces take priority.

![Workspace switcher showing five workspace previews](preview.png)

> [!NOTE]
> This is a beta release. It is currently tested on Omarchy 4.0.2 with
> Hyprland 0.56.2 and Quickshell 0.3.1 on a 2011 MacBook Pro. Reports from
> other hardware, keyboards, display layouts, and Omarchy versions are very
> welcome.

## Install

```bash
omarchy plugin add https://github.com/cmyk/omarchy-workspace-switcher.git --enable
~/.config/omarchy/plugins/reomarchy.workspace-switcher/install.sh
```

The guided setup explains that it replaces Omarchy's immediate
`Super+Tab`/`Super+Shift+Tab` workspace cycling, checks for an existing manual
setup, asks for confirmation, backs up `~/.config/hypr/bindings.lua`, and adds
only a marked loader block. It reloads Hyprland and rolls the change back if
configuration validation fails. Pass `--yes` for non-interactive setup.

If you already installed the bindings documented by version 0.2.x, keep that
manual setup or remove its old Lua block before running `install.sh`.

## Update

```bash
omarchy plugin update reomarchy.workspace-switcher --yes
```

## Remove

```bash
~/.config/omarchy/plugins/reomarchy.workspace-switcher/uninstall.sh
```

The removal helper deletes only its marked loader block, backs up and validates
the Hyprland configuration, then delegates plugin removal to Omarchy. Use
`--keep-plugin` to remove only the managed bindings.

## Compatibility reports

When reporting a problem, include the output of:

```bash
omarchy version
hyprctl version
quickshell --version
```

Please also mention whether you use an Apple or PC keyboard, your monitor
layout, and approximately how many occupied workspaces you had.

## Privacy

Workspace previews are captured only after a workspace becomes active. They
are kept in memory, are never continuously recorded, and are never written to
disk by the plugin. At most 10 preview frames are retained at once.

## License

[MIT](LICENSE)
