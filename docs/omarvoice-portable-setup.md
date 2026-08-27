# Portable Omarvoice setup

Omarvoice is deployed as reproducible code plus machine-local authorization:

- Git provides the Agent Panel, Omarvoice, the streaming bridge, tests, and the
  Chinese developer recognition profile.
- Omarchy installs the desktop/audio dependencies.
- The Antigravity AUR package provides the supported `language_server`.
- Each machine completes its own Google browser authorization and stores its
  own refresh token and keyring entry.

No access token or refresh token is copied between machines.

## New machine

Run this from an interactive terminal inside the logged-in Omarchy desktop:

```bash
omarchy pkg add git
git clone \
  https://github.com/forbidden-game/omarchy-plugins.git \
  ~/.local/share/omarvoice
~/.local/share/omarvoice/setup-omarvoice.sh
```

The setup performs these steps:

1. Installs `pipewire-audio`, `libsecret`, `wl-clipboard`, `wtype`, Python,
   Git, and jq through Omarchy.
2. Installs Antigravity from the AUR when it is missing and requires version
   2.11 or newer.
3. Links `eipi10.agents` and `qwen-asr` into the user plugin directory.
4. Places Agent Panel on the right and Omarvoice in the center without moving
   an already-configured widget.
5. Creates the push-to-talk binding, defaulting to `F9`.
6. Extracts the supported OAuth client shipped in the installed Antigravity
   engine, using committed SHA-256 fingerprints to select the correct values.
7. Opens Google authorization in the default browser and waits on a
   loopback-only callback.
8. Stores the long-lived account credential with mode `0600`, synchronizes the
   native Antigravity token shape to the desktop keyring, warms Omarvoice, and
   runs an end-to-end local health check.

The repository contains only OAuth client fingerprints. It does not contain
the extracted client secret, account credentials, audio, transcripts, or
diagnostic data.

## Options

```bash
# Read-only verification
~/.local/share/omarvoice/setup-omarvoice.sh --check

# Install first and authorize later
~/.local/share/omarvoice/setup-omarvoice.sh --skip-auth

# Choose another push-to-talk shortcut
~/.local/share/omarvoice/setup-omarvoice.sh --shortcut "SUPER+V"

# Replace the current machine authorization
~/.local/share/omarvoice/setup-omarvoice.sh --reauthorize
```

## Updating

The checkout must remain on disk because the Omarchy plugins are symlinked to
it. Update and reconcile the machine with:

```bash
cd ~/.local/share/omarvoice
git pull --ff-only
./setup-omarvoice.sh
```

Running setup repeatedly is intentional. Package installation, plugin links,
bar placement, the managed shortcut block, OAuth client preparation, keyring
sync, and service warmup are all idempotent.

## Persisted state

These files stay local to each machine:

```text
~/.config/omarchy/agents/antigravity/accounts.json
~/.config/omarchy/agents/antigravity/accounts/
~/.config/omarchy/agents/antigravity/auth/
~/.config/omarchy/agents/antigravity/oauth.json
~/.config/XiezhaoPan/qwen-asr-qt.conf
~/.local/share/XiezhaoPan/qwen-asr-qt/
```

The authorization callback listens only on `127.0.0.1`, and OAuth material is
never passed through QML, command-line arguments, transcript history, or
diagnostic logs.

## Antigravity compatibility

The setup intentionally stops if a future Antigravity release contains an
unknown OAuth client. It never guesses between binary candidates. To support a
new release, verify its OAuth client against a working local installation and
add only the corresponding SHA-256 fingerprints to
`omarchy-antigravity-ctl`.

