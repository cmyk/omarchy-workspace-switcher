# Omarchy Workspace Switcher

A Mac-style visual workspace switcher for Omarchy. It presents occupied
Hyprland workspaces as miniature layouts, cycles while Command/Super is held,
and activates the selection when the modifier is released.

## Install

```bash
omarchy plugin add https://github.com/cmyk/omarchy-workspace-switcher.git --enable
```

Add bindings to `~/.config/hypr/bindings.lua` or another user-loaded Lua file:

```lua
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
o.bind("SUPER + TAB", "Visual workspace switcher", "omarchy-shell shell summon reomarchy.workspace-switcher '{\"direction\":1}'")
o.bind("SUPER + SHIFT + TAB", "Visual workspace switcher (reverse)", "omarchy-shell shell summon reomarchy.workspace-switcher '{\"direction\":-1}'")
```

The stock bindings previously assigned these keys to immediate next/previous
workspace switching.
