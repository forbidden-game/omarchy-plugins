# Qwen ASR (qwen-asr)

Push-to-talk **Qwen Audio 3.0** speech-to-text recognition widget for the [Omarchy](https://omarchy.org/) shell bar.

Hold to record with a responsive real-time audio waveform level meter, release to automatically transcribe your voice into the system clipboard.

## Features

- **Push-to-Talk Anywhere**: Global hotkey support (default `F9` or customizable keyboard/mouse bindings) or press-and-hold on the bar icon.
- **Interactive Shortcut & Mouse Side Button Capture**: Directly configure, record, and switch push-to-talk hotkeys from the panel (supports `F9`, keyboard combos, mouse side buttons `mouse:275` / `mouse:276`, and mouse middle click).
- **Dynamic Acoustic Level Meter**: Live acoustic amplitude animation with DC bias calibration and noise floor suppression.
- **Non-blocking Transcription**: Asynchronous pipeline invoking local or remote Qwen Audio ASR models.
- **Timing Diagnostics**: Records local stage timings, cloud request latency, HTTP status, request IDs, and automatic retries without storing secrets or transcript content in the diagnostic log.
- **Direct Clipboard Integration & Auto-paste**: Transcribed Chinese/English speech is instantly typed directly into your active window or copied to your clipboard.

## Installation

```bash
./install.sh qwen-asr
omarchy-shell shell rescanPlugins
```

## Usage & Hotkeys

- **Bar Action**: Click and hold the microphone icon in the bar to start recording; release when finished speaking.
- **Global Keybinding**: Bind a Hyprland key (e.g. `bind = , F9, ...`) to trigger speech recognition globally.

## Diagnostics

Timing records are appended as JSON Lines to:

```text
~/.local/share/XiezhaoPan/qwen-asr-qt/diagnostics.jsonl
```

Each transcription receives a trace ID. The log separates audio conversion,
speech probing, Base64 encoding, every cloud request, automatic retry, and the
complete pipeline. It never writes the API key, audio payload, or transcript
text.

## Prerequisites

- `sox` / `arecord` or PipeWire recording backend
- Qwen Audio 3.0 inference backend service running locally or on LAN

## License

MIT License (c) 2026 Xiezhao Pan
