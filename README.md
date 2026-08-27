# Omarchy Plugins Collection

A curated collection of modern, native, and high-efficiency shell plugins and bar widgets for the [Omarchy](https://omarchy.org/) desktop environment (built with Quickshell, QML, and Linux system telemetry).

All plugins are designed with strict performance budgets, zero-slop UI aesthetics, non-blocking asynchronous sampling, and complete dark/light design token adherence.

---

## 📦 Plugin Matrix

| Plugin ID | Name | Category | Description | Source |
| :--- | :--- | :--- | :--- | :--- |
| **`eipi10.agents`** | **My Agents** | `AI` | Comprehensive usage, rate limits, pace tracking, and KV cache stats for Claude Code, Codex, Antigravity, and Fireworks. | [`plugins/eipi10.agents/`](plugins/eipi10.agents/) |
| **`eipi10.cpu-ram`** | **CPU & RAM** | `System` | Real-time CPU, RAM, Swap, CPU temperature meters with per-core usage & top resource-consuming processes popup. | [`plugins/eipi10.cpu-ram/`](plugins/eipi10.cpu-ram/) |
| **`eipi10.battery-info`** | **Battery Info** | `System` | Live battery charging/discharging wattage, battery state indicators, and daily/weekly/monthly energy consumption metrics. | [`plugins/eipi10.battery-info/`](plugins/eipi10.battery-info/) |
| **`qwen-asr`** | **Qwen ASR** | `Utility` | Push-to-talk Qwen Audio 3.0 speech recognition with acoustic level visualizer, global `F9` keybinding, and clipboard output. | [`plugins/qwen-asr/`](plugins/qwen-asr/) |
| **`eipi10.netrate`** | **Network Rate** | `Network` | Ultra-lightweight, zero-jitter network upload and download speed monitor sampled directly from `/sys/class/net`. | [`plugins/eipi10.netrate/`](plugins/eipi10.netrate/) |
| **`eipi10.365vpn`** | **365VPN** | `Network` | Native bar status for the official 365VPN client: shows connection state (connected/open/ready/stopped/missing) and launches the vendor GUI. | [`plugins/eipi10.365vpn/`](plugins/eipi10.365vpn/) |

---

## 🚀 Quick Start & Installation

### 1. Clone the repository

On this machine the repository lives inside the `omarchy_plugins` workspace:

```bash
git clone https://github.com/forbidden-game/omarchy-plugins.git ~/work/projects/omarchy_plugins/omarchy-plugins
cd ~/work/projects/omarchy_plugins/omarchy-plugins
```

Anywhere else works too — `install.sh` resolves its own location.

### 2. Install all plugins (via Symlink)

Use the provided `install.sh` helper to symlink the plugins into your local Omarchy plugins directory (`~/.config/omarchy/plugins/`):

```bash
./install.sh all
```

Or install a specific plugin:

```bash
./install.sh eipi10.agents
```

### 3. Reload or Restart Shell

```bash
# Lightweight rescan and config reload
omarchy-shell shell rescanPlugins
omarchy-shell shell reloadConfig

# Full restart (recommended when updating complex widgets, singletons, or dependencies)
omarchy restart shell
```

---

## ⚙️ Enabling & Configuring Plugins

Enable any installed plugin into your status bar (left, center, or right section):

```bash
# Enable My Agents in right section
omarchy plugin enable eipi10.agents right

# Enable CPU & RAM in right section
omarchy plugin enable eipi10.cpu-ram right

# Enable Qwen ASR in center section
omarchy plugin enable qwen-asr center
```

Configurations are stored declaratively in `~/.config/omarchy/shell.json`. Refer to each plugin's individual `README.md` in `plugins/<plugin-id>/` for detailed options and schema keys.

---

## 🛠️ Related Projects

- **[Macro IME](https://github.com/forbidden-game/macro-ime)** — A modern Chinese IME ecosystem for Wayland & Omarchy with deep Quickshell integration and custom language models.

---

## 📄 License

All plugins in this repository are licensed under the [MIT License](LICENSE).  
Copyright (c) 2026 Xiezhao Pan.
