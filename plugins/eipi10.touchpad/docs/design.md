# Touchpad product and UI/UX design

## Macro: what the plugin is

The plugin is a **small calibration tool**, not a second system-settings app.
Its job is to shorten the loop between changing a value and deciding whether
that value feels right:

```text
detect → choose a starting point → preview in place → test → save or revert
```

Three product principles drive the design:

1. **Feel before commit.** Touchpad values are experiential, so every edit is
   a live preview and persistence is a separate, explicit action.
2. **Safe by construction.** Closing discards an unsaved preview; saving owns
   one marked config block; validation failure rolls the file back.
3. **High-frequency settings only.** The panel remains scannable and avoids
   gesture policies that can silently conflict with the window manager.

The plugin deliberately does not expose a global “disable touchpad” switch.
On a laptop without a mouse that is an easy lockout. It also avoids applying
global pointer sensitivity, because that would unexpectedly change external
mice; speed is written per detected touchpad.

## Micro: information architecture

The panel is a single vertical reading path at a theme-scaled width of 420:

| Region | Purpose | Interaction |
| --- | --- | --- |
| Hero | Device identity and `SYSTEM` / `PREVIEW` / `SAVED` state | Read-only |
| Starting point | Typing, Balanced, Gesture | One click replaces the draft |
| Scrolling | Direction and multiplier | Toggle + continuous slider |
| Clicking & dragging | Tap, physical click model, drag, drag lock | Toggle + segmented choices |
| Control | Typing protection and touchpad-only pointer speed | Toggle + bipolar slider |
| Try it here | Validate post-libinput clicks and scroll | Direct input surface |
| Action row | Reset, Revert, Save | Explicit state transition |

Sections use typography and separators rather than nested cards. A bordered
surface appears only when it has interaction semantics: a setting row, slider,
choice group, or test target.

## Presets

Presets are visible starting points, not opaque modes. After selection, every
affected control updates immediately and remains editable.

| Preset | Intent | Important choices |
| --- | --- | --- |
| Typing | Minimize accidental input | physical click, no tap/drag, slower motion |
| Balanced | Everyday laptop use | taps and timed drag lock, moderate scrolling |
| Gesture | Touch-first navigation | natural scrolling, taps, timed drag lock |

Any manual adjustment changes the preset label to “Custom values.” This avoids
pretending a modified preset is still canonical.

## State model

```text
LOADING ──success──> READY
   │                  │  edit
   ├──no device──> EMPTY
   └──failure────> ERROR

READY ──edit──> PREVIEW ──Save──> SAVED
                  │
                  ├──Revert─────> READY
                  └──Close──────> READY
```

- **Loading:** animated theme-token skeleton bars reserve the final rhythm.
- **Empty:** the bar icon stays available, and the panel explains how to
  rescan. Hiding the icon would remove the recovery path.
- **Error:** the controller message appears in the panel with a retry action.
- **Preview:** the hero badge and bar icon communicate unsaved state.
- **Busy:** mutation controls stop accepting input while save/reset runs.
- **Success:** a short inline confirmation replaces toast noise.

## Input and accessibility

Pointer and keyboard share one cursor model:

- vertical movement walks controls;
- horizontal movement changes presets, sliders, and segmented choices;
- Enter/Space activates;
- Esc closes and rolls back unsaved runtime values.

Hover updates the same keyboard cursor instead of creating a second focus
model. Long device names elide in the hero. The panel uses a capped Flickable,
so scaled fonts and small screens remain usable.

## Technical boundary

QML never edits configuration text. It exchanges JSON with
`bin/omarchy-touchpad-ctl`, which owns:

- touchpad discovery;
- effective-value reads;
- Lua generation;
- live `hyprctl eval` previews;
- atomic persistence;
- Hyprland reload and `configerrors` validation;
- automatic rollback.

This boundary keeps both halves readable: QML expresses interaction and
Python expresses system invariants.

## Deferred work

- Conflict-aware workspace gesture setup
- Three- or four-finger drag with gesture collision detection
- Per-device profiles when multiple touchpads intentionally differ
- External-mouse-triggered enable/disable policy

These are valid features, but each adds policy or lifecycle behavior beyond a
common-settings panel.
