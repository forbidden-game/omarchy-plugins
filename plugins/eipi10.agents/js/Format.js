.pragma library

function formatTokenCount(n) {
  if (n === undefined || n === null || isNaN(n)) return "0"
  var abs = Math.abs(Number(n))
  if (abs >= 1e9) return (n / 1e9).toFixed(1) + "B"
  if (abs >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (abs >= 1e3) return (n / 1e3).toFixed(1) + "K"
  return String(Math.round(n))
}

function modelWordCase(word) {
  var lower = String(word || "").toLowerCase()
  if (lower === "gpt") return "GPT"
  if (lower === "deepseek") return "DeepSeek"
  if (lower === "qwen") return "Qwen"
  if (lower === "gemini") return "Gemini"
  if (lower === "claude") return "Claude"
  if (lower === "openai") return "OpenAI"
  if (lower === "vlm") return "VLM"
  return lower.charAt(0).toUpperCase() + lower.slice(1)
}

function normalizeModelId(id) {
  if (!id) return "unknown"
  var lower = String(id).toLowerCase().trim()
  if (lower.indexOf("gemini-3.7-flash") >= 0 || lower.indexOf("gemini-3-7-flash") >= 0) {
    return "gemini-3.7-flash"
  }
  return lower
}

function friendlyModelName(id) {
  var norm = normalizeModelId(id)
  if (!norm) return "Unknown"
  var name = String(norm).replace(/^claude-/, "").replace(/-\d{8}$/, "")
  var parts = name.split(/[-_/]/)
  var words = []
  var version = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue
    if (/^\d+(\.\d+)*$/.test(part)) {
      version.push(part)
      continue
    }
    if (version.length > 0) {
      words.push(version.join("."))
      version = []
    }
    words.push(modelWordCase(part))
  }
  if (version.length > 0) words.push(version.join("."))
  return words.length > 0 ? words.join(" ") : "Unknown"
}

function dayName(date) {
  var parsed = new Date(String(date || "") + "T00:00:00")
  if (isNaN(parsed.getTime())) return String(date || "")
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
}

function dayLabel(date, isToday) {
  if (isToday) return "Today"
  return dayName(date)
}

function formatDuration(ms) {
  if (!(ms > 0)) return "now"
  var minutes = Math.floor(ms / 60000)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "m"
  return Math.max(1, minutes) + "m"
}
