# Discuss

Discuss turns selected text from any Wayland application into a sequence of
paired notes:

```
selection 01 → your discussion 01
selection 02 → your discussion 02
...
```

It does not call an AI service. Clicking **确认本轮 · 复制** freezes the current
round as an in-memory snapshot, writes it to the clipboard as readable Markdown,
and starts a fresh round. Clipboard export does not wait for draft persistence.
The final discussion may be empty.

## Interaction

1. Select text in any application.
2. Press `Super + D`.
3. Write a comment in the current pair.
4. Select more text elsewhere and press `Super + D` again.
5. Click **确认本轮 · 复制** or press `Ctrl + Enter`.

Every new capture collapses the previous pair and keeps the newest pair open.
One historical pair can be expanded at a time. The footer remains fixed while
the pair list scrolls inside the resizable window. `Esc` and **隐藏** only hide
the window; they do not discard the draft.

## Installation

From the repository root:

```bash
./install.sh eipi10.discuss
omarchy restart shell
omarchy plugin enable eipi10.discuss
```

Add the following to `~/.config/hypr/bindings.lua`:

```lua
local discuss_ctl = (os.getenv("HOME") or "") ..
  "/.config/omarchy/plugins/eipi10.discuss/bin/discuss-ctl"
o.bind("SUPER + D", "Discuss selected text", discuss_ctl .. " capture")
```

Keep the window floating by adding an exact-title rule to
`~/.config/hypr/hyprland.lua`:

```lua
o.window({ class = "^org\\.quickshell$", title = "^Discuss$" }, {
  float = true,
  center = true,
})
```

Then validate the Hyprland configuration:

```bash
hyprctl reload
hyprctl configerrors
```

## Clipboard output

Each pair is kept together:

```markdown
> **引用 01 · firefox · Article title**
>
> Selected text

**我的讨论：**
My response
```

Pairs are separated with a Markdown horizontal rule.

## Dependencies

- Omarchy Shell / Quickshell
- Hyprland (`hyprctl`)
- `wl-clipboard` (`wl-paste` and `wl-copy`)
- Python 3

## State and privacy

Drafts live at:

```text
${XDG_STATE_HOME:-~/.local/state}/omarchy/discuss/draft.json
```

Captured selections first pass through private, one-shot JSON files in the
adjacent `inbox/` directory. Directories use mode `0700`, records use `0600`,
and an inbox record is deleted as soon as the panel consumes it. No content is
sent over the network.

## Verification

```bash
omarchy plugin validate plugins/eipi10.discuss
python -m unittest discover -s plugins/eipi10.discuss/tests -v
qmllint -I /usr/share/omarchy/shell \
  plugins/eipi10.discuss/Discuss.qml \
  plugins/eipi10.discuss/components/DiscussionPair.qml
```
