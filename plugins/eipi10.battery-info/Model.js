// Pure helpers for the battery-info widget: history validation and recovery,
// calendar aggregation, Zhuhai electricity pricing, icons, and formatting.
// There are no Quickshell imports, so this file remains easy to unit-test.

var ZHUHAI_BASE_RATE = 0.60886875
var ZHUHAI_TIER_2_SURCHARGE = 0.05
var ZHUHAI_TIER_3_SURCHARGE = 0.30

function pad2(n) {
  return n < 10 ? "0" + n : "" + n
}

function finiteNonNegative(value, fallback) {
  var n = Number(value)
  return isFinite(n) && n >= 0 ? n : Number(fallback || 0)
}

function hasOwn(object, key) {
  return !!object && Object.prototype.hasOwnProperty.call(object, key)
}

// Local-time ISO date key, e.g. "2026-08-15".
function todayKey(date) {
  var d = date || new Date()
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function dateFromKey(key) {
  var parts = String(key || "").split("-")
  if (parts.length !== 3) return null
  var date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  return isNaN(date.getTime()) ? null : date
}

function addDaysKey(key, amount) {
  var date = dateFromKey(key)
  if (!date) return ""
  date.setDate(date.getDate() + Number(amount || 0))
  return todayKey(date)
}

// ISO key of the Monday starting this date's calendar week.
function weekStartKey(date) {
  var ref = date || new Date()
  var d = new Date(ref.getFullYear(), ref.getMonth(), ref.getDate())
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7))
  return todayKey(d)
}

// ISO key of the first day of this date's calendar month.
function monthStartKey(date) {
  var ref = date || new Date()
  return todayKey(new Date(ref.getFullYear(), ref.getMonth(), 1))
}

function monthStartForKey(key) {
  var date = dateFromKey(key)
  return date ? monthStartKey(date) : ""
}

// A missing bucket means "not recorded", which is intentionally different
// from a recorded zero. This distinction keeps gaps from looking like resets.
function hasRangeData(buckets, fromKey, toKey, field) {
  var source = buckets || {}
  for (var key in source) {
    if (key >= fromKey && key <= toKey && (!field || hasOwn(source[key], field))) return true
  }
  return false
}

// Sum one field across day buckets in [fromKey, toKey], inclusive.
function sumRange(buckets, fromKey, toKey, field) {
  var source = buckets || {}
  var total = 0
  for (var key in source) {
    var bucket = source[key] || {}
    if (key >= fromKey && key <= toKey) total += finiteNonNegative(bucket[field], 0)
  }
  return total
}

// Keep at most `limit` most-recent day buckets; drop the rest.
function pruneBuckets(buckets, limit) {
  var keys = Object.keys(buckets || {}).sort()
  var drop = keys.length - limit
  for (var i = 0; i < drop; i++) delete buckets[keys[i]]
}

function normalizeBucket(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  var bucket = {}
  var fields = ["drained", "charged", "system"]
  for (var i = 0; i < fields.length; i++) {
    var field = fields[i]
    if (hasOwn(raw, field)) bucket[field] = finiteNonNegative(raw[field], 0)
  }
  if (raw.batteryEstimated === true) bucket.batteryEstimated = true
  return bucket
}

// Validate before adopting persisted state. An unreadable file must never be
// silently converted into an empty history and written back over the original.
function normalizeHistory(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { valid: false, error: "History root is not an object" }
  }
  if (!raw.days || typeof raw.days !== "object" || Array.isArray(raw.days)) {
    return { valid: false, error: "History days are missing or invalid" }
  }

  var days = {}
  for (var key in raw.days) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(key) || !dateFromKey(key)) continue
    var bucket = normalizeBucket(raw.days[key])
    if (bucket) days[key] = bucket
  }

  var last = null
  if (raw.last && typeof raw.last === "object" && !Array.isArray(raw.last)) {
    last = {
      ts: finiteNonNegative(raw.last.ts, 0),
      energy: finiteNonNegative(raw.last.energy, 0),
      state: String(raw.last.state || "Unknown"),
      rapl: finiteNonNegative(raw.last.rapl, 0),
      raplNode: String(raw.last.raplNode || "")
    }
  }
  return {
    valid: true,
    version: finiteNonNegative(raw.version, 1),
    days: days,
    last: last
  }
}

function parseHistory(raw) {
  try {
    return normalizeHistory(JSON.parse(String(raw || "")))
  } catch (error) {
    return { valid: false, error: "History JSON is malformed" }
  }
}

// Split a measured delta proportionally at local midnight boundaries. This
// fixes the old behavior that assigned an entire restart/suspend gap to today.
function splitAmountByDay(startTimestamp, endTimestamp, amount) {
  var start = Number(startTimestamp)
  var end = Number(endTimestamp)
  var total = finiteNonNegative(amount, 0)
  if (!isFinite(start) || !isFinite(end) || total <= 0) return []
  if (end <= start) return [{ key: todayKey(new Date(end * 1000)), amount: total }]

  var pieces = []
  var cursor = start
  var duration = end - start
  var assigned = 0
  while (cursor < end) {
    var date = new Date(cursor * 1000)
    var nextMidnight = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1).getTime() / 1000
    var pieceEnd = Math.min(end, nextMidnight)
    var pieceAmount = total * (pieceEnd - cursor) / duration
    assigned += pieceAmount
    pieces.push({ key: todayKey(date), amount: pieceAmount })
    cursor = pieceEnd
  }
  if (pieces.length > 0) pieces[pieces.length - 1].amount += total - assigned
  return pieces
}

function addRecoveredAmount(buckets, pieces, field) {
  for (var i = 0; i < pieces.length; i++) {
    var piece = pieces[i]
    var bucket = buckets[piece.key] || { drained: 0, charged: 0 }
    bucket[field] = finiteNonNegative(bucket[field], 0) + piece.amount
    bucket.batteryEstimated = true
    buckets[piece.key] = bucket
  }
}

// Convert UPower's retained percentage history into approximate Wh buckets.
// UPower state values: 1 charging, 2 discharging. Samples arrive newest first.
function recoverUPowerHistory(raw, energyCapacityWh) {
  var capacity = finiteNonNegative(energyCapacityWh, 0)
  if (capacity <= 0) return {}

  var payload
  try {
    payload = JSON.parse(String(raw || ""))
  } catch (error) {
    return {}
  }
  var rows = payload && payload.data && payload.data[0]
  if (!Array.isArray(rows)) return {}

  var samples = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!Array.isArray(row) || row.length < 3) continue
    var timestamp = Number(row[0])
    var percentage = Number(row[1])
    var state = Number(row[2])
    if (!isFinite(timestamp) || !isFinite(percentage) || percentage <= 0 || percentage > 100 || state <= 0) continue
    samples.push({ ts: timestamp, percentage: percentage, state: state })
  }
  samples.sort(function(a, b) { return a.ts - b.ts })

  var buckets = {}
  for (var j = 1; j < samples.length; j++) {
    var previous = samples[j - 1]
    var current = samples[j]
    if (current.ts <= previous.ts) continue
    var difference = current.percentage - previous.percentage
    if (difference === 0 || Math.abs(difference) > 100) continue

    var field = ""
    if (difference > 0 && (previous.state === 1 || current.state === 1)) field = "charged"
    if (difference < 0 && (previous.state === 2 || current.state === 2)) field = "drained"
    if (!field) continue

    var wh = Math.abs(difference) * capacity / 100
    addRecoveredAmount(buckets, splitAmountByDay(previous.ts, current.ts, wh), field)
  }
  return buckets
}

// Recovered UPower data is lower precision than live energy readings. It only
// fills absent/zero battery days; it never overwrites a live non-zero total.
function mergeRecoveredBatteryHistory(existing, recovered) {
  var output = {}
  var key
  for (key in (existing || {})) output[key] = Object.assign({}, existing[key])

  for (key in (recovered || {})) {
    var estimate = recovered[key] || {}
    var bucket = output[key]
    if (!bucket) {
      output[key] = Object.assign({}, estimate)
      continue
    }
    var measuredTotal = finiteNonNegative(bucket.drained, 0) + finiteNonNegative(bucket.charged, 0)
    var recoveredTotal = finiteNonNegative(estimate.drained, 0) + finiteNonNegative(estimate.charged, 0)
    if (measuredTotal <= 0 && recoveredTotal > 0) {
      bucket.drained = finiteNonNegative(estimate.drained, 0)
      bucket.charged = finiteNonNegative(estimate.charged, 0)
      bucket.batteryEstimated = true
    }
  }
  return output
}

function historyChanged(before, after) {
  return JSON.stringify(before || {}) !== JSON.stringify(after || {})
}

// Guangdong uses summer thresholds from May through October.
function zhuhaiTierLimits(date) {
  var month = (date || new Date()).getMonth() + 1
  return month >= 5 && month <= 10 ? [260, 600] : [200, 400]
}

function zhuhaiSeasonLabel(date) {
  var month = (date || new Date()).getMonth() + 1
  return month >= 5 && month <= 10 ? "summer" : "non-summer"
}

function zhuhaiCostAtTotal(kwh, date, baseRate) {
  var usage = finiteNonNegative(kwh, 0)
  var rate = finiteNonNegative(baseRate, ZHUHAI_BASE_RATE)
  var limits = zhuhaiTierLimits(date)
  var tier1 = Math.min(usage, limits[0])
  var tier2 = Math.min(Math.max(usage - limits[0], 0), limits[1] - limits[0])
  var tier3 = Math.max(usage - limits[1], 0)
  return tier1 * rate
    + tier2 * (rate + ZHUHAI_TIER_2_SURCHARGE)
    + tier3 * (rate + ZHUHAI_TIER_3_SURCHARGE)
}

// Marginal cost of this device after `priorKwh` of monthly household use.
function zhuhaiIncrementalCost(priorKwh, deviceKwh, date, baseRate) {
  var prior = finiteNonNegative(priorKwh, 0)
  var usage = finiteNonNegative(deviceKwh, 0)
  return zhuhaiCostAtTotal(prior + usage, date, baseRate) - zhuhaiCostAtTotal(prior, date, baseRate)
}

function zhuhaiMarginalRate(monthKwh, date, baseRate) {
  var usage = finiteNonNegative(monthKwh, 0)
  var rate = finiteNonNegative(baseRate, ZHUHAI_BASE_RATE)
  var limits = zhuhaiTierLimits(date)
  if (usage >= limits[1]) return rate + ZHUHAI_TIER_3_SURCHARGE
  if (usage >= limits[0]) return rate + ZHUHAI_TIER_2_SURCHARGE
  return rate
}

function zhuhaiTier(monthKwh, date) {
  var limits = zhuhaiTierLimits(date)
  var usage = finiteNonNegative(monthKwh, 0)
  if (usage >= limits[1]) return 3
  if (usage >= limits[0]) return 2
  return 1
}

// The daily value is priced at its true marginal tier within the tracked
// month. `baselineKwh` can account for other household electricity.
function dayElectricityCost(buckets, key, field, baseRate, baselineKwh) {
  var date = dateFromKey(key)
  if (!date || !hasRangeData(buckets, key, key, field)) return NaN
  var monthStart = monthStartForKey(key)
  var previousKey = addDaysKey(key, -1)
  var priorTracked = previousKey >= monthStart ? sumRange(buckets, monthStart, previousKey, field) / 1000 : 0
  var todayKwh = sumRange(buckets, key, key, field) / 1000
  return zhuhaiIncrementalCost(finiteNonNegative(baselineKwh, 0) + priorTracked, todayKwh, date, baseRate)
}

function rangeElectricityCost(buckets, fromKey, toKey, field, baseRate, baselineKwh) {
  var keys = Object.keys(buckets || {}).sort()
  var total = 0
  var found = false
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i]
    if (key < fromKey || key > toKey || !hasOwn(buckets[key], field)) continue
    var cost = dayElectricityCost(buckets, key, field, baseRate, baselineKwh)
    if (isFinite(cost)) {
      found = true
      total += cost
    }
  }
  return found ? total : NaN
}

function recentDayRows(buckets, count, endKey, field, baseRate, baselineKwh) {
  var rows = []
  var lastKey = endKey || todayKey()
  for (var i = 0; i < count; i++) {
    var key = addDaysKey(lastKey, -i)
    var bucket = (buckets || {})[key] || {}
    var hasData = hasRangeData(buckets, key, key)
    rows.push({
      key: key,
      label: key.slice(5).replace("-", "/"),
      hasData: hasData,
      systemWh: hasOwn(bucket, field) ? finiteNonNegative(bucket[field], 0) : NaN,
      cost: dayElectricityCost(buckets, key, field, baseRate, baselineKwh),
      drainedWh: hasOwn(bucket, "drained") ? finiteNonNegative(bucket.drained, 0) : NaN,
      chargedWh: hasOwn(bucket, "charged") ? finiteNonNegative(bucket.charged, 0) : NaN,
      batteryEstimated: bucket.batteryEstimated === true
    })
  }
  return rows
}

function upowerStateName(state, states) {
  var s = states || {}
  if (state === s.Charging) return "Charging"
  if (state === s.Discharging) return "Discharging"
  if (state === s.FullyCharged) return "FullyCharged"
  if (state === s.PendingCharge) return "PendingCharge"
  if (state === s.PendingDischarge) return "PendingDischarge"
  if (state === s.Empty) return "Empty"
  return "Unknown"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

// Same hold-state detection as the stock power widget: the battery is at a
// charge-control threshold when it is plugged in and either pending charge,
// "full" below 99%, or charging at a trickle with a very long time-to-full.
function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

// Keep an index inside [0, length-1]; degenerate lists clamp to 0.
function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

// Move the work-mode (power profile) cursor by `delta` steps.
function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

// Parse `omarchy-powerprofiles-list --active-state` output
// ("power-saver\t0\nbalanced\t1\n...") into a profile list plus the
// currently active name.
function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

// Nerd-font glyphs for the work-mode buttons.
function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

// Nerd-font battery glyph: filled per 10% step. The bolt (charging series)
// only appears while energy is actually flowing into the battery — a plugged
// but full battery is a plain full glyph, not a charging one.
function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))

  if (chargeThresholdActive(d, onBattery, states)) return defaultIcons[index]
  if (onBattery) return defaultIcons[index]
  var chargingFlow = d.state === states.Charging && Number(d.changeRate || 0) > 0.05
  if (chargingFlow) return chargingIcons[index]
  return defaultIcons[index]
}

// Hero status line, e.g. "Fully charged" / "Charging" / "On battery".
function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""
  if (chargeThresholdActive(d, onBattery, states)) return "Charge limited"
  if (onBattery) return "On battery"
  if (!onBattery && batteryFraction(d) >= 1) return "Fully charged"
  return "Charging"
}

// "45 W" for the panel; one decimal below 100 W so trickle rates stay legible.
function formatPower(watts) {
  var n = Number(watts)
  if (!isFinite(n)) n = 0
  if (Math.abs(n) >= 10) return Math.round(n) + " W"
  return (Math.round(n * 10) / 10) + " W"
}

// Compact "45W" for the bar button.
function formatCompactPower(watts) {
  return formatPower(watts).replace(" W", "W")
}

// Wh with adaptive precision: 3.2 Wh, 21.4 Wh, 128 Wh.
function formatWh(wh) {
  var n = Number(wh)
  if (!isFinite(n)) return "—"
  if (n <= 0) return "0 Wh"
  if (n >= 100) return Math.round(n) + " Wh"
  if (n >= 10) return n.toFixed(1) + " Wh"
  return n.toFixed(2) + " Wh"
}

function formatCurrency(value) {
  var n = Number(value)
  if (!isFinite(n)) return "—"
  if (n > 0 && n < 0.01) return "¥" + n.toFixed(3)
  return "¥" + n.toFixed(2)
}

function formatRate(rate) {
  return "¥" + finiteNonNegative(rate, ZHUHAI_BASE_RATE).toFixed(4) + "/kWh"
}

// Seconds → "23m" / "1h 23m" / "2d 5h".
function formatDuration(seconds) {
  var s = Number(seconds)
  if (!isFinite(s) || s <= 0) return "—"
  var m = Math.round(s / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h " + (m % 60) + "m"
  return Math.floor(h / 24) + "d " + (h % 24) + "h"
}

if (typeof module !== "undefined") {
  module.exports = {
    ZHUHAI_BASE_RATE: ZHUHAI_BASE_RATE,
    todayKey: todayKey,
    dateFromKey: dateFromKey,
    addDaysKey: addDaysKey,
    weekStartKey: weekStartKey,
    monthStartKey: monthStartKey,
    hasRangeData: hasRangeData,
    sumRange: sumRange,
    pruneBuckets: pruneBuckets,
    normalizeHistory: normalizeHistory,
    parseHistory: parseHistory,
    splitAmountByDay: splitAmountByDay,
    recoverUPowerHistory: recoverUPowerHistory,
    mergeRecoveredBatteryHistory: mergeRecoveredBatteryHistory,
    historyChanged: historyChanged,
    zhuhaiTierLimits: zhuhaiTierLimits,
    zhuhaiSeasonLabel: zhuhaiSeasonLabel,
    zhuhaiCostAtTotal: zhuhaiCostAtTotal,
    zhuhaiIncrementalCost: zhuhaiIncrementalCost,
    zhuhaiMarginalRate: zhuhaiMarginalRate,
    zhuhaiTier: zhuhaiTier,
    dayElectricityCost: dayElectricityCost,
    rangeElectricityCost: rangeElectricityCost,
    recentDayRows: recentDayRows,
    upowerStateName: upowerStateName,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    formatPower: formatPower,
    formatCompactPower: formatCompactPower,
    formatWh: formatWh,
    formatCurrency: formatCurrency,
    formatRate: formatRate,
    formatDuration: formatDuration
  }
}
