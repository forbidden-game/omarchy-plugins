# Network Rate (eipi10.netrate)

A lightweight, zero-flicker live network throughput widget for the [Omarchy](https://omarchy.org/) shell bar.

## Features

- **Split Sampling Engine**:
  - Slow poll (30s) detects interface changes via `ip -j route get`.
  - Fast poll (1s) reads rx/tx bytes directly from `/sys/class/net/<iface>/statistics/` with no heavy process forks.
- **Constant-Width Anti-Jitter**: Monospace label layout with dynamic unit normalization (`K`, `M`, `G`, `T`) ensuring the bar width never twitches during high bandwidth spikes.
- **Tooltip Details**: Displays active interface name and cumulative downloaded/uploaded data volumes.

## Installation

```bash
./install.sh eipi10.netrate
omarchy-shell shell rescanPlugins
```

## Configuration

Add to `~/.config/omarchy/shell.json` in your preferred section (e.g. `right`):

```json
{
  "id": "eipi10.netrate"
}
```

## License

MIT License (c) 2026 Xiezhao Pan
