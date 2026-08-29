# Touchpad

A native Omarchy bar panel for the touchpad settings people change most:
scroll direction and speed, taps, physical-click behavior, dragging, typing
protection, and touchpad-only pointer speed.

The panel is built around a reversible workflow. Every edit previews
immediately through Hyprland. **Save** persists it; **Revert** or closing the
panel restores the snapshot captured when the panel opened.

## Product shape

- **Typing, Balanced, and Gesture presets** provide useful starting points
  without hiding the individual values they change.
- **Scrolling** contains natural scrolling and a `0.10×–2.00×` multiplier.
- **Clicking & Dragging** contains tap-to-click, finger-count versus button-area
  physical clicks, tap-and-drag, and off/timeout/sticky drag lock.
- **Control** contains typing protection and a per-touchpad pointer-speed
  slider. External mice are not changed.
- **Try it here** receives real post-libinput clicks and scroll events so a
  preview can be evaluated before saving.
- **Omarchy defaults** removes only the plugin-managed override block; it does
  not replace the rest of `~/.config/hypr/input.lua`.

Workspace gestures and three-finger drag are intentionally outside version
1. They are useful, but they can collide with existing gesture and window
management choices and deserve a separate conflict-aware workflow.

See [the design rationale](docs/design.md) for the information architecture,
state model, and rejected alternatives.

## Install

From the collection root:

```bash
./install.sh eipi10.touchpad
omarchy-shell shell rescanPlugins
omarchy plugin enable eipi10.touchpad right
```

The plugin requires Omarchy's Lua-based Hyprland configuration (Hyprland
0.55 or newer), `hyprctl`, Python 3, and a running Hyprland session.

## Persistence and recovery

Saving appends one marked block to `~/.config/hypr/input.lua`:

```lua
-- BEGIN eipi10.touchpad (managed by the Touchpad plugin)
-- ...
-- END eipi10.touchpad
```

The controller:

1. preserves all content outside that block;
2. writes atomically;
3. reloads Hyprland and checks `hyprctl configerrors`;
4. restores the previous file automatically if validation fails; and
5. keeps the first pre-plugin snapshot at
   `~/.config/hypr/input.lua.eipi10-touchpad.bak`.

The backup is a recovery aid. The panel's **Omarchy defaults** action is more
precise for normal use because it removes only the managed block and preserves
later user edits.

## Controller

The QML panel talks to a JSON-only helper:

```bash
bin/omarchy-touchpad-ctl status
bin/omarchy-touchpad-ctl presets --pretty
bin/omarchy-touchpad-ctl preview --json '{"naturalScroll":true,...}'
bin/omarchy-touchpad-ctl apply --json '{"naturalScroll":true,...}'
bin/omarchy-touchpad-ctl reset
```

For tests, `OMARCHY_TOUCHPAD_INPUT_FILE` can redirect the config target and
`HYPRCTL` can select a fake controller binary.

## Keyboard

- `j` / `k` or `↓` / `↑`: move between controls
- `h` / `l` or `←` / `→`: adjust a slider or segmented choice
- `Enter` / `Space`: activate the selected control
- `s`: save
- `r`: rescan devices
- `Esc`: close and discard an unsaved preview

## Test

```bash
python3 -m unittest discover -s plugins/eipi10.touchpad/tests -v
omarchy plugin validate plugins/eipi10.touchpad
```
