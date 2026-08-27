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

  // GLM (Zhipu BigModel domestic schedule — https://bigmodel.cn/pricing,
  // scraped 2026-08-27; CNY converted at 7.2/USD, same basis as Qwen.
  // GLM-5.3-Flash is on a two-week 50% promo: current ¥0.4 input / ¥0.115
  // cache-hit / ¥1.4 output per M, list ¥0.8/¥0.23/¥2.8. No cache-write
  // surcharge. This is the platform the Coding Plan traffic bills on.)
  "glm-5.3-flash": { input: 0.056, output: 0.194, cacheRead: 0.016, cacheWrite: 0.056 },
  "glm-5.3": { input: 1.11, output: 3.89, cacheRead: 0.28, cacheWrite: 1.11 },

  // Qwen (self-hosted office_server models have no per-token API charge)
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

function zeroRate() {
  return { input: 0.0, output: 0.0, cacheRead: 0.0, cacheWrite: 0.0 }
}

function nonNegativeNumber(value) {
  var number = Number(value)
  return isFinite(number) && number > 0 ? number : 0
}

function resolveModelRate(modelId, customRates) {
  var id = String(modelId || "").toLowerCase().trim()
  if (customRates && customRates[id]) return { rate: customRates[id], rated: true }
  if (DEFAULT_RATES[id]) return { rate: DEFAULT_RATES[id], rated: true }

  if (id.indexOf("free") >= 0) return { rate: zeroRate(), rated: true }
  if (id.indexOf("glm-5.3") >= 0 && id.indexOf("flash") >= 0)
    return { rate: DEFAULT_RATES["glm-5.3-flash"], rated: true }
  if (id.indexOf("glm-5.3") >= 0)
    return { rate: DEFAULT_RATES["glm-5.3"], rated: true }
  if (id.indexOf("qwen38") >= 0 || id.indexOf("qwen-2.5-coder") >= 0)
    return { rate: DEFAULT_RATES["qwen38"], rated: true }
  if (id.indexOf("gpt-5.6") >= 0 && id.indexOf("sol") >= 0)
    return { rate: DEFAULT_RATES["gpt-5.6-sol"], rated: true }
  if (id.indexOf("gpt-5.6") >= 0 && id.indexOf("terra") >= 0)
    return { rate: DEFAULT_RATES["gpt-5.6-terra"], rated: true }
  if (id.indexOf("gpt-5.6") >= 0 && id.indexOf("luna") >= 0)
    return { rate: DEFAULT_RATES["gpt-5.6-luna"], rated: true }
  if (id.indexOf("gemini") >= 0 && id.indexOf("3.7") >= 0 && id.indexOf("flash") >= 0)
    return { rate: DEFAULT_RATES["gemini-3.7-flash"], rated: true }
  if (id.indexOf("gemini") >= 0 && id.indexOf("pro") >= 0)
    return { rate: DEFAULT_RATES["gemini-2.5-pro"], rated: true }
  if (id.indexOf("gemini") >= 0 && id.indexOf("flash") >= 0)
    return { rate: DEFAULT_RATES["gemini-2.5-flash"], rated: true }
  if (id.indexOf("deepseek") >= 0 && id.indexOf("pro") >= 0)
    return { rate: DEFAULT_RATES["deepseek-v4-pro"], rated: true }
  if (id.indexOf("deepseek") >= 0 && (id.indexOf("flash") >= 0 || id.indexOf("chat") >= 0))
    return { rate: DEFAULT_RATES["deepseek-v4-flash"], rated: true }
  if (id.indexOf("sonnet") >= 0)
    return { rate: DEFAULT_RATES["claude-3-7-sonnet"], rated: true }
  if (id.indexOf("haiku") >= 0)
    return { rate: DEFAULT_RATES["claude-3-5-haiku"], rated: true }
  if (id.indexOf("opus") >= 0)
    return { rate: DEFAULT_RATES["claude-3-opus"], rated: true }

  // An unknown model is explicitly unrated. Inventing a fallback price makes
  // the grand total look exact while silently charging an unrelated tariff.
  return { rate: zeroRate(), rated: false }
}

function getModelRate(modelId, customRates) {
  return resolveModelRate(modelId, customRates).rate
}

function isModelRated(modelId, customRates) {
  return resolveModelRate(modelId, customRates).rated
}

function bucketTokenTotal(bucket) {
  var b = bucket || {}
  return nonNegativeNumber(b.inputTokens !== undefined ? b.inputTokens : b.input)
    + nonNegativeNumber(b.outputTokens !== undefined ? b.outputTokens : b.output)
    + nonNegativeNumber(b.cacheReadInputTokens !== undefined ? b.cacheReadInputTokens : b.cacheRead)
    + nonNegativeNumber(b.cacheCreationInputTokens !== undefined ? b.cacheCreationInputTokens : b.cacheWrite)
    + nonNegativeNumber(b.unclassifiedTokens)
}

function calculateCostBreakdown(bucket, rate) {
  var b = bucket || {}
  var r = rate || zeroRate()
  var input = nonNegativeNumber(b.inputTokens !== undefined ? b.inputTokens : b.input)
  var output = nonNegativeNumber(b.outputTokens !== undefined ? b.outputTokens : b.output)
  var cacheRead = nonNegativeNumber(b.cacheReadInputTokens !== undefined ? b.cacheReadInputTokens : b.cacheRead)
  var cacheWrite = nonNegativeNumber(b.cacheCreationInputTokens !== undefined ? b.cacheCreationInputTokens : b.cacheWrite)
  var unclassified = nonNegativeNumber(b.unclassifiedTokens)
  var inCost = (input / 1e6) * nonNegativeNumber(r.input)
  var outCost = (output / 1e6) * nonNegativeNumber(r.output)
  var crCost = (cacheRead / 1e6) * nonNegativeNumber(r.cacheRead)
  var cwCost = (cacheWrite / 1e6) * nonNegativeNumber(r.cacheWrite)
  var total = inCost + outCost + crCost + cwCost
  return {
    total: total,
    inputCost: inCost,
    outputCost: outCost,
    cacheReadCost: crCost,
    cacheWriteCost: cwCost,
    unclassifiedTokens: unclassified,
    rate: r
  }
}

function calculateModelCost(modelId, bucket, customRates) {
  var resolved = resolveModelRate(modelId, customRates)
  var breakdown = calculateCostBreakdown(bucket, resolved.rate)
  breakdown.rated = resolved.rated
  return breakdown
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
