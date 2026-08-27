import QtQuick
import Quickshell
import Quickshell.Io
import "js/Format.js" as Format
import "js/Pricing.js" as Pricing

// The display side of agent usage. All extraction lives behind
// omarchy-agent-usage-update, which writes one JSON record per agent into
// the usage directory; this file only discovers those records, watches them
// for changes, and optionally merges snapshots synced from other machines.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/usage"
  readonly property string pricingConfigPath: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omarchy/agents/pricing.json"

  property var customRates: ({})

  FileView {
    path: root.pricingConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parsePricing(text())
    onLoadFailed: root.customRates = ({})
  }

  function parsePricing(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      var source = parsed && typeof parsed === "object" ? (parsed.models || parsed) : ({})
      var normalized = {}
      for (var modelId in source) normalized[String(modelId).toLowerCase().trim()] = source[modelId]
      root.customRates = normalized
      root.dataRevision++
    } catch (e) {
      root.customRates = ({})
    }
  }

  // ------------------------------------------------------------- discovery

  property var agentIds: []
  property var agents: []
  property int dataRevision: 0

  Process {
    id: listProcess
    running: false
    command: ["find", root.usageDir, "-maxdepth", "1", "-name", "*.json", "-printf", "%f\n"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAgentListing(text)
    }
  }

  function rescanAgents() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyAgentListing(output) {
    var ids = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".json") ids.push(name.slice(0, -5))
    }
    ids.sort()
    // Same list, same objects: reassigning the model would tear down every
    // FileView just to build identical ones.
    if (JSON.stringify(ids) !== JSON.stringify(agentIds)) agentIds = ids
  }

  Instantiator {
    id: agentInstantiator
    model: root.agentIds

    delegate: Agent {
      required property var modelData
      agentId: modelData
      path: root.usageDir + "/" + modelData + ".json"
      onRecordChanged: root.recordsChanged()
    }

    onObjectAdded: (index, object) => root.rebuildAgents()
    onObjectRemoved: (index, object) => root.rebuildAgents()
  }

  function rebuildAgents() {
    var result = []
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) result.push(agent)
    }
    agents = result
    recordsChanged()
  }

  function recordsChanged() {
    dataRevision++
    scheduleLimitsRetry()
    scheduleSync()
  }

  // A collector that could not reach its limits endpoint at all — typically
  // the seconds after login before the network is up — writes retryAdvised
  // into its record. Honor it with one sooner try instead of waiting out the
  // full refresh interval; a run that reaches the endpoint clears the flag.
  // Only the advising agents rerun, so an outage at one provider does not
  // put every other collector on a 30-second treadmill.
  property var retryAgentIds: []

  Timer {
    id: limitsRetry
    interval: 30000
    repeat: false
    onTriggered: root.runUpdate("limits", root.retryAgentIds)
  }

  function scheduleLimitsRetry() {
    var advising = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (record && record.retryAdvised === true && providerEnabled(String(record.id || "")))
        advising.push(String(record.id))
    }
    retryAgentIds = advising
    if (advising.length > 0) limitsRetry.restart()
    else limitsRetry.stop()
  }

  Component.onCompleted: {
    rescanAgents()
    if (syncConfigured()) scheduleSync()
  }

  // -------------------------------------------------------------- refresh

  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 900)))
  property string pendingUpdateKind: ""

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runUpdate("normal")
  }

  Process {
    id: updateProcess
    running: false
    onExited: {
      root.rescanAgents()
      if (root.pendingUpdateKind !== "") {
        var kind = root.pendingUpdateKind
        root.pendingUpdateKind = ""
        root.runUpdate(kind)
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents", text.trim())
    }
  }

  function updateCommand(kind, agentIds) {
    var command = [root.home + "/.config/omarchy/plugins/eipi10.agents/bin/omarchy-agent-usage-update"]
    if (kind === "force") command.push("--force")
    if (kind === "limits") command.push("--limits-only")
    var providers = settings && settings.providers ? settings.providers : {}
    for (var id in providers) {
      if (providers[id] && providers[id].enabled === false) command.push("--except", id)
    }
    if (agentIds) {
      for (var i = 0; i < agentIds.length; i++) command.push(agentIds[i])
    }
    return command
  }

  function runUpdate(kind, agentIds) {
    if (updateProcess.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateProcess.command = updateCommand(kind, agentIds)
    updateProcess.running = true
  }

  function refresh() { refreshAll(true) }
  function refreshAll(force) { runUpdate(force === true ? "force" : "normal") }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk — the collectors reuse their
  // recent scans in this mode.
  function refreshLimits() { runUpdate("limits") }

  // ------------------------------------------------------------- providers

  // An agent earns a place in the bar and the panel by being switched on in
  // settings and having actually produced numbers — locally or on a synced
  // device. With nothing to show, the whole module collapses out of the bar
  // rather than sitting there dimmed.
  property var enabledProviders: {
    var rev = dataRevision
    var syncRev = syncRevision
    var result = []
    var localIds = {}
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      var id = String(record.id)
      localIds[id] = true
      if (!providerEnabled(id)) continue
      var display = displayProvider(record)
      if (providerHasData(display)) result.push(display)
    }
    // An agent that only ever ran on another machine has no local record, but
    // its synced numbers still deserve a tab. Rate limits stay blank — they
    // are per-account and never travel.
    var syncedProviders = syncConfigured() && aggregateData && aggregateData.providers ? aggregateData.providers : {}
    for (var syncedId in syncedProviders) {
      if (localIds[syncedId] || !providerEnabled(syncedId)) continue
      var stats = syncedProviders[syncedId] || {}
      var syncedDisplay = displayProvider({ id: syncedId, name: stats.providerName || syncedId })
      if (providerHasData(syncedDisplay)) result.push(syncedDisplay)
    }
    return result
  }

  function providerEnabled(id) {
    // Removed providers stay removed even if an old synced snapshot or stale
    // local record still contains them.
    if (String(id) === "glm") return false
    if (!settings || !settings.providers || !settings.providers[id]) return true
    return settings.providers[id].enabled !== false
  }

  // All-time keeps a quiet day from hiding an agent; today's counts admit a
  // machine whose only source is history.jsonl, which knows nothing older.
  function providerHasData(p) {
    return numberValue(p.totalPrompts) > 0 || numberValue(p.totalSessions) > 0
      || numberValue(p.activeDays) > 0 || numberValue(p.todayPrompts) > 0
      || numberValue(p.todaySessions) > 0 || (p.limits && p.limits.length > 0)
      || !!p.balance
  }

  // A prepaid agent's credit ledger. Like rate limits, the balance is
  // per-account and never merged across devices.
  function balanceValue(raw) {
    if (!raw || typeof raw !== "object") return null
    var remaining = Number(raw.remaining)
    var funded = Number(raw.funded)
    if (!isFinite(remaining) || remaining < 0) return null
    return {
      remaining: remaining,
      funded: isFinite(funded) && funded > 0 ? funded : 0,
      spent: Math.max(0, Number(raw.spent) || 0),
      currency: String(raw.currency || "USD"),
      estimated: raw.estimated === true
    }
  }

  function tokenMapTotal(map) {
    var total = 0
    for (var modelId in map) total += Pricing.bucketTokenTotal(map[modelId])
    return total
  }

  function completeTodayUsage(stats, providerId) {
    var result = {}
    var detailed = stats.todayModelUsage || {}
    for (var rawId in detailed) {
      var normalizedId = Format.normalizeModelId(rawId)
      var source = detailed[rawId] || {}
      var bucket = result[normalizedId]
      if (!bucket) bucket = result[normalizedId] = emptyTokenBucket()
      bucket.inputTokens += numberValue(source.inputTokens)
      bucket.outputTokens += numberValue(source.outputTokens)
      bucket.cacheReadInputTokens += numberValue(source.cacheReadInputTokens)
      bucket.cacheCreationInputTokens += numberValue(source.cacheCreationInputTokens)
      bucket.unclassifiedTokens += numberValue(source.unclassifiedTokens)
    }

    // Older provider records expose today's total per model but not its
    // input/output/cache split. Keep those tokens visible and explicitly
    // unrated instead of dropping them or inventing a category and price.
    var byModel = stats.todayTokensByModel || {}
    var normalizedTodayTotals = {}
    for (var rawTodayId in byModel) {
      var todayId = Format.normalizeModelId(rawTodayId)
      normalizedTodayTotals[todayId] = numberValue(normalizedTodayTotals[todayId])
        + numberValue(byModel[rawTodayId])
    }
    for (var normalizedTodayId in normalizedTodayTotals) {
      var todayBucket = result[normalizedTodayId]
      if (!todayBucket) todayBucket = result[normalizedTodayId] = emptyTokenBucket()
      var missing = normalizedTodayTotals[normalizedTodayId] - Pricing.bucketTokenTotal(todayBucket)
      if (missing > 0) todayBucket.unclassifiedTokens += missing
    }

    var remaining = numberValue(stats.todayTotalTokens) - tokenMapTotal(result)
    if (remaining > 0) {
      var fallbackId = String(providerId || "unknown") + "/unclassified"
      var fallback = result[fallbackId]
      if (!fallback) fallback = result[fallbackId] = emptyTokenBucket()
      fallback.unclassifiedTokens += remaining
    }
    return result
  }

  function displayProvider(record) {
    var stats = syncedStatsFor(String(record.id))
    var synced = !!stats
    var deviceCount = synced ? Number(stats.deviceCount || aggregateData.deviceCount || 0) : 0
    var usageStats = synced ? stats : record
    var todayUsage = completeTodayUsage(usageStats, record.id)

    return {
      providerId: String(record.id),
      providerName: String(record.name || record.id),
      ready: record.ready === true || synced,
      usageStatusText: String(record.usageStatusText || ""),
      authHelpText: String(record.authHelpText || ""),

      // Rate limits and balances stay per-account and are never merged
      // across devices. All limits are normalized to Remaining Quota (余量 0.0~1.0).
      limits: (function() {
        var rawLimits = Array.isArray(record.limits) ? record.limits : []
        var normalized = []
        var isAgy = String(record.id) === "antigravity"
        for (var li = 0; li < rawLimits.length; li++) {
          var le = rawLimits[li] || {}
          var rawPct = Number(le.percent !== undefined ? le.percent : (le.remaining !== undefined ? le.remaining : 0))
          var rem = (isAgy || le.remaining !== undefined) ? rawPct : Math.max(0, Math.min(1, 1.0 - rawPct))
          normalized.push({
            title: String(le.title || le.label || ""),
            percent: rem,
            remaining: rem,
            resetsAt: String(le.resetsAt || le.reset_time || ""),
            weeklyPercent: le.weeklyPercent !== undefined && le.weeklyPercent !== null ? Number(le.weeklyPercent) : null,
            weeklyResetAt: String(le.weeklyResetAt || "")
          })
        }
        return normalized
      })(),
      tierLabel: String(record.tierLabel || ""),
      balance: balanceValue(record.balance),

      currentAccountId: String(record.currentAccountId || ""),
      currentAccountEmail: String(record.currentAccountEmail || ""),
      accounts: Array.isArray(record.accounts) ? record.accounts : [],
      todayTotalCost: Pricing.calculateTotalCost(todayUsage, root.customRates),
      contributesUsage: usageStats.contributesUsage !== false,

      todayPrompts: numberValue(usageStats.todayPrompts),
      todaySessions: numberValue(usageStats.todaySessions),
      todayTotalTokens: tokenMapTotal(todayUsage),
      todayTokensByModel: usageStats.todayTokensByModel || ({}),
      todayModelUsage: todayUsage,
      recentDays: usageStats.recentDays || [],
      totalPrompts: numberValue(usageStats.totalPrompts),
      totalSessions: numberValue(usageStats.totalSessions),
      activeDays: numberValue(usageStats.activeDays),
      activeDates: usageStats.activeDates || [],
      modelUsage: usageStats.modelUsage || ({}),
      hasLocalStats: usageStats.hasLocalStats !== false,
      hasPromptStats: usageStats.hasPromptStats !== false,

      syncEnabled: synced,
      syncDeviceCount: deviceCount,
      syncUpdatedAt: aggregateData && aggregateData.updatedAt ? aggregateData.updatedAt : ""
    }
  }

  // Unified machine view for the shared sections. Records that only expose a
  // subscription or quota set contributesUsage=false, so their provider tab
  // stays visible without multiplying the authoritative transcript dataset.
  readonly property var aggregateProvider: {
    var pList = enabledProviders
    if (pList.length === 0) return null
    var dayMap = {}
    var modelMap = {}
    var todayModelMap = {}
    var todayModelOwners = ({})
    var dateSet = {}
    var todayPrompts = 0, todaySessions = 0
    var totalPrompts = 0, totalSessions = 0
    var hasStats = false

    function mergeModelMap(dst, src) {
      for (var model in src) {
        var from = src[model] || {}
        var normalizedModel = Format.normalizeModelId(model)
        var to = dst[normalizedModel]
        if (!to) to = dst[normalizedModel] = emptyTokenBucket()
        to.inputTokens += numberValue(from.inputTokens)
        to.outputTokens += numberValue(from.outputTokens)
        to.cacheReadInputTokens += numberValue(from.cacheReadInputTokens)
        to.cacheCreationInputTokens += numberValue(from.cacheCreationInputTokens)
        to.unclassifiedTokens += numberValue(from.unclassifiedTokens)
      }
    }

    function mergeDayModels(dst, src) {
      for (var model in src) {
        var from = src[model] || {}
        var to = dst[model]
        if (!to) to = dst[model] = emptyTokenBucket()
        to.inputTokens += numberValue(from.inputTokens)
        to.outputTokens += numberValue(from.outputTokens)
        to.cacheReadInputTokens += numberValue(from.cacheReadInputTokens)
        to.cacheCreationInputTokens += numberValue(from.cacheCreationInputTokens)
        to.unclassifiedTokens += numberValue(from.unclassifiedTokens)
      }
    }

    for (var i = 0; i < pList.length; i++) {
      var p = pList[i]
      if (p.contributesUsage === false) continue
      todayPrompts += numberValue(p.todayPrompts)
      todaySessions += numberValue(p.todaySessions)
      totalPrompts += numberValue(p.totalPrompts)
      totalSessions += numberValue(p.totalSessions)

      var days = Array.isArray(p.recentDays) ? p.recentDays : []
      for (var d = 0; d < days.length; d++) {
        var row = days[d]
        if (!row || !row.date) continue
        var cell = dayMap[row.date]
        if (!cell) cell = dayMap[row.date] = { date: String(row.date), messageCount: 0, models: {} }
        cell.messageCount += numberValue(row.messageCount)
        var rowModels = row.models || {}
        var detailedDayTokens = tokenMapTotal(rowModels)
        mergeDayModels(cell.models, rowModels)
        var unclassifiedDayTokens = numberValue(row.messageCount) - detailedDayTokens
        if (unclassifiedDayTokens > 0) {
          var dayFallbackId = String(p.providerId || "unknown") + "/unclassified"
          var dayFallback = cell.models[dayFallbackId]
          if (!dayFallback) dayFallback = cell.models[dayFallbackId] = emptyTokenBucket()
          dayFallback.unclassifiedTokens += unclassifiedDayTokens
        }
      }

      mergeModelMap(modelMap, p.modelUsage || {})
      mergeModelMap(todayModelMap, p.todayModelUsage || {})

      var todaySrc = p.todayModelUsage || {}
      for (var ownerId in todaySrc) {
        var normalizedOwnerId = Format.normalizeModelId(ownerId)
        if (!todayModelOwners[normalizedOwnerId]) todayModelOwners[normalizedOwnerId] = p.providerName
        else if (todayModelOwners[normalizedOwnerId].indexOf(p.providerName) < 0) todayModelOwners[normalizedOwnerId] += " / " + p.providerName
      }

      var activeDates = Array.isArray(p.activeDates) ? p.activeDates : []
      for (var a = 0; a < activeDates.length; a++) dateSet[String(activeDates[a])] = true

      if (p.hasLocalStats !== false) hasStats = true
    }

    var recentDays = []
    for (var dateKey in dayMap) recentDays.push(dayMap[dateKey])
    recentDays.sort(function(a, b) { return a.date < b.date ? -1 : (a.date > b.date ? 1 : 0) })
    if (recentDays.length > 7) recentDays = recentDays.slice(-7)

    var activeDates = []
    for (var dateKey in dateSet) activeDates.push(dateKey)
    activeDates.sort()

    var todayTotalTokens = 0
    var todayUnratedTokens = 0
    var normalizedTodayByModel = {}
    for (var todayModelId in todayModelMap) {
      var modelTokens = Pricing.bucketTokenTotal(todayModelMap[todayModelId])
      var modelCost = Pricing.calculateModelCost(todayModelId, todayModelMap[todayModelId], root.customRates)
      todayTotalTokens += modelTokens
      todayUnratedTokens += modelCost.rated
        ? numberValue(todayModelMap[todayModelId].unclassifiedTokens)
        : modelTokens
      normalizedTodayByModel[todayModelId] = modelTokens
    }
    var todayTotalCost = Pricing.calculateTotalCost(todayModelMap, root.customRates)

    return {
      providerId: "aggregate",
      providerName: "All Agents",
      ready: true,
      usageStatusText: "",
      authHelpText: "",
      limits: [],
      tierLabel: "",
      balance: null,
      currentAccountId: "",
      currentAccountEmail: "",
      accounts: [],
      todayPrompts: todayPrompts,
      todaySessions: todaySessions,
      todayTotalTokens: todayTotalTokens,
      todayUnratedTokens: todayUnratedTokens,
      todayTotalCost: todayTotalCost,
      todayTokensByModel: normalizedTodayByModel,
      todayModelUsage: todayModelMap,
      todayModelOwners: todayModelOwners,
      recentDays: recentDays,
      totalPrompts: totalPrompts,
      totalSessions: totalSessions,
      activeDays: activeDates.length,
      activeDates: activeDates,
      modelUsage: modelMap,
      agentCount: pList.length,
      hasLocalStats: hasStats,
      hasPromptStats: true,
      syncEnabled: false,
      syncDeviceCount: 0,
      syncUpdatedAt: ""
    }
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ------------------------------------------------------------------ sync

  property var syncModeSetting: setting("syncMode", setting("syncEnabled", false))
  property bool syncEnabled: parseSyncEnabled(syncModeSetting)
  property string syncDir: String(setting("syncDir", ""))
  property string syncFileName: String(setting("syncFileName", ""))
  property string syncDeviceId: String(setting("syncDeviceId", ""))
  property string detectedHostname: ""
  readonly property string syncEffectiveDir: expandPath(syncDir)
  readonly property string syncEffectiveFileName: safeSnapshotFileName(syncFileName, syncDeviceId)
  readonly property string syncEffectiveDeviceId: safeDeviceId(syncDeviceId || syncEffectiveFileName.replace(/\.json$/i, ""))
  readonly property string syncSnapshotPath: syncConfigured() ? syncEffectiveDir + "/" + syncEffectiveFileName : home + "/.cache/omarchy/agents-disabled.json"
  property var aggregateData: ({})
  property int syncRevision: 0
  property bool syncRunning: false
  property bool syncRequestedWhileRunning: false
  property string syncStatusText: ""
  property double aggregateUpdatedAtMs: aggregateData && aggregateData.updatedAtMs ? Number(aggregateData.updatedAtMs) : 0

  onSyncEnabledChanged: syncSettingsChanged()
  onSyncDirChanged: syncSettingsChanged()
  onSyncFileNameChanged: if (syncConfigured()) scheduleSync()
  onSyncDeviceIdChanged: if (syncConfigured()) scheduleSync()

  Timer {
    id: syncDebounce
    interval: 1000
    repeat: false
    onTriggered: root.runSync()
  }

  Process {
    id: syncMkdirProcess
    running: false
    onRunningChanged: root.updateSyncRunning()
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (root.syncConfigured()) root.syncStatusText = "Usage sync mkdir failed"
        root.finishSyncRun()
        return
      }
      root.writeSyncSnapshot()
    }
  }

  Process {
    id: syncScanProcess
    running: false
    onRunningChanged: root.updateSyncRunning()
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.syncConfigured()) root.syncStatusText = "Usage sync scan failed"
      root.finishSyncRun()
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseSyncScanOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents/sync", text.trim())
    }
  }

  FileView {
    id: syncSnapshotFile
    path: root.syncSnapshotPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    watchChanges: false
    printErrors: false
    onLoaded: root.detectedHostname = String(text() || "").trim()
  }

  function parseSyncEnabled(value) {
    if (value === true) return true
    var text = String(value || "").trim().toLowerCase()
    return text === "on" || text === "enabled" || text === "true" || text === "yes" || text === "1"
  }

  function syncConfigured() {
    return root.syncEnabled === true && String(root.syncDir || "").trim() !== ""
  }

  function syncSettingsChanged() {
    if (syncConfigured()) {
      scheduleSync()
    } else {
      syncDebounce.stop()
      syncRequestedWhileRunning = false
      aggregateData = ({})
      syncStatusText = ""
      syncRevision++
    }
  }

  function updateSyncRunning() {
    root.syncRunning = syncMkdirProcess.running || syncScanProcess.running
  }

  function scheduleSync() {
    if (!syncConfigured()) return
    syncDebounce.restart()
  }

  function runSync() {
    if (!syncConfigured()) return
    if (root.syncRunning) {
      syncRequestedWhileRunning = true
      return
    }

    syncRequestedWhileRunning = false
    syncStatusText = ""
    syncMkdirProcess.command = ["mkdir", "-p", root.syncEffectiveDir]
    syncMkdirProcess.running = true
  }

  function writeSyncSnapshot() {
    if (!syncConfigured()) {
      finishSyncRun()
      return
    }
    syncSnapshotFile.setText(JSON.stringify(localSnapshot(), null, 2) + "\n")
    Qt.callLater(root.startSyncScan)
  }

  function startSyncScan() {
    if (!syncConfigured()) {
      finishSyncRun()
      return
    }
    var script = "dir=$0; [[ -d \"$dir\" ]] || exit 0; shopt -s nullglob; for f in \"$dir\"/*.json; do [[ -f \"$f\" ]] || continue; printf '===%s===\\n' \"$f\"; cat \"$f\"; printf '\\n=== EOM ===\\n'; done"
    syncScanProcess.command = ["bash", "-c", script, root.syncEffectiveDir]
    syncScanProcess.running = true
  }

  function finishSyncRun() {
    if (syncRequestedWhileRunning && syncConfigured()) {
      syncRequestedWhileRunning = false
      scheduleSync()
    }
  }

  function expandPath(path) {
    var value = String(path || "").trim()
    if (value === "") return ""
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.substring(1)
    if (value.indexOf("$HOME/") === 0) return home + value.substring(5)
    if (value.charAt(0) !== "/") return home + "/" + value
    return value
  }

  function safeDeviceId(raw) {
    var value = String(raw || "").trim()
    if (value === "") value = Quickshell.env("HOSTNAME") || root.detectedHostname || Quickshell.env("HOST") || Quickshell.env("USER") || "device"
    value = value.replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^[._-]+|[._-]+$/g, "")
    if (value === "") value = "device"
    return value.length > 80 ? value.substring(0, 80) : value
  }

  function safeSnapshotFileName(rawFileName, rawDeviceId) {
    var value = String(rawFileName || "").trim()
    if (value === "") value = safeDeviceId(rawDeviceId) + ".json"
    value = value.split("/").pop().replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^[._-]+|[._-]+$/g, "")
    if (value === "") value = safeDeviceId(rawDeviceId) + ".json"
    if (!/\.json$/i.test(value)) value += ".json"
    return value.length > 100 ? value.substring(0, 95) + ".json" : value
  }

  function parseSyncScanOutput(output) {
    var lines = String(output || "").split("\n")
    var snapshots = []
    var currentPath = ""
    var currentJson = []

    function flush() {
      if (currentPath === "") return
      var raw = currentJson.join("\n").trim()
      try {
        var parsed = JSON.parse(raw)
        if (parsed && parsed.providers) snapshots.push(parsed)
      } catch (e) {
        console.warn("agents/sync", "Ignoring bad snapshot", currentPath, e)
      }
      currentPath = ""
      currentJson = []
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var start = line.match(/^===(.+)===$/)
      if (start && line !== "=== EOM ===") {
        flush()
        currentPath = start[1]
        currentJson = []
        continue
      }
      if (line === "=== EOM ===") {
        flush()
        continue
      }
      if (currentPath !== "") currentJson.push(line)
    }
    flush()

    aggregateData = aggregateSnapshots(snapshots)
    syncStatusText = ""
    syncRevision++
  }

  function cloneValue(value, fallback) {
    if (value === undefined || value === null) return fallback
    try {
      return JSON.parse(JSON.stringify(value))
    } catch (e) {
      return fallback
    }
  }

  function numberValue(value) {
    var n = Number(value || 0)
    return isFinite(n) ? Math.round(n) : 0
  }

  function dateString(date) {
    var y = date.getFullYear()
    var m = String(date.getMonth() + 1).padStart(2, "0")
    var d = String(date.getDate()).padStart(2, "0")
    return y + "-" + m + "-" + d
  }

  function recentDateStrings() {
    var result = []
    for (var offset = 6; offset >= 0; offset--) {
      var date = new Date()
      date.setDate(date.getDate() - offset)
      result.push(dateString(date))
    }
    return result
  }

  function emptyTokenBucket() {
    return {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadInputTokens: 0,
      cacheCreationInputTokens: 0,
      unclassifiedTokens: 0
    }
  }

  // Device-scoped stats add up across machines; account-scoped stats
  // (Fireworks' billing API) are replicas of the same upstream truth on
  // every synced device, so the widest value wins — summing them would
  // double every token per machine.
  function combineNumber(additive, current, value) {
    return additive ? numberValue(current) + numberValue(value) : Math.max(numberValue(current), numberValue(value))
  }

  function combineObjectNumbers(additive, target, source) {
    if (!source) return
    for (var key in source) target[key] = combineNumber(additive, target[key], source[key])
  }

  function aggregateSnapshots(snapshots) {
    var dates = recentDateStrings()
    var devices = {}
    var providers = {}

    function providerAcc(id) {
      if (providers[id]) return providers[id]
      var recentByDay = {}
      var recentModelsByDay = {}
      for (var d = 0; d < dates.length; d++) {
        recentByDay[dates[d]] = 0
        recentModelsByDay[dates[d]] = ({})
      }
      providers[id] = {
        providerId: id,
        providerName: "",
        ready: false,
        hasLocalStats: false,
        hasPromptStats: false,
        contributesUsage: true,
        todayPrompts: 0,
        todaySessions: 0,
        todayTotalTokens: 0,
        todayTokensByModel: ({}),
        todayModelUsage: ({}),
        recentByDay: recentByDay,
        recentModelsByDay: recentModelsByDay,
        totalPrompts: 0,
        totalSessions: 0,
        activeDays: 0,
        activeDates: ({}),
        modelUsage: ({}),
        devices: ({})
      }
      return providers[id]
    }

    for (var i = 0; i < snapshots.length; i++) {
      var snapshot = snapshots[i]
      var device = safeDeviceId(snapshot.deviceId || "device")
      devices[device] = true
      var snapshotProviders = snapshot.providers || {}
      for (var providerId in snapshotProviders) {
        var stats = snapshotProviders[providerId] || {}
        var acc = providerAcc(String(providerId))
        acc.devices[device] = true
        if (stats.providerName && acc.providerName === "") acc.providerName = String(stats.providerName)
        acc.ready = acc.ready || stats.ready === true
        acc.hasLocalStats = acc.hasLocalStats || stats.hasLocalStats !== false
        // Snapshots from before the field existed only came from agents that
        // count prompts, so a missing value reads as true.
        acc.hasPromptStats = acc.hasPromptStats || stats.hasPromptStats !== false
        acc.contributesUsage = acc.contributesUsage && stats.contributesUsage !== false
        var additive = String(stats.scope || "device") !== "account"
        acc.todayPrompts = combineNumber(additive, acc.todayPrompts, stats.todayPrompts)
        acc.todaySessions = combineNumber(additive, acc.todaySessions, stats.todaySessions)
        acc.todayTotalTokens = combineNumber(additive, acc.todayTotalTokens, stats.todayTotalTokens)
        acc.totalPrompts = combineNumber(additive, acc.totalPrompts, stats.totalPrompts)
        acc.totalSessions = combineNumber(additive, acc.totalSessions, stats.totalSessions)
        // Active days overlap between machines, so union the dates rather than
        // summing counts. Snapshots written before activeDates existed only
        // carry a count; the widest one stands in for them.
        var activeDates = Array.isArray(stats.activeDates) ? stats.activeDates : []
        for (var ad = 0; ad < activeDates.length; ad++) acc.activeDates[String(activeDates[ad])] = true
        acc.activeDays = Math.max(acc.activeDays, numberValue(stats.activeDays))
        var todayTokens = stats.todayTokensByModel || {}
        for (var tModel in todayTokens) {
          var normTModel = Format.normalizeModelId(tModel)
          acc.todayTokensByModel[normTModel] = combineNumber(additive, acc.todayTokensByModel[normTModel], todayTokens[tModel])
        }

        var todayUsage = stats.todayModelUsage || {}
        for (var todayModelId in todayUsage) {
          var normTodayModelId = Format.normalizeModelId(todayModelId)
          var todayBucket = acc.todayModelUsage[normTodayModelId]
          if (!todayBucket) todayBucket = acc.todayModelUsage[normTodayModelId] = emptyTokenBucket()
          combineObjectNumbers(additive, todayBucket, todayUsage[todayModelId] || {})
        }

        var recent = Array.isArray(stats.recentDays) ? stats.recentDays : []
        for (var r = 0; r < recent.length; r++) {
          var day = recent[r] || {}
          var date = String(day.date || "")
          if (acc.recentByDay[date] !== undefined) {
            acc.recentByDay[date] = combineNumber(additive, acc.recentByDay[date], day.messageCount)
            var dayModels = day.models || {}
            for (var dayModelId in dayModels) {
              var normDayModelId = Format.normalizeModelId(dayModelId)
              var dayBucket = acc.recentModelsByDay[date][normDayModelId]
              if (!dayBucket) dayBucket = acc.recentModelsByDay[date][normDayModelId] = emptyTokenBucket()
              combineObjectNumbers(additive, dayBucket, dayModels[dayModelId] || {})
            }
          }
        }

        var usage = stats.modelUsage || {}
        for (var modelId in usage) {
          var normModelId = Format.normalizeModelId(modelId)
          var bucket = acc.modelUsage[normModelId]
          if (!bucket) bucket = acc.modelUsage[normModelId] = emptyTokenBucket()
          combineObjectNumbers(additive, bucket, usage[modelId] || {})
        }
      }
    }

    var outProviders = {}
    for (var id in providers) {
      var acc = providers[id]
      var recentDays = []
      for (var di = 0; di < dates.length; di++) {
        recentDays.push({
          date: dates[di],
          messageCount: acc.recentByDay[dates[di]] || 0,
          models: acc.recentModelsByDay[dates[di]] || {}
        })
      }
      var providerDevices = Object.keys(acc.devices).sort()
      outProviders[id] = {
        providerId: acc.providerId,
        providerName: acc.providerName,
        ready: acc.ready || providerDevices.length > 0,
        hasLocalStats: acc.hasLocalStats,
        hasPromptStats: acc.hasPromptStats,
        contributesUsage: acc.contributesUsage,
        todayPrompts: acc.todayPrompts,
        todaySessions: acc.todaySessions,
        todayTotalTokens: acc.todayTotalTokens,
        todayTokensByModel: acc.todayTokensByModel,
        todayModelUsage: acc.todayModelUsage,
        recentDays: recentDays,
        totalPrompts: acc.totalPrompts,
        totalSessions: acc.totalSessions,
        activeDays: Math.max(acc.activeDays, Object.keys(acc.activeDates).length),
        modelUsage: acc.modelUsage,
        deviceCount: providerDevices.length,
        devices: providerDevices
      }
    }

    return {
      schemaVersion: 1,
      updatedAt: new Date().toISOString(),
      updatedAtMs: Date.now(),
      deviceCount: Object.keys(devices).length,
      devices: Object.keys(devices).sort(),
      providers: outProviders
    }
  }

  // Snapshots keep the field names older Omarchy versions wrote, so a fleet
  // of machines on mixed versions still merges cleanly in both directions.
  function providerSnapshot(record) {
    return {
      providerId: String(record.id),
      providerName: String(record.name || record.id),
      ready: record.ready === true,
      hasLocalStats: record.hasLocalStats !== false,
      hasPromptStats: record.hasPromptStats !== false,
      contributesUsage: record.contributesUsage !== false,
      scope: String(record.scope || "device"),
      todayPrompts: numberValue(record.todayPrompts),
      todaySessions: numberValue(record.todaySessions),
      todayTotalTokens: numberValue(record.todayTotalTokens),
      todayTokensByModel: cloneValue(record.todayTokensByModel, ({})),
      todayModelUsage: cloneValue(record.todayModelUsage, ({})),
      recentDays: cloneValue(record.recentDays, []),
      totalPrompts: numberValue(record.totalPrompts),
      totalSessions: numberValue(record.totalSessions),
      activeDays: numberValue(record.activeDays),
      activeDates: cloneValue(record.activeDates, []),
      modelUsage: cloneValue(record.modelUsage, ({}))
    }
  }

  function localSnapshot() {
    var providerMap = {}
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      if (!providerEnabled(String(record.id))) continue
      providerMap[String(record.id)] = providerSnapshot(record)
    }
    return {
      schemaVersion: 1,
      deviceId: syncEffectiveDeviceId,
      updatedAt: new Date().toISOString(),
      providers: providerMap
    }
  }

  function syncedStatsFor(providerId) {
    var rev = syncRevision
    if (!syncConfigured() || !aggregateData || !aggregateData.providers) return null
    return aggregateData.providers[providerId] || null
  }

  // ---------------------------------------------------------------- format
  function formatTokenCount(n) { return Format.formatTokenCount(n) }
  function modelWordCase(word) { return Format.modelWordCase(word) }
  function friendlyModelName(id) { return Format.friendlyModelName(id) }
}
