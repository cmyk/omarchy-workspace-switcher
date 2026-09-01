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

To keep the always-loaded overlay bounded, it displays at most 10 occupied
workspaces, retains previews for the 5 most recently visited workspaces, and
uses at most 24 windows per workspace in the fallback layout. When more than
10 workspaces are occupied, the current and most recently used workspaces take
priority.

![Workspace switcher showing five workspace previews](preview.png)

> [!NOTE]
> This is a beta release. It is currently tested on Omarchy 4.0.2 with
> Hyprland 0.56.2 and Quickshell 0.3.1 on a 2011 MacBook Pro. Reports from
> other hardware, keyboards, display layouts, and Omarchy versions are very
> welcome.

## Install

```bash
omarchy plugin add https://github.com/cmyk/omarchy-workspace-switcher.git --enable
```

Add bindings to `~/.config/hypr/bindings.lua` or another user-loaded Lua file:

```lua
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

local workspace_switcher_active = false

local function suspend_workspace_switcher_mouse_bindings()
  hl.unbind("SUPER + mouse_down")
  hl.unbind("SUPER + mouse_up")
  hl.unbind("SUPER + mouse:272")
  hl.unbind("SUPER + mouse:273")
end

local function restore_workspace_switcher_mouse_bindings()
  hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { description = "Scroll active workspace forward" })
  hl.bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }), { description = "Scroll active workspace backward" })
  hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true, description = "Move window" })
  hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Resize window" })
end

local function summon_workspace_switcher(direction)
  if not workspace_switcher_active then
    suspend_workspace_switcher_mouse_bindings()
  end
  workspace_switcher_active = true
  hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"direction\":" .. direction .. "}'")
end

hl.bind("SUPER + TAB", function() summon_workspace_switcher(1) end, { description = "Visual workspace switcher" })
hl.bind("SUPER + SHIFT + TAB", function() summon_workspace_switcher(-1) end, { description = "Visual workspace switcher (reverse)" })

hl.on("input.keyboard.key", function(keycode, _, state)
  if workspace_switcher_active and state == 0 and (keycode == 133 or keycode == 134) then
    workspace_switcher_active = false
    restore_workspace_switcher_mouse_bindings()
    hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"commit\":true}'")
  end
end)
```

The stock bindings previously assigned these keys to immediate next/previous
workspace switching.

## Update

```bash
omarchy plugin update reomarchy.workspace-switcher --yes
```

## Remove

Remove the workspace-switcher block from your Hyprland bindings, then run:

```bash
omarchy plugin remove reomarchy.workspace-switcher --yes
```

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
disk by the plugin. At most five preview frames are retained at once.

## License

[MIT](LICENSE)
