local bindings = {}
local events = {}
local commands = {}
local current_definition_submap = ""
local current_submap = "default"
local pressed_keycodes = {}
local watchdog

local function fail(message)
  io.stderr:write("binding test: " .. message .. "\n")
  os.exit(1)
end

local function expect(condition, message)
  if not condition then fail(message) end
end

hl = {
  dsp = {
    submap = function(name)
      return function() current_submap = name == "reset" and "default" or name end
    end
  },
  unbind = function() end,
  bind = function(keys, action)
    bindings[current_definition_submap .. "|" .. keys] = action
  end,
  define_submap = function(name, callback)
    local previous = current_definition_submap
    current_definition_submap = name
    callback()
    current_definition_submap = previous
  end,
  dispatch = function(action) action() end,
  exec_cmd = function(command) table.insert(commands, command) end,
  get_current_submap = function() return current_submap end,
  is_key_down = function(keycode)
    expect(type(keycode) == "number", "watchdog used a string keysym")
    return pressed_keycodes[keycode] == true
  end,
  on = function(event, callback) events[event] = callback end,
  timer = function(callback, options)
    expect(options.timeout == 100, "unexpected watchdog interval")
    expect(options.type == "repeat", "watchdog is not repeating")
    watchdog = {
      callback = callback,
      enabled = true,
      set_enabled = function(self, enabled) self.enabled = enabled end
    }
    return watchdog
  end
}

dofile(arg[1])

local main_forward = bindings["|SUPER + TAB"]
local submap_forward = bindings["reomarchy-workspace-switcher|SUPER + TAB"]
local submap_reverse = bindings["reomarchy-workspace-switcher|SUPER + SHIFT + TAB"]
local submap_escape = bindings["reomarchy-workspace-switcher|escape"]
expect(type(main_forward) == "function", "main forward binding missing")
expect(type(submap_forward) == "function", "submap forward binding missing")
expect(type(submap_reverse) == "function", "submap reverse binding missing")
expect(type(submap_escape) == "function", "submap escape binding missing")
expect(not watchdog.enabled, "watchdog starts enabled")

pressed_keycodes[133] = true
main_forward()
expect(current_submap == "reomarchy-workspace-switcher", "switcher submap was not entered")
expect(watchdog.enabled, "watchdog was not enabled")
expect(commands[#commands]:find('"direction":1', 1, true), "forward summon missing")

submap_reverse()
expect(commands[#commands]:find('"direction":-1', 1, true), "reverse summon missing")

events["input.keyboard.key"](133, nil, 0)
pressed_keycodes[133] = false
expect(current_submap == "default", "normal release did not reset the submap")
expect(not watchdog.enabled, "normal release did not stop the watchdog")
expect(commands[#commands]:find('"commit":true', 1, true), "normal release did not commit")

pressed_keycodes[134] = true
main_forward()
submap_escape()
pressed_keycodes[134] = false
expect(current_submap == "default", "escape did not reset the submap")
expect(not watchdog.enabled, "escape did not stop the watchdog")
expect(commands[#commands]:find(" shell hide ", 1, true), "escape did not hide the switcher")

pressed_keycodes[133] = true
main_forward()
pressed_keycodes[133] = false
watchdog.callback()
expect(current_submap == "default", "watchdog did not reset the submap")
expect(not watchdog.enabled, "watchdog did not stop itself")
expect(commands[#commands]:find('"commit":true', 1, true), "watchdog did not commit")

print("binding tests: pass")
