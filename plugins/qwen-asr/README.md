# Qwen ASR (qwen-asr)

Push-to-talk **Qwen Audio 3.0** speech-to-text recognition widget for the [Omarchy](https://omarchy.org/) shell bar.

Hold to record with a responsive real-time audio waveform level meter, release to automatically transcribe your voice into the system clipboard.

## Features

- **Push-to-Talk Anywhere**: Global hotkey support (default `F9`) or press-and-hold on the bar icon.
- **Dynamic Acoustic Level Meter**: Live acoustic amplitude animation with DC bias calibration and noise floor suppression.
- **Non-blocking Transcription**: Asynchronous pipeline invoking local or remote Qwen Audio ASR models.
- **Direct Clipboard Integration**: Transcribed Chinese/English speech is instantly copied to your Wayland clipboard ready to paste into any editor, terminal, or chat window.

## Installation

```bash
./install.sh qwen-asr
omarchy-shell shell rescanPlugins
```

## Usage & Hotkeys

- **Bar Action**: Click and hold the microphone icon in the bar to start recording; release when finished speaking.
- **Global Keybinding**: Bind a Hyprland key (e.g. `bind = , F9, ...`) to trigger speech recognition globally.

## Prerequisites

- `sox` / `arecord` or PipeWire recording backend
- Qwen Audio 3.0 inference backend service running locally or on LAN

## License

MIT License (c) 2026 Xiezhao Pan
