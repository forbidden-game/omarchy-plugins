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
   OAuth credentials. Omarvoice pins one account by `voice_account_id`, so
   native Antigravity App account switches do not change dictation identity.
4. The pinned credential is refreshed only near expiry and staged in a
   private file-token home used solely by Omarvoice's language server. That
   process cannot access the desktop Secret Service, so it never overwrites
   the native App's single system-keyring entry.

The service starts Antigravity's language server without the Electron UI and
keeps the cloud transcription session active while audio arrives. OAuth
material is never placed in QML, command-line arguments, transcript history,
or diagnostics. The isolated token file, runtime state, and Unix socket are
private to the desktop user.

Every transcription session includes a short, static recognition profile for
mainland-Chinese names, places, organizations, and current expressions, plus
Chinese-English software-development terminology. It asks the provider to
preserve standard English spelling, capitalization, and abbreviations while
limiting edits to contextual punctuation, sentence boundaries, and word order.
Caller-provided cursor context is appended to this profile rather than
replacing it. The profile contains no clipboard, document, account, or device
data.

## Installation

For a fresh machine, the repository-level portable setup installs
dependencies, Antigravity, Agent Panel, Omarvoice, browser authorization,
shortcut, and service warmup in one flow:

```bash
./setup-omarvoice.sh
```

See `docs/omarvoice-portable-setup.md` at the repository root for the complete
new-machine and update procedures.

For manual installation:

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

Antigravity dictation requires the Google OAuth scope
`https://www.googleapis.com/auth/aicode`. Pin a registered account with:

```bash
~/.config/omarchy/plugins/eipi10.agents/bin/omarchy-antigravity-ctl \
  voice-bind <account-id>
```

Omarvoice does not expose a second browser-login path. If the pinned account
was authorized before the `aicode` scope was added, reauthorize that account
from Agent Panel and then refresh Omarvoice's status row.

## Usage

- Hold the bar microphone button and release to transcribe.
- The default global push-to-talk shortcut is `F9`; keyboard combinations and
  supported mouse buttons can be captured in the panel.
- Turn off **自动直接上屏** to copy without pasting.
- If Omarchy Shell reloads during capture, Omarvoice stops the detached
  recording and keeps its recovery WAV. A five-minute service-side limit is
  the final guard against an indefinitely open microphone.
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
