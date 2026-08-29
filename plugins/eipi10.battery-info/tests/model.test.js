const assert = require("node:assert/strict")
const model = require("../Model.js")

function close(actual, expected, epsilon = 1e-9) {
  assert.ok(Math.abs(actual - expected) <= epsilon, `${actual} != ${expected}`)
}

function localTimestamp(year, month, day, hour, minute = 0) {
  return new Date(year, month - 1, day, hour, minute).getTime() / 1000
}

// Corrupt or structurally invalid history must be rejected, never normalized
// to an empty-but-valid payload that could overwrite the original file.
assert.equal(model.parseHistory("{broken").valid, false)
assert.equal(model.normalizeHistory({ version: 4 }).valid, false)

const normalized = model.normalizeHistory({
  version: 3,
  days: {
    "2026-08-29": { system: 12.5, drained: -4, charged: "2.5" },
    garbage: { system: 99 }
  },
  last: { ts: 100, energy: 50, state: "Charging", rapl: 200, raplNode: "psys" }
})
assert.equal(normalized.valid, true)
assert.deepEqual(normalized.days, {
  "2026-08-29": { drained: 0, charged: 2.5, system: 12.5 }
})

// A measurement spanning midnight is distributed by elapsed time.
const split = model.splitAmountByDay(
  localTimestamp(2026, 8, 28, 23),
  localTimestamp(2026, 8, 29, 1),
  20
)
assert.equal(split.length, 2)
assert.equal(split[0].key, "2026-08-28")
assert.equal(split[1].key, "2026-08-29")
close(split[0].amount, 10)
close(split[1].amount, 10)

// UPower samples arrive newest-first. One 10% discharge and one 20% charge on
// a 50 Wh battery recover to 5 Wh drained and 10 Wh charged.
const upowerPayload = JSON.stringify({
  type: "a(udu)",
  data: [[
    [localTimestamp(2026, 8, 29, 12), 60, 1],
    [localTimestamp(2026, 8, 29, 11), 40, 2],
    [localTimestamp(2026, 8, 29, 10), 50, 2]
  ]]
})
const recovered = model.recoverUPowerHistory(upowerPayload, 50)
close(recovered["2026-08-29"].drained, 5)
close(recovered["2026-08-29"].charged, 10)
assert.equal(recovered["2026-08-29"].batteryEstimated, true)

const merged = model.mergeRecoveredBatteryHistory({
  "2026-08-28": { system: 20, drained: 0, charged: 0 },
  "2026-08-29": { system: 30, drained: 4, charged: 3 }
}, {
  "2026-08-28": { drained: 5, charged: 6, batteryEstimated: true },
  "2026-08-29": { drained: 50, charged: 60, batteryEstimated: true }
})
assert.equal(merged["2026-08-28"].drained, 5)
assert.equal(merged["2026-08-28"].batteryEstimated, true)
assert.equal(merged["2026-08-29"].drained, 4)
assert.equal(merged["2026-08-29"].batteryEstimated, undefined)

// Zhuhai summer: first 260 kWh at base, next 340 at base + ¥0.05, then
// base + ¥0.30. Non-summer thresholds are 200/400 kWh.
const base = model.ZHUHAI_BASE_RATE
close(
  model.zhuhaiCostAtTotal(700, new Date(2026, 7, 1), base),
  260 * base + 340 * (base + 0.05) + 100 * (base + 0.30)
)
close(
  model.zhuhaiCostAtTotal(500, new Date(2026, 10, 1), base),
  200 * base + 200 * (base + 0.05) + 100 * (base + 0.30)
)

// A day's device use crossing the household's first-tier threshold is priced
// marginally instead of multiplying the whole day by one flat rate.
close(
  model.zhuhaiIncrementalCost(250, 20, new Date(2026, 7, 1), base),
  10 * base + 10 * (base + 0.05)
)

const days = {
  "2026-08-28": { system: 10000, drained: 2, charged: 3 },
  "2026-08-29": { system: 20000, drained: 4, charged: 5 }
}
close(model.dayElectricityCost(days, "2026-08-29", "system", base, 250), 20 * (base + 0.05))
close(model.rangeElectricityCost(days, "2026-08-28", "2026-08-29", "system", base, 250), 10 * base + 20 * (base + 0.05))
assert.ok(Number.isNaN(model.dayElectricityCost(days, "2026-08-27", "system", base, 0)))
assert.equal(model.formatWh(NaN), "—")

console.log("battery-info model tests passed")
