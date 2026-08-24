// Pure helpers for the battery-info widget: icon selection, date keys,
// consumption aggregation, and value formatting. No Quickshell imports so
// this stays unit-testable and trivially portable.

function pad2(n) {
  return n < 10 ? "0" + n : "" + n
}

// Local-time ISO date key, e.g. "2026-08-15".
function todayKey(date) {
  var d = date || new Date()
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
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

// Sum one field ("drained"|"charged") across day buckets whose keys fall
// inside [fromKey, toKey] inclusive. ISO keys compare lexicographically.
function sumRange(buckets, fromKey, toKey, field) {
  var total = 0
  for (var key in buckets) {
    if (key >= fromKey && key <= toKey) total += Number(buckets[key][field] || 0)
  }
  return total
}

// Keep at most `limit` most-recent day buckets; drop the rest.
function pruneBuckets(buckets, limit) {
  var keys = Object.keys(buckets).sort()
  var drop = keys.length - limit
  for (var i = 0; i < drop; i++) delete buckets[keys[i]]
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

  // Charge-control hold: plain glyph, no bolt.
  if (chargeThresholdActive(d, onBattery, states)) return defaultIcons[index]
  // On battery: plain glyph.
  if (onBattery) return defaultIcons[index]
  // Plugged: bolt only while energy is genuinely flowing into the battery.
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
  if (!isFinite(n) || n <= 0) return "0 Wh"
  if (n >= 100) return Math.round(n) + " Wh"
  if (n >= 10) return n.toFixed(1) + " Wh"
  return n.toFixed(2) + " Wh"
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
    todayKey: todayKey,
    weekStartKey: weekStartKey,
    monthStartKey: monthStartKey,
    sumRange: sumRange,
    pruneBuckets: pruneBuckets,
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
    formatDuration: formatDuration
  }
}
