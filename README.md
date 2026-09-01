# Omarchy Workspace Switcher

A Mac-style visual workspace switcher for Omarchy. It presents occupied
Hyprland workspaces as miniature layouts, orders them by most-recent use,
cycles while Command/Super is held, and activates the selection when the
modifier is released.

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
