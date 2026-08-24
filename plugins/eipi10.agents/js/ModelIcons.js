// js/ModelIcons.js — Omarchy Theme-Adaptive Model Color Palette

.pragma library

// Deterministic model to color palette slot index
var MODEL_INDEX_MAP = {
  "gemini-3.7-flash-control": 0, // Slot 0: Primary Accent / Blue
  "gemini-3.7-flash": 1,         // Slot 1: Magenta / Indigo
  "gemini-3.7-flash-high": 1,
  "gemini-3.7-flash-tiered": 1,
  "gemini-3.1-pro-high": 0,
  "gemini-3.1-pro": 0,
  "gemini-2.5-pro": 0,
  "gemini-default": 6,          // Slot 6: Muted / Gray
  "deepseek-v4-flash": 2,       // Slot 2: Cyan / Teal
  "deepseek/deepseek-v4-flash": 2,
  "gpt-5.6-sol": 3,             // Slot 3: Orange
  "gpt-5.6-sol-372k": 3,
  "claude-sonnet-4-6": 4,       // Slot 4: Green / Rose
  "claude-opus-4-6-thinking": 4,
  "gpt-5.6-luna": 1,
  "qwen38-ridge": 4,
  "qwen38": 4,
  "stealth/ox-alpha": 5,        // Slot 5: Yellow
  "ox-alpha-free": 5,
  "deepseek-v4-pro": 2,
  "gpt-oss-120b-medium": 5
}

function getThemePalette(colorSingleton) {
  if (!colorSingleton) {
    return ["#7aa2f7", "#bb9af7", "#7dcfff", "#ff9e64", "#9ece6a", "#e0af68", "#565f89"]
  }

  var accent = colorSingleton.accent || "#7aa2f7"
  var muted = colorSingleton.muted || colorSingleton.dim || "#565f89"
  var urgent = colorSingleton.urgent || "#f7768e"

  function resolveRole(role, fallback) {
    if (typeof colorSingleton.flatColor === "function") {
      var c = colorSingleton.flatColor(role, fallback)
      if (c && c !== fallback) return c
    }
    if (colorSingleton.shellValues && colorSingleton.shellValues[role]) {
      return colorSingleton.shellValues[role]
    }
    return fallback
  }

  var cBlue = resolveRole("blue", accent)
  var cMagenta = resolveRole("magenta", resolveRole("bright_magenta", "#bb9af7"))
  var cCyan = resolveRole("cyan", resolveRole("bright_cyan", "#7dcfff"))
  var cOrange = resolveRole("orange", resolveRole("yellow", "#ff9e64"))
  var cGreen = resolveRole("green", resolveRole("bright_green", "#9ece6a"))
  var cYellow = resolveRole("yellow", resolveRole("bright_yellow", "#e0af68"))
  var cMuted = muted

  return [cBlue, cMagenta, cCyan, cOrange, cGreen, cYellow, cMuted]
}

function getModelColor(modelId, colorSingleton, rankIndex) {
  var palette = getThemePalette(colorSingleton)
  if (rankIndex !== undefined && rankIndex >= 0 && rankIndex < palette.length) {
    return palette[rankIndex]
  }

  var clean = String(modelId || "").toLowerCase().replace(/\/+$/, "")
  if (MODEL_INDEX_MAP[clean] !== undefined) {
    return palette[MODEL_INDEX_MAP[clean]]
  }

  for (var k in MODEL_INDEX_MAP) {
    if (clean.indexOf(k) >= 0) {
      return palette[MODEL_INDEX_MAP[k]]
    }
  }

  return palette[6] // Muted fallback
}

var FRIENDLY_NAMES = {
  "gemini-3.7-flash-control": "Gemini 3.7 Flash Control",
  "gemini-3.7-flash": "Gemini 3.7 Flash",
  "gemini-3.7-flash-high": "Gemini 3.7 Flash (High)",
  "gemini-3.7-flash-tiered": "Gemini 3.7 Flash (Tiered)",
  "gemini-3.1-pro-high": "Gemini 3.1 Pro (High)",
  "gemini-3.1-pro": "Gemini 3.1 Pro",
  "gemini-2.5-pro": "Gemini 2.5 Pro",
  "gemini-default": "Gemini (Default)",
  "deepseek-v4-flash": "DeepSeek V4 Flash",
  "deepseek/deepseek-v4-flash": "DeepSeek V4 Flash",
  "gpt-5.6-sol": "GPT-5.6 Sol",
  "gpt-5.6-sol-372k": "GPT-5.6 Sol 372k",
  "gpt-5.6-luna": "GPT-5.6 Luna",
  "claude-sonnet-4-6": "Claude Sonnet 4.6",
  "claude-opus-4-6-thinking": "Claude Opus 4.6",
  "qwen38-ridge": "Qwen 3.8 Ridge",
  "qwen38": "Qwen 3.8",
  "stealth/ox-alpha": "Stealth OX-Alpha",
  "ox-alpha-free": "Stealth OX-Alpha",
  "deepseek-v4-pro": "DeepSeek V4 Pro",
  "gpt-oss-120b-medium": "GPT-OSS 120B",
  "weekly (7-day)": "Weekly Limit (7-day)",
  "weekly": "Weekly Limit"
}

function getModelLabel(modelId) {
  var clean = String(modelId || "").toLowerCase().replace(/\/+$/, "")
  if (FRIENDLY_NAMES[clean]) return FRIENDLY_NAMES[clean]
  for (var k in FRIENDLY_NAMES) {
    if (clean.indexOf(k) >= 0) return FRIENDLY_NAMES[k]
  }
  return modelId || "Unknown"
}
