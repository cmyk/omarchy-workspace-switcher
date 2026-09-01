# Omarchy Workspace Switcher

A Mac-style visual workspace switcher for Omarchy. It presents occupied
Hyprland workspaces as cached visual previews in stable numeric positions,
cycles first to the most-recently used workspace, then moves left or right
through the visible cards while Command/Super is held. It activates the
selection when the modifier is released. A quick Command-Tab switches without
flashing the overlay; holding Command briefly reveals the visual switcher.

Each workspace receives one in-memory screenshot shortly after it becomes
active. The switcher never records continuously and never writes previews to
disk. Until a workspace has been visited, its card uses a lightweight window
layout as a fallback.

## Install

```bash
omarchy plugin add https://github.com/cmyk/omarchy-workspace-switcher.git --enable
```

Add bindings to `~/.config/hypr/bindings.lua` or another user-loaded Lua file:

```lua
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

local workspace_switcher_active = false
local function summon_workspace_switcher(direction)
  workspace_switcher_active = true
  hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"direction\":" .. direction .. "}'")
end

hl.bind("SUPER + TAB", function() summon_workspace_switcher(1) end, { description = "Visual workspace switcher" })
hl.bind("SUPER + SHIFT + TAB", function() summon_workspace_switcher(-1) end, { description = "Visual workspace switcher (reverse)" })

hl.on("input.keyboard.key", function(keycode, _, state)
  if workspace_switcher_active and state == 0 and (keycode == 133 or keycode == 134) then
    workspace_switcher_active = false
    hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"commit\":true}'")
  end
end)
```

The stock bindings previously assigned these keys to immediate next/previous
workspace switching.
