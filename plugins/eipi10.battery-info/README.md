# Battery Info (eipi10.battery-info)

Live battery flow, whole-system energy history, and estimated Zhuhai
residential electricity cost for the [Omarchy](https://omarchy.org/) desktop
shell.

## Features

- Correctly derives charge/discharge direction from UPower state. UPower's
  `EnergyRate` is a magnitude, not a signed value.
- Tracks separate daily buckets for whole-system energy, battery discharge,
  and battery charge.
- Shows today, calendar-week, calendar-month, and the last seven individual
  days. Missing observations are shown as `—`; a measured zero stays `0 Wh`.
- Persists 400 days in
  `$XDG_STATE_HOME/omarchy/battery-info/history.json`, using atomic writes and
  a `history.json.bak` safety copy. Multi-monitor instances and hot-reload
  generations are serialized so they cannot race over one temporary file.
- Refuses to overwrite malformed or unreadable history.
- Uses UPower's retained percentage history to recover up to 40 days of
  approximate charge/discharge data. Recovered rows are marked `*`; past
  whole-system energy cannot be reconstructed and remains `—`.
- Calculates marginal daily/weekly/monthly device cost with Zhuhai's standard
  one-household residential three-tier tariff.

## Electricity-cost model

The default base rate is **¥0.60886875/kWh**. From May through October, the
first/second tier boundaries are 260/600 kWh per household-month; in the other
months they are 200/400 kWh. Tier 2 adds ¥0.05/kWh and tier 3 adds
¥0.30/kWh.

The displayed amount is a **device estimate**, not the utility bill: RAPL
measures this computer rather than the household meter, and charger conversion
losses or other appliances are not observable. Set `monthlyBaselineKWh` to the
household's other month-to-date use when the computer should be priced at the
same marginal tier as the meter.

References:

- [Guangdong residential tier policy](https://drc.gd.gov.cn/gfxwj5633/content/post_864609.html)
- [Government response quoting China Southern Power Grid's Zhuhai rates](https://www.hhhk.gov.cn/info/2651/274321.htm)

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
  "showPercentage": true,
  "tariffBaseRate": 0.60886875,
  "monthlyBaselineKWh": 0
}
```

`monthlyBaselineKWh` defaults to zero, which prices the tracked computer as a
standalone load. The value can be updated during the month from the household
meter or electricity account.

## Verification

```bash
node plugins/eipi10.battery-info/tests/model.test.js
bash plugins/eipi10.battery-info/tests/persist-history.test.sh
omarchy plugin validate plugins/eipi10.battery-info
```

## License

MIT License (c) 2026 Xiezhao Pan
