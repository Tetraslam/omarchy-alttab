# Alt+Tab for Omarchy

The Windows Alt+Tab, done properly on Omarchy Quattro.

- **Tap** Alt+Tab to flip to the previous window. No panel, no flash.
- **Hold** Alt and a frosted panel shows every window as a live thumbnail with its icon and title, in most-recently-used order across all workspaces, starting on the previous window.
- **Tab / Shift+Tab** (Alt still held) and the **arrow keys** move the selection; **release Alt** to switch.
- **Enter** or a **click** switches, **Esc** or a click outside goes back, **Delete**, a **middle click** or the **✕** closes a window and the grid reflows.
- The layout is fixed while the panel is open: tiles keep their window's shape, share one height, and wrap into centered rows, so only the highlight moves.
- Leaving a fullscreen game parks it in fake fullscreen (it keeps its resolution and doesn't minimize); switching back restores real fullscreen.

## Why it's fast

Nothing starts on the hot path. The overlay is mapped the instant Alt+Tab is pressed and only drawn after 80 ms, so a tap never flashes it and a hold reveals thumbnails that are already streaming. Each recent window keeps one capture view for its whole life, so opening the panel resumes captures instead of negotiating new ones, and a window Hyprland can't capture right now (another workspace, scrolled away) shows the frame taken when it last had focus. Recency comes from compositor events as they happen; nothing is queried when the chord fires.

## Install

Requires Omarchy Quattro (Hyprland 0.56+ with the Lua config).

```bash
omarchy plugin add https://github.com/tetraslam/omarchy-alttab --enable
```

Then give it Alt+Tab by adding this block at the end of `~/.config/hypr/bindings.lua`:

```lua
-- alttab: begin
do
  local alttab = os.getenv("HOME") .. "/.config/omarchy/plugins/tetraslam.alttab/hypr/alttab.lua"
  local file = io.open(alttab, "r")
  if file then
    file:close()
    pcall(dofile, alttab)
  end
end
-- alttab: end
```

Hyprland reloads on save. The block does nothing while the plugin is missing or disabled, so Omarchy's own Alt+Tab comes back by itself.

`omarchy-shell alttab open` opens the panel without holding Alt (Enter or a click to switch). Bind it to a free chord if you want Windows' Ctrl+Alt+Tab; Omarchy already uses that one for monitor focus.

## Notes

- Releasing Alt is read from Hyprland's raw key stream, because a release bind on a bare modifier only fires when the modifier is tapped alone. The approach comes from [Fathom](https://github.com/mtolhuys/fathom) and altswitch.
- The 12 most recently used windows keep their last frame between openings (`warmWindows` in `AltTab.qml`); older ones reconnect when the panel opens.
- `omarchy-shell alttab state` prints recency and capture state for debugging.

## License

MIT
