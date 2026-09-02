-- Replace Omarchy's immediate workspace cycling with the visual switcher.
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

local workspace_switcher_active = false

local function summon_workspace_switcher(direction)
  workspace_switcher_active = true
  hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"direction\":" .. direction .. "}'")
end

hl.bind("SUPER + TAB", function() summon_workspace_switcher(1) end, { description = "Visual workspace switcher" })
hl.bind("SUPER + SHIFT + TAB", function() summon_workspace_switcher(-1) end, { description = "Visual workspace switcher (reverse)" })

-- XKB keycodes 133/134 are left/right Command/Super; state 0 is release.
hl.on("input.keyboard.key", function(keycode, _, state)
  if workspace_switcher_active and state == 0 and (keycode == 133 or keycode == 134) then
    workspace_switcher_active = false
    hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"commit\":true}'")
  end
end)
