.pragma library

var DEFAULT_RATES = {
  // OpenAI GPT-5.6 Family (Official OpenAI Pricing: Sol $4/$20, Terra $2/$12, Luna $0.20/$1.20)
  "gpt-5.6-sol": { input: 4.00, output: 20.00, cacheRead: 0.40, cacheWrite: 0.0 },
  "gpt-5.6-sol-372k": { input: 8.00, output: 40.00, cacheRead: 0.80, cacheWrite: 0.0 },
  "gpt-5.6-terra": { input: 2.00, output: 12.00, cacheRead: 0.20, cacheWrite: 0.0 },
  "gpt-5.6-luna": { input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.0 },
  "gpt-5.6": { input: 4.00, output: 20.00, cacheRead: 0.40, cacheWrite: 0.0 },
  "codex": { input: 4.00, output: 20.00, cacheRead: 0.40, cacheWrite: 0.0 },
  "stealth/ox-alpha": { input: 4.00, output: 20.00, cacheRead: 0.40, cacheWrite: 0.0 },

  // Gemini (Official Google Pricing: 3.7 Flash $0.75/$3.75, 2.5 Flash $0.10/$0.40, 2.5 Pro $1.25/$5.00)
  "gemini-3.7-flash": { input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.0 },
  "gemini-3.7-flash-control": { input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.0 },
  "gemini-default": { input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.0 },
  "gemini-2.5-pro": { input: 1.25, output: 5.00, cacheRead: 0.3125, cacheWrite: 0.0 },
  "gemini-2.5-flash": { input: 0.10, output: 0.40, cacheRead: 0.025, cacheWrite: 0.0 },
  "gemini-2.0-flash": { input: 0.10, output: 0.40, cacheRead: 0.025, cacheWrite: 0.0 },

  // DeepSeek V4 (Official DeepSeek Pricing: V4 Flash $0.22/$0.66, V4 Pro $0.66/$1.98)
  "deepseek-v4-flash": { input: 0.22, output: 0.66, cacheRead: 0.014, cacheWrite: 0.0 },
  "deepseek/deepseek-v4-flash": { input: 0.22, output: 0.66, cacheRead: 0.014, cacheWrite: 0.0 },
  "deepseek/deepseek-v4-flash-0731": { input: 0.22, output: 0.66, cacheRead: 0.014, cacheWrite: 0.0 },
  "deepseek-chat": { input: 0.22, output: 0.66, cacheRead: 0.014, cacheWrite: 0.0 },
  "deepseek-v4-pro": { input: 0.66, output: 1.98, cacheRead: 0.044, cacheWrite: 0.0 },
  "deepseek/deepseek-v4-pro": { input: 0.66, output: 1.98, cacheRead: 0.044, cacheWrite: 0.0 },
  "deepseek/deepseek-v4-pro-0813": { input: 0.66, output: 1.98, cacheRead: 0.044, cacheWrite: 0.0 },
  "deepseek-reasoner": { input: 0.66, output: 1.98, cacheRead: 0.044, cacheWrite: 0.0 },

  // Other OpenAI
  "gpt-4o": { input: 2.50, output: 10.00, cacheRead: 1.25, cacheWrite: 0.0 },
  "gpt-4o-mini": { input: 0.15, output: 0.60, cacheRead: 0.075, cacheWrite: 0.0 },
  "o1": { input: 15.00, output: 60.00, cacheRead: 7.50, cacheWrite: 0.0 },
  "o3-mini": { input: 1.10, output: 4.40, cacheRead: 0.55, cacheWrite: 0.0 },

  // Claude (Anthropic official pricing)
  "claude-3-7-sonnet": { input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75 },
  "claude-3-5-sonnet": { input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75 },
  "claude-3-5-haiku": { input: 0.80, output: 4.00, cacheRead: 0.08, cacheWrite: 1.00 },
  "claude-3-opus": { input: 15.00, output: 75.00, cacheRead: 1.50, cacheWrite: 18.75 },

  // Qwen (Local llama.cpp / Self-hosted tunnels on office_server -> $0.00)
  "qwen38": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 },
  "qwen38-q3kxl": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 },
  "qwen38-iq3xxs": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 },
  "qwen38-ridge": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 },
  "qwen38-udq8-mtp-vlm": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 },
  "qwen-2.5-coder": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 },

  // Free / Local
  "ox-alpha-free": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 },
  "hy3-free": { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 }
}

function getModelRate(modelId, customRates) {
  var id = String(modelId || "").toLowerCase().trim()
  if (customRates && customRates[id]) return customRates[id]
  if (DEFAULT_RATES[id]) return DEFAULT_RATES[id]

  if (id.indexOf("free") >= 0) return { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 }
  if (id.indexOf("qwen") >= 0) return DEFAULT_RATES["qwen38"]
  if (id.indexOf("sol") >= 0) return DEFAULT_RATES["gpt-5.6-sol"]
  if (id.indexOf("terra") >= 0) return DEFAULT_RATES["gpt-5.6-terra"]
  if (id.indexOf("luna") >= 0) return DEFAULT_RATES["gpt-5.6-luna"]
  if (id.indexOf("gemini") >= 0 && id.indexOf("3.7") >= 0) return DEFAULT_RATES["gemini-3.7-flash"]
  if (id.indexOf("gemini") >= 0) return DEFAULT_RATES["gemini-2.5-flash"]
  if (id.indexOf("deepseek") >= 0 && id.indexOf("pro") >= 0) return DEFAULT_RATES["deepseek-v4-pro"]
  if (id.indexOf("deepseek") >= 0) return DEFAULT_RATES["deepseek-v4-flash"]
  if (id.indexOf("sonnet") >= 0) return DEFAULT_RATES["claude-3-7-sonnet"]
  if (id.indexOf("haiku") >= 0) return DEFAULT_RATES["claude-3-5-haiku"]
  if (id.indexOf("opus") >= 0) return DEFAULT_RATES["claude-3-opus"]
  if (id.indexOf("gpt") >= 0) return DEFAULT_RATES["gpt-5.6-sol"]

  // Default fallback rate ($0.15 in / $0.60 out / $0.05 cache)
  return { input: 0.15, output: 0.60, cacheRead: 0.05, cacheWrite: 0.0 }
}

function calculateCostBreakdown(bucket, rate) {
  var b = bucket || {}
  var r = rate || { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  var inCost = (Number(b.inputTokens || b.input || 0) / 1e6) * (r.input || 0)
  var outCost = (Number(b.outputTokens || b.output || 0) / 1e6) * (r.output || 0)
  var crCost = (Number(b.cacheReadInputTokens || b.cacheRead || 0) / 1e6) * (r.cacheRead || 0)
  var cwCost = (Number(b.cacheCreationInputTokens || b.cacheWrite || 0) / 1e6) * (r.cacheWrite || 0)
  var total = inCost + outCost + crCost + cwCost
  return {
    total: total,
    inputCost: inCost,
    outputCost: outCost,
    cacheReadCost: crCost,
    cacheWriteCost: cwCost,
    rate: r
  }
}

function calculateModelCost(modelId, bucket, customRates) {
  var rate = getModelRate(modelId, customRates)
  return calculateCostBreakdown(bucket, rate)
}

function calculateTotalCost(modelUsageMap, customRates) {
  var map = modelUsageMap || {}
  var total = 0
  for (var id in map) {
    var breakdown = calculateModelCost(id, map[id], customRates)
    total += breakdown.total
  }
  return total
}

function formatMoney(amount, currency) {
  var val = Number(amount)
  if (!isFinite(val) || val <= 0) return "$0.00"
  if (val < 0.005) return "< $0.01"
  if (val < 0.10) return "$" + val.toFixed(3)
  return "$" + val.toFixed(2)
}
