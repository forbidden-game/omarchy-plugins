// Pure helpers for the cpu-ram widget: /proc/stat and /proc/meminfo parsing,
// CPU jiffie-delta math, top-process row parsing, and compact value
// formatting. No Quickshell imports so this stays unit-testable and trivially
// portable.

// Split the concatenated output of `cat /proc/stat /proc/meminfo` into the
// two raw buffers. Everything before the first "MemTotal:" line is /proc/stat.
function splitProcOutput(raw) {
  var s = String(raw || "")
  var idx = s.indexOf("MemTotal:")
  if (idx < 0) return { stat: s, meminfo: "" }
  return { stat: s.substr(0, idx), meminfo: s.substr(idx) }
}

// Parse /proc/stat into { total: metric, cores: [metric, ...] }. `total` is
// the aggregate `cpu` line; `cores` maps cpu0..cpuN by index. Each metric
// carries the raw tick counters plus two derived sums used by the delta math.
function parseStat(raw) {
  var total = null
  var cores = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line.indexOf("cpu") !== 0) continue
    var parts = line.split(/\s+/)
    if (parts.length < 9) continue
    var p = {
      user: +parts[1] || 0,
      nice: +parts[2] || 0,
      system: +parts[3] || 0,
      idle: +parts[4] || 0,
      iowait: +parts[5] || 0,
      irq: +parts[6] || 0,
      softirq: +parts[7] || 0,
      steal: +parts[8] || 0
    }
    p.total = p.user + p.nice + p.system + p.idle + p.iowait + p.irq + p.softirq + p.steal
    p.idleTotal = p.idle + p.iowait
    if (parts[0] === "cpu") total = p
    else if (/^cpu\d+$/.test(parts[0])) cores[parseInt(parts[0].substr(3), 10)] = p
  }
  // Squeeze out sparse holes (kernels report cpu0..cpuN so this is a no-op in
  // practice, but keeps the array tight for unusual layouts).
  var tight = []
  for (var c = 0; c < cores.length; c++) if (cores[c]) tight.push(cores[c])
  return { total: total, cores: tight }
}

// CPU busy percent (0..100) between two snapshots of the same metric. Idle
// jiffies include iowait, matching what task managers call "idle". Returns 0
// when the counter has not advanced (first sample, or a fresh /proc namespace).
function cpuPercent(prev, next) {
  if (!prev || !next) return 0
  var dTotal = next.total - prev.total
  if (dTotal <= 0) return 0
  var dIdle = next.idleTotal - prev.idleTotal
  return Math.max(0, Math.min(100, (dTotal - dIdle) / dTotal * 100))
}

// Parse /proc/meminfo into byte values. `used` excludes buff/cache, which is
// reported separately so the panel can show the reclaimable headroom — this
// matches the "used" column of free(1) (total - available).
function parseMeminfo(raw) {
  var m = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^(\w+):\s+(\d+)\s*kB/)
    if (match) m[match[1]] = +match[2]
  }
  var total = m.MemTotal || 0
  var available = m.MemAvailable >= 0 ? m.MemAvailable : (m.MemFree || 0)
  var cache = (m.Buffers || 0) + (m.Cached || 0) + (m.SReclaimable || 0)
  var swapTotal = m.SwapTotal || 0
  return {
    total: total * 1024,
    used: Math.max(0, total - available) * 1024,
    cache: cache * 1024,
    swapTotal: swapTotal * 1024,
    swapUsed: Math.max(0, (swapTotal - (m.SwapFree || 0))) * 1024
  }
}

// Parse /proc/loadavg into [one, five, fifteen] minute load averages.
// Anchored at line start so only the loadavg line matches inside the
// concatenated proc dump (stat lines start with "cpu", meminfo with words,
// and a trailing temp file is digits-only).
function parseLoadavg(raw) {
  var m = String(raw || "").match(/^(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)/m)
  if (!m) return [0, 0, 0]
  return [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3])]
}

// Parse `ps -eo comm=,%cpu=,%mem= --sort=-%cpu | head -6` into top rows.
// comm is matched lazily so names containing spaces parse correctly.
function parseTop(raw) {
  var out = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^(.*?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)$/)
    if (!m) continue
    var name = m[1].trim()
    if (name.length === 0) continue
    out.push({ name: name, cpu: parseFloat(m[2]), mem: parseFloat(m[3]) })
  }
  return out
}

function percentOf(used, total) {
  if (!total || total <= 0) return 0
  return Math.max(0, Math.min(100, used / total * 100))
}

// Extract the trailing CPU temperature (millidegrees) from the concatenated
// output of `cat /proc/stat /proc/meminfo <tempfile>`. Scans backwards: the
// first digits-only line is the temp; a meminfo "... kB" line means there is
// none. /proc/stat lines always start with "cpu", so they never match.
function parseTemp(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = lines.length - 1; i >= 0; i--) {
    var line = lines[i].trim()
    if (/^\d+$/.test(line)) return Number(line)
    if (/^\w+:\s+\d+\s*kB/.test(line)) return 0
  }
  return 0
}

// Millidegrees Celsius -> rounded whole degrees; 0 stays 0 ("unknown").
function celsius(milli) {
  var n = Number(milli)
  if (!isFinite(n) || n <= 0) return 0
  return Math.round(n / 1000)
}

// Compact byte string with one decimal place above 1K: 812B, 1.2K, 34M, 6.5G.
function compactBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + "B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + "K"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + "M"
  return (n / (1024 * 1024 * 1024)).toFixed(1) + "G"
}