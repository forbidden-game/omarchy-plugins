# Battery Info (eipi10.battery-info)

Live battery charging/discharging power, level percentage, and daily/weekly/monthly historical power consumption statistics for the [Omarchy](https://omarchy.org/) desktop shell.

## Features

- **Live Power Monitoring**: Accurately displays charging (+) or discharging (-) wattage in real time sampled directly from `/sys/class/power_supply/`.
- **Health & Consumption Breakdown**:
  - Today's total energy used (Wh)
  - Last 7 days energy metrics
  - 30-day running battery cycle estimations
- **Omarchy Design Tokens**: Automatically inherits system color schemes, typography, and dark/light palettes seamlessly without visual glitches.
- **Adaptive Display**: Automatically changes icon color/state based on charging thresholds and low battery warnings.

## Installation

Inside the `omarchy-plugins` repository root:

```bash
./install.sh eipi10.battery-info
omarchy-shell shell rescanPlugins
```

## Configuration

Settings can be customized directly in `~/.config/omarchy/shell.json` under the widget definition:

```json
{
  "id": "eipi10.battery-info",
  "showPercentage": true
}
```

## License

MIT License (c) 2026 Xiezhao Pan
