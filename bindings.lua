-- Replace Omarchy's immediate workspace cycling with the visual switcher.
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

local workspace_switcher_active = false
local workspace_switcher_submap = "reomarchy-workspace-switcher"
local release_watchdog

local function finish_workspace_switcher(commit)
  if not workspace_switcher_active then return end

  workspace_switcher_active = false
  release_watchdog:set_enabled(false)
  if hl.get_current_submap() == workspace_switcher_submap then
    hl.dispatch(hl.dsp.submap("reset"))
  end

  if commit then
    hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"commit\":true}'")
  else
    hl.exec_cmd("omarchy-shell shell hide reomarchy.workspace-switcher")
  end
end

release_watchdog = hl.timer(function()
  if workspace_switcher_active
      and not hl.is_key_down("SUPER_L")
      and not hl.is_key_down("SUPER_R") then
    finish_workspace_switcher(true)
  end
end, { timeout = 100, type = "repeat" })
release_watchdog:set_enabled(false)

local function summon_workspace_switcher(direction)
  if not workspace_switcher_active then
    workspace_switcher_active = true
    hl.dispatch(hl.dsp.submap(workspace_switcher_submap))
  end
  release_watchdog:set_enabled(true)
  hl.exec_cmd("omarchy-shell shell summon reomarchy.workspace-switcher '{\"direction\":" .. direction .. "}'")
end

hl.define_submap(workspace_switcher_submap, function()
  hl.bind("SUPER + TAB", function() summon_workspace_switcher(1) end)
  hl.bind("SUPER + SHIFT + TAB", function() summon_workspace_switcher(-1) end)
  hl.bind("escape", function() finish_workspace_switcher(false) end, { ignore_mods = true })
end)

hl.bind("SUPER + TAB", function() summon_workspace_switcher(1) end, { description = "Visual workspace switcher" })
hl.bind("SUPER + SHIFT + TAB", function() summon_workspace_switcher(-1) end, { description = "Visual workspace switcher (reverse)" })

-- XKB keycodes 133/134 are left/right Command/Super; state 0 is release.
hl.on("input.keyboard.key", function(keycode, _, state)
  if workspace_switcher_active and state == 0 and (keycode == 133 or keycode == 134) then
    finish_workspace_switcher(true)
  end
end)

-- A config reload destroys the old watchdog and event subscription. Never
-- leave Hyprland in the switcher submap if a reload happened mid-switch.
if hl.get_current_submap() == workspace_switcher_submap then
  hl.dispatch(hl.dsp.submap("reset"))
end
