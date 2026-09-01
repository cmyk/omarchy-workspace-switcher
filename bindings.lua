-- Replace Omarchy's immediate workspace cycling with the visual switcher.
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

-- XKB keycodes 133/134 are left/right Command/Super; state 0 is release.
hl.on("input.keyboard.key", function(keycode, _, state)
  if workspace_switcher_active and state == 0 and (keycode == 133 or keycode == 134) then
    workspace_switcher_active = false
    restore_workspace_switcher_mouse_bindings()
    hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"commit\":true}'")
  end
end)
