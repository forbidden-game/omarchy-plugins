# Omarvoice (`qwen-asr`)

Omarvoice is push-to-talk dictation for the Omarchy bar. Hold the microphone
button or global shortcut, speak, then release: Omarvoice streams 16 kHz PCM
to Antigravity Cloud and pastes the transcript into the focused application.

The plugin id remains `qwen-asr` so existing bar layouts, IPC commands,
shortcuts, settings, history, and runtime symlinks keep working.

## Architecture

The transcription path is intentionally split into three readable boundaries:

1. QML owns push-to-talk state, the live level meter, clipboard, and history.
2. A private per-user `omarvoice-antigravity` service keeps Antigravity's
   language server warm. It captures 16 kHz mono PCM in 200 ms chunks, saves a
   recovery WAV, and streams those chunks while the user is still speaking.
3. Agent Panel remains the only owner of the account index and long-lived
   OAuth credential. It refreshes only near token expiry and synchronizes
   Antigravity's system-keyring entry without returning a token to Omarvoice.

The service starts Antigravity's language server without the Electron UI and
keeps the cloud transcription session active while audio arrives. OAuth
material is never placed in QML, command-line arguments, transcript history,
or diagnostics. Runtime state and the Unix socket are private to the desktop
user.

## Installation

```bash
./install.sh eipi10.agents
./install.sh qwen-asr
omarchy-shell shell rescanPlugins
```

Prerequisites:

- Antigravity 2.11 or newer installed at `/opt/Antigravity`
- an Antigravity account configured in the `eipi10.agents` Agent Panel
- `pw-record`, `secret-tool`, `wl-copy`, and `wtype`

`ffmpeg` is needed only by the backward-compatible `transcribe <wav>` CLI,
not by the live push-to-talk path.

Antigravity dictation adds the Google OAuth scope
`https://www.googleapis.com/auth/aicode`. Accounts authorized before this
change need one explicit reauthorization. Open the Omarvoice panel, choose
**重新授权**, complete the browser login, and the readiness row will refresh
automatically.

## Usage

- Hold the bar microphone button and release to transcribe.
- The default global push-to-talk shortcut is `F9`; keyboard combinations and
  supported mouse buttons can be captured in the panel.
- Turn off **自动直接上屏** to copy without pasting.
- IPC compatibility is unchanged:

```bash
omarchy-shell qwen-asr start
omarchy-shell qwen-asr stop
omarchy-shell qwen-asr status
```

## Diagnostics and data

Existing storage paths are retained for a no-loss migration:

```text
~/.config/XiezhaoPan/qwen-asr-qt.conf
~/.local/share/XiezhaoPan/qwen-asr-qt/transcripts.txt
~/.local/share/XiezhaoPan/qwen-asr-qt/diagnostics.jsonl
~/.local/share/XiezhaoPan/qwen-asr-qt/recordings/
```

Any legacy `apiKey` entry in the settings file is ignored and never loaded by
Omarvoice.

Diagnostics contain service warmup, session-ready, release-to-final, provider
outcome, audio byte, and request-count timings. They never contain OAuth
credentials, audio payloads, or transcript text.

## License

MIT License (c) 2026 Xiezhao Pan
