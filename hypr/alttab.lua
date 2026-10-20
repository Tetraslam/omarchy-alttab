-- Alt+Tab keybindings for Hyprland 0.56+ (Lua config).
--
-- Load from ~/.config/hypr/bindings.lua with the guarded block in README.md.
-- Alt+Tab and Alt+Shift+Tab step the switcher through Hyprland global
-- shortcuts (no process per keypress), and a raw key hook reports when Alt is
-- let go, which is what commits the switch. A release bind on a bare modifier
-- only fires when the modifier was tapped alone, so the key stream is read
-- instead (the approach Fathom and altswitch use).
--
-- Nothing here is ever torn down: removing a keybind from Lua could crash
-- Hyprland 0.56.2, so loading twice in one Lua state is a no-op and a change
-- is picked up by `hyprctl reload`.

if rawget(_G, "__alttab") then
  return true
end

-- Only while the shell has the plugin enabled; `omarchy plugin disable` and
-- `remove` drop it from shell.json, and Omarchy's own Alt+Tab stays.
local function enabled()
  local file = io.open((os.getenv("HOME") or "") .. "/.config/omarchy/shell.json", "r")
  if not file then
    return true
  end
  local text = file:read("a") or ""
  file:close()
  return text:find('"tetraslam.alttab"', 1, true) ~= nil
end

if not enabled() then
  return false
end

local state = { holding = false, alt = {}, down = {} }
_G.__alttab = state

local function send(name)
  hl.dispatch(hl.dsp.global("alttab:" .. name))
end

-- Key codes that can act as Alt: 64/108 are left/right Alt; 133/134 Super and
-- 37/105 Control can become Alt through XKB options. Whichever of them is down
-- when the chord fires is the Alt in use, so its release commits.
local MAY_BE_ALT = { [37] = true, [64] = true, [105] = true, [108] = true, [133] = true, [134] = true }

local function chord(name)
  return function()
    if not state.holding then
      state.holding = true
      state.alt = { [64] = true }
      for code in pairs(state.down) do
        if code ~= 37 and code ~= 105 then
          state.alt[code] = true
        end
      end
    end
    send(name)
  end
end

hl.on("input.keyboard.key", function(keycode, _, pressed)
  if MAY_BE_ALT[keycode] then
    state.down[keycode] = pressed ~= 0 or nil
  end
  if pressed == 0 and state.holding and state.alt[keycode] then
    state.holding = false
    send("release")
  end
end)

-- The overlay closing on its own (Escape, a click) ends the hold as well.
hl.on("layer.closed", function(layer)
  if layer and layer.namespace == "alttab" then
    state.holding = false
  end
end)

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.bind("ALT + TAB", chord("next"), { description = "Switch windows", repeating = true })
hl.bind("ALT + SHIFT + TAB", chord("previous"), { description = "Switch windows (reverse)", repeating = true })

-- Show the panel at once and frost what is behind it. Cosmetic, so a renamed
-- field must not cost the bindings above.
pcall(hl.layer_rule, {
  name = "alttab",
  match = { namespace = "^alttab$" },
  no_anim = true,
  blur = true,
  ignore_alpha = 0.2,
})

return true
