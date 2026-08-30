import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Core of Omarvoice: recording, live input level metering, Antigravity cloud
// dictation, text cleaning, history, settings, clipboard, and push-to-talk IPC.
//
// All state transitions run through `state`:
//   idle -> arming -> recording -> transcribing -> idle
// `arming` means the resident service is starting live microphone capture.
// Errors return to idle and are classified
// separately by `errorKind` so the bar never confuses stale failures with an
// active recording.
//
// Live level: PwNodePeakMonitor watches the default audio source node. While
// recording, a 33ms timer two-pole smooths the raw peak (attack via
// `peakTarget`, decay via `level`) and pushes it into the rolling `barLevels`
// history the widget renders as a segmented meter.
//
// The V4 QML JS engine has no lookbehind, no Unicode property escapes
// (\p{...}) and no ES2018 regex flags, so the transcript cleaner is written
// with explicit character classes and capture-group prefixes instead.
// Root is an Item (not QtObject): QtObject has no default property to hold
// the nested Timer/CaptureSession/Process/IpcHandler components.
Item {
  id: root

  // ------------------------------------------------------------- constants
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string settingsDir: homeDir + "/.config/XiezhaoPan"
  readonly property string settingsFile: settingsDir + "/qwen-asr-qt.conf"
  readonly property string historyDir: homeDir + "/.local/share/XiezhaoPan/qwen-asr-qt"
  readonly property string historyFile: historyDir + "/transcripts.txt"
  readonly property string diagnosticsFile: historyDir + "/diagnostics.jsonl"
  readonly property string recordingsDir: historyDir + "/recordings"
  readonly property string model: "antigravity-cloud"
  readonly property string bridgeBinary: homeDir + "/.config/omarchy/plugins/qwen-asr/bin/omarvoice-antigravity"
  readonly property int minRecordingMs: 1000

  // ---------------------------------------------------------------- state
  property string state: "idle" // idle | arming | recording | transcribing
  property string lastError: ""
  property string errorKind: "" // "" | offline | input | recording | auth | asr
  property string lastTranscript: ""
  property bool authReady: false
  property string authState: "checking" // checking | ready | authorizing | reauthorize | error
  property string authMessage: "正在检查 Agent Panel 鉴权…"
  property string authAccount: ""
  property int authPollCount: 0
  property bool serviceReady: false
  property string recordingRecoveryReason: ""
  property int elapsedSec: 0
  property var recent: [] // [{time, text}] most recent first, max 10

  // Per-transcription timing context. Diagnostic entries intentionally exclude
  // OAuth material, audio content, and transcript text.
  property string diagnosticTraceId: ""
  property string diagnosticStage: "idle"
  property double diagnosticPipelineStartMs: 0
  property double diagnosticStageStartMs: 0
  property double diagnosticApiStartMs: 0
  property int diagnosticAudioBytes: 0
  property int diagnosticRequestCount: 0
  property var diagnosticQueue: []

  // ----------------------------------------------------------- HUD & Features
  property bool autoPaste: true
  property bool showHud: true
  property bool hudVisible: false
  property string hudStatus: "idle" // idle | arming | recording | transcribing | success | error
  property string hudMessage: ""
  readonly property string activeMicName: Pipewire.defaultAudioSource ? (Pipewire.defaultAudioSource.description || Pipewire.defaultAudioSource.name || "默认麦克风") : "未检测到麦克风"

  // ------------------------------------------------------------- shortcut
  property string currentShortcut: "F9"
  readonly property string currentShortcutDisplay: root.friendlyShortcutName(root.currentShortcut)
  readonly property bool isMouseShortcut: root.currentShortcut.indexOf("mouse:") >= 0

  function loadShortcut() {
    shortcutReadProc.command = ["bash", "-c",
      "p=" + shellQuote(root.homeDir + "/.config/omarchy/plugins/qwen-asr/bin/qwen-asr-ctl") + "; "
      + "if [ -x \"$p\" ]; then \"$p\" get-shortcut; "
      + "elif [ -x \"$HOME/work/projects/omarchy_plugins/omarchy-plugins/plugins/qwen-asr/bin/qwen-asr-ctl\" ]; then \"$HOME/work/projects/omarchy_plugins/omarchy-plugins/plugins/qwen-asr/bin/qwen-asr-ctl\" get-shortcut; "
      + "fi"]
    shortcutReadProc.running = true
  }

  function setShortcut(newKey, callback) {
    var k = String(newKey || "").trim()
    if (k === "") return "快捷键不能为空"
    shortcutWriteProc.callback = callback
    shortcutWriteProc.targetKey = k
    shortcutWriteProc.command = ["bash", "-c",
      "p=" + shellQuote(root.homeDir + "/.config/omarchy/plugins/qwen-asr/bin/qwen-asr-ctl") + "; "
      + "if [ -x \"$p\" ]; then \"$p\" set-shortcut " + shellQuote(k) + "; "
      + "elif [ -x \"$HOME/work/projects/omarchy_plugins/omarchy-plugins/plugins/qwen-asr/bin/qwen-asr-ctl\" ]; then \"$HOME/work/projects/omarchy_plugins/omarchy-plugins/plugins/qwen-asr/bin/qwen-asr-ctl\" set-shortcut " + shellQuote(k) + "; "
      + "fi"]
    shortcutWriteProc.running = true
    return "ok"
  }

  function friendlyShortcutName(key) {
    if (!key || key === "") return "未设置"
    var s = String(key).trim()
    var parts = s.split("+").map(function(p) { return p.trim() })
    var names = parts.map(function(p) {
      if (p === "mouse:275") return "鼠标后退侧键 (Mouse 4)"
      if (p === "mouse:276") return "鼠标前进侧键 (Mouse 5)"
      if (p === "mouse:274") return "鼠标中键 (Mouse 3)"
      if (p === "mouse:273") return "鼠标右键 (Mouse 2)"
      if (p === "mouse:272") return "鼠标左键 (Mouse 1)"
      if (p === "mouse:277") return "鼠标扩展键 (Mouse 6)"
      if (p === "mouse:278") return "鼠标扩展键 (Mouse 7)"
      if (p === "mouse:279") return "鼠标扩展键 (Mouse 8)"
      if (p === "SUPER") return "Super"
      if (p === "CTRL") return "Ctrl"
      if (p === "ALT") return "Alt"
      if (p === "SHIFT") return "Shift"
      if (p === "SPACE") return "空格 (Space)"
      if (p === "Return") return "回车 (Enter)"
      return p
    })
    return names.join(" + ")
  }

  function shortcutIcon(key) {
    if (!key) return "󰌌"
    return String(key).indexOf("mouse:") >= 0 ? "󰍽" : "󰌌"
  }

  Timer {
    id: hudDismissTimer
    interval: 1200
    repeat: false
    onTriggered: {
      root.hudVisible = false
      root.hudStatus = "idle"
    }
  }



  // ----------------------------------------------------------- level meter
  property int barCount: 10
  property real noiseFloor: 0.0
  property real level: 0.0 // smoothed instantaneous input level, 0..1
  property real peakTarget: 0.0 // attack-smoothed raw peak feeding `level`
  property var barLevels: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] // rolling history, oldest first, length <= barCount

  PwNodePeakMonitor {
    id: peakMonitor
    node: Pipewire.defaultAudioSource
    enabled: true // Keep background warm so there's zero cold-start delay or DC offset spike
  }

  Timer {
    id: levelTimer
    interval: (root.state === "recording" || root.state === "arming") ? 33 : 250
    repeat: true
    running: true
    onTriggered: root.tickLevel()
  }

  function tickLevel() {
    var raw = peakMonitor.peak || 0
    if (raw <= 0) return

    // Continuously maintain background ambient baseline
    if (root.noiseFloor <= 0) {
      root.noiseFloor = raw
    } else if (raw < root.noiseFloor) {
      root.noiseFloor = root.noiseFloor * 0.70 + raw * 0.30
    } else if (root.state !== "recording") {
      // Idle / Arming: fast convergence to true room ambient level
      root.noiseFloor = root.noiseFloor * 0.90 + raw * 0.10
    } else {
      // Active recording: slowly follow ambient noise floor (ignoring speech phoneme spikes)
      root.noiseFloor = root.noiseFloor * 0.992 + raw * 0.008
    }

    if (root.state !== "recording") return

    // Active speech signal above ambient baseline
    var delta = Math.max(0, raw - root.noiseFloor)
    var norm = Math.min(1.0, Math.max(0, delta - 0.015) / 0.16)
    var scaled = Math.pow(norm, 0.75)

    // Snappy attack on phonemes, smooth decay on pauses
    if (scaled > root.peakTarget) {
      root.peakTarget = root.peakTarget * 0.15 + scaled * 0.85
    } else {
      root.peakTarget = root.peakTarget * 0.65 + scaled * 0.35
    }
    root.level = root.peakTarget

    var arr = root.barLevels.concat(root.level)
    if (arr.length > root.barCount) arr = arr.slice(arr.length - root.barCount)
    root.barLevels = arr
  }

  function resetLevel() {
    // Keep root.noiseFloor intact so recording starts immediately calibrated!
    root.level = 0
    root.peakTarget = 0
    root.barLevels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  }

  // ------------------------------------------------------ settings & auth
  function loadSettings() {
    settingsReadProc.command = ["bash", "-c",
      "f=" + shellQuote(root.settingsFile) + "; "
      + "if [ -f \"$f\" ]; then "
      + "  ap=$(grep -E '^[[:space:]]*autoPaste[[:space:]]*=' \"$f\" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]'); "
      + "  sh=$(grep -E '^[[:space:]]*showHud[[:space:]]*=' \"$f\" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]'); "
      + "  printf '%s\\n%s\\n' \"$ap\" \"$sh\"; "
      + "fi"]
    settingsReadProc.running = true
  }

  function loadAuthStatus() {
    if (authStatusProc.running) return
    root.authState = root.authState === "authorizing" ? "authorizing" : "checking"
    authStatusProc.command = [root.bridgeBinary, "status"]
    authStatusProc.running = true
  }

  function beginAuthorization() {
    if (authorizeProc.running) return
    root.authReady = false
    root.authState = "authorizing"
    root.authMessage = "等待浏览器授权…"
    root.authPollCount = 0
    authorizeProc.command = [root.bridgeBinary, "authorize"]
    authorizeProc.running = true
  }

  function warmService() {
    if (!root.authReady || warmupProc.running) return
    warmupProc.command = [root.bridgeBinary, "warmup"]
    warmupProc.running = true
  }

  function reconcileServiceRecording() {
    if (daemonStatusProc.running) return
    daemonStatusProc.command = [root.bridgeBinary, "daemon-status"]
    daemonStatusProc.running = true
  }

  function cancelOrphanedRecording(reason) {
    if (recordingRecoveryProc.running) return
    root.recordingRecoveryReason = reason || "startup"
    recordingRecoveryProc.command = [root.bridgeBinary, "record-cancel"]
    recordingRecoveryProc.running = true
  }

  function setAutoPaste(enabled) {
    root.autoPaste = enabled
    writeConfigKey("autoPaste", enabled ? "true" : "false", null)
  }

  function setShowHud(enabled) {
    root.showHud = enabled
    writeConfigKey("showHud", enabled ? "true" : "false", null)
  }

  function writeConfigKey(keyName, val, callback) {
    keyWriteProc.callback = callback
    keyWriteProc.command = ["bash", "-c",
      "f=" + shellQuote(root.settingsFile) + "; mkdir -p " + shellQuote(root.settingsDir)
      + " && umask 077 && awk -v key=" + shellQuote(keyName) + " -v val=" + shellQuote(val) + " '"
      + "BEGIN { seen = 0; ins = 0 }"
      + "/^[[:space:]]*\\[asr\\][[:space:]]*$/ { seen = 1; print; next }"
      + "seen && !ins && $0 ~ (\"^[[:space:]]*\" key \"[[:space:]]*=\") { print key \"=\" val; ins = 1; next }"
      + "seen && /^[[:space:]]*\\[/ && !ins { print key \"=\" val; ins = 1; seen = 0 }"
      + "{ print }"
      + "END { if (!ins) { if (seen) print key \"=\" val; else print \"[asr]\\n\" key \"=\" val } }"
      + "' \"$f\" > \"$f.tmp\" && mv \"$f.tmp\" \"$f\" && chmod 600 \"$f\""]
    keyWriteProc.running = true
  }

  // ------------------------------------------------------------- recording
  property string recPath: ""
  property double recordStartMs: 0
  property bool discardNextStop: false
  property bool stopWhenReady: false

  // Runs only while recording so it freezes at the final audio duration when transcribing.
  Timer {
    id: recTimer
    interval: 1000
    repeat: true
    running: root.state === "recording"
    onTriggered: root.elapsedSec++
  }

  function startRecording() {
    if (root.state !== "idle") return
    root.clearError()

    if (!root.authReady) {
      root.loadAuthStatus()
      root.fail(root.authMessage || "Agent Panel 鉴权尚未就绪", "auth")
      return
    }

    if (!Pipewire.defaultAudioSource) {
      root.fail("未检测到可用的录音设备，请检查麦克风", "recording")
      return
    }

    var now = Date.now()
    var name = "omarvoice-" + now + ".wav"
    root.recPath = root.recordingsDir + "/" + name
    root.recordStartMs = now
    root.discardNextStop = false
    root.stopWhenReady = false
    root.elapsedSec = 0
    root.resetLevel()
    root.state = "arming"
    root.hudStatus = "arming"
    root.hudVisible = true
    hudDismissTimer.stop()

    root.diagnosticTraceId = name.slice(0, -4)
    root.diagnosticStage = "live_start"
    root.diagnosticPipelineStartMs = now
    root.diagnosticStageStartMs = now
    root.diagnosticApiStartMs = 0
    root.diagnosticAudioBytes = 0
    root.diagnosticRequestCount = 0
    root.appendDiagnostic("pipeline_started", {
      model: root.model,
      mode: "live_stream"
    })

    recordStartProc.command = [root.bridgeBinary, "record-start", root.recPath]
    recordStartProc.contextPath = root.recPath
    recordStartProc.running = true
  }

  function stopRecording() {
    if (root.state !== "arming" && root.state !== "recording") return
    if (Date.now() - root.recordStartMs < root.minRecordingMs) {
      root.discardNextStop = true
      root.hudVisible = false
      root.hudStatus = "idle"
    }
    if (root.state === "arming") {
      root.stopWhenReady = true
      return
    }
    root.stopLiveRecording()
  }

  function onLiveStartFinished(output, path, ok) {
    var result = parseBridgeResult(output)
    root.appendDiagnostic("stage_finished", {
      stage: "live_start",
      duration_ms: Math.round(Date.now() - root.diagnosticStageStartMs),
      outcome: ok && result && result.status === "recording" ? "success" : "error",
      service_start_ms: result ? Number(result.start_ms || 0) : 0
    })
    if (!ok || !result || result.status !== "recording") {
      var message = result ? String(result.message || "无法启动实时听写")
        : "Omarvoice 常驻服务没有返回有效结果"
      if (result && result.code === "recording_busy") {
        message = "检测到上次中断的录音，正在自动停止"
        root.cancelOrphanedRecording("recording_busy")
      }
      root.recPath = ""
      root.stopWhenReady = false
      root.fail(message + "；WAV 已保留", "recording")
      return
    }
    root.serviceReady = true
    root.state = "recording"
    root.hudStatus = "recording"
    if (root.stopWhenReady) {
      root.stopWhenReady = false
      root.stopLiveRecording()
    }
  }

  function stopLiveRecording() {
    if (recordStopProc.running) return
    root.state = "transcribing"
    if (!root.discardNextStop) {
      root.hudStatus = "transcribing"
      root.hudVisible = true
    }
    hudDismissTimer.stop()
    root.diagnosticStage = "cloud_finalize"
    root.diagnosticStageStartMs = Date.now()
    root.diagnosticApiStartMs = root.diagnosticStageStartMs
    root.appendDiagnostic("request_started", {
      attempt: 1,
      provider: root.model,
      phase: "release_to_final"
    })
    recordStopProc.command = [
      root.bridgeBinary,
      root.discardNextStop ? "record-cancel" : "record-stop"
    ]
    recordStopProc.contextPath = root.recPath
    recordStopProc.running = true
  }

  function parseBridgeResult(output) {
    try { return JSON.parse(String(output || "").trim()) }
    catch (e) { return null }
  }

  function onLiveStopFinished(output, path, ok) {
    var result = parseBridgeResult(output)
    var elapsedMs = Math.round(Date.now() - root.diagnosticApiStartMs)
    root.recPath = ""
    root.stopWhenReady = false
    root.diagnosticAudioBytes = result ? Number(result.audio_bytes || 0) : 0
    root.diagnosticRequestCount = result ? Number(result.request_count || 0) : 0

    if (root.discardNextStop) {
      root.discardNextStop = false
      root.appendDiagnostic("pipeline_finished", {
        outcome: "cancelled",
        total_ms: Math.round(Date.now() - root.diagnosticPipelineStartMs),
        post_release_ms: elapsedMs,
        audio_bytes: root.diagnosticAudioBytes
      })
      root.diagnosticTraceId = ""
      root.diagnosticStage = "idle"
      root.state = "idle"
      root.hudVisible = false
      root.hudStatus = "idle"
      removeFile(path)
      return
    }

    if (!ok || !result || result.status !== "success") {
      var code = result ? String(result.code || "provider_error") : "bridge_error"
      var message = result ? String(result.message || "Omarvoice 云端听写失败")
        : "Omarvoice 常驻服务没有返回有效结果"
      root.appendDiagnostic("request_finished", {
        attempt: 1,
        duration_ms: elapsedMs,
        outcome: code,
        audio_bytes: root.diagnosticAudioBytes,
        audio_duration_ms: Number(result ? (result.audio_duration_ms || 0) : 0),
        detected_speech_ms: Number(result ? (result.detected_speech_ms || 0) : 0),
        cloud_requests: root.diagnosticRequestCount,
        timings: result ? (result.timings || {}) : {}
      })
      if (code === "reauthorize_required" || code === "authorization_required") {
        root.authReady = false
        root.authState = "reauthorize"
        root.authMessage = message
      }
      var kind = code === "reauthorize_required" || code === "authorization_required"
        ? "auth" : (code === "no_speech" ? "input"
          : (code.indexOf("network") >= 0 ? "offline" : "asr"))
      root.fail(message + "；WAV 已保留", kind)
      return
    }
    root.appendDiagnostic("request_finished", {
      attempt: 1,
      duration_ms: elapsedMs,
      outcome: "success",
      audio_bytes: root.diagnosticAudioBytes,
      audio_duration_ms: Number(result.audio_duration_ms || 0),
      detected_speech_ms: Number(result.detected_speech_ms || 0),
      cloud_requests: root.diagnosticRequestCount,
      timings: result.timings || {}
    })
    root.finishTranscript(String(result.text || ""))
  }

  function finishTranscript(rawText) {
    var text = root.cleanTranscript(rawText)
    if (text === "") {
      root.fail("云端没有识别到可转写的语音；WAV 已保留", "input")
      return
    }
    root.appendDiagnostic("pipeline_finished", {
      outcome: "success",
      total_ms: Math.round(Date.now() - root.diagnosticPipelineStartMs),
      api_ms: Math.round(Date.now() - root.diagnosticApiStartMs),
      requests: root.diagnosticRequestCount,
      audio_bytes: root.diagnosticAudioBytes,
      transcript_chars: text.length
    })
    root.diagnosticTraceId = ""
    root.diagnosticStage = "idle"
    root.lastTranscript = text
    root.state = "idle"
    root.clearError()
    Quickshell.clipboardText = text
    root.appendHistory(text)

    var duration = root.elapsedSec
    var charCount = text.length
    if (root.autoPaste) {
      root.triggerAutoPaste(text)
      root.hudMessage = "已上屏 (" + charCount + "字)"
      root.notify("󰄬", "语音转写已上屏 · " + charCount + "字 (" + duration + "s)", text.length > 80 ? text.slice(0, 80) + "…" : text, "low")
    } else {
      root.hudMessage = "已复制 (" + charCount + "字)"
      root.notify("󰄬", "语音转写已复制 · " + charCount + "字 (" + duration + "s)", text.length > 80 ? text.slice(0, 80) + "…" : text, "low")
    }
    root.hudStatus = "success"
    root.hudVisible = true
    hudDismissTimer.interval = 1200
    hudDismissTimer.restart()
  }

  function triggerAutoPaste(text) {
    var script = "wl-copy " + shellQuote(text) + "; "
      + "active_cls=$(hyprctl activewindow -j 2>/dev/null | grep -o '\"class\": \"[^\"]*' | cut -d'\"' -f4 | tr '[:upper:]' '[:lower:]'); "
      + "case \"$active_cls\" in "
      + "  kitty|foot|alacritty|ghostty|xterm|wezterm) wtype -s 30 -M shift -k Insert -m shift ;; "
      + "  *) wtype -s 30 -M ctrl -k v -m ctrl ;; "
      + "esac"
    pasteProc.command = ["bash", "-c", script]
    pasteProc.running = true
  }

  function clearError() {
    root.lastError = ""
    root.errorKind = ""
  }

  function fail(message, kind) {
    if (root.diagnosticTraceId !== "") {
      root.appendDiagnostic("pipeline_finished", {
        outcome: "error",
        failed_stage: root.diagnosticStage,
        error_kind: kind || "asr",
        total_ms: Math.round(Date.now() - root.diagnosticPipelineStartMs),
        api_ms: root.diagnosticApiStartMs > 0
          ? Math.round(Date.now() - root.diagnosticApiStartMs) : 0,
        requests: root.diagnosticRequestCount,
        audio_bytes: root.diagnosticAudioBytes
      })
      root.diagnosticTraceId = ""
      root.diagnosticStage = "idle"
    }
    root.state = "idle"
    root.lastError = message
    root.errorKind = kind || "asr"
    root.hudStatus = "error"
    root.hudMessage = message
    root.hudVisible = true
    hudDismissTimer.interval = 2400
    hudDismissTimer.restart()
    root.notify("󰅚", "Omarvoice 错误", message, "normal")
  }

  // --------------------------------------------------------------- cleaner
  // Port of src/domain/transcript_cleaner.cpp. Lookbehinds become capture
  // groups, \p{...} becomes explicit CJK/ASCII classes.
  function cleanTranscript(raw) {
    var marker = "<asr_text>"
    var idx = String(raw).indexOf(marker)
    if (idx >= 0) return root.removeFillers(String(raw).slice(idx + marker.length).trim())
    var text = String(raw).trim()
    if (text.toLowerCase().indexOf("transcribe audio to text") === 0) return ""
    return root.removeFillers(text)
  }

  function removeFillers(text) {
    var cleaned = String(text).replace(/\s+/g, " ").trim()
    var protectedText = root.protectQuoted(cleaned)
    cleaned = protectedText.text

    var cjkAlnum = "A-Za-z0-9\\u4e00-\\u9fff"
    var filler = "[嗯呃额唔啊呐欸诶哎嗳]+|u+h+|u+m+|e+r+"

    var strong = new RegExp("([。！？!?；;：:])\\s*(" + filler + ")\\s*(?=[" + cjkAlnum + "])", "gi")
    cleaned = cleaned.replace(strong, "$1")

    var weak = new RegExp("(^|[\\s,，、])\\s*(" + filler + ")\\s*(?=[" + cjkAlnum + "])", "gi")
    cleaned = cleaned.replace(weak, "")

    var standalone = new RegExp("(^|[\\s,，、。！？!?；;：:])\\s*(" + filler + ")\\s*(?=$|[\\s,，、。！？!?；;：:])", "gi")
    cleaned = cleaned.replace(standalone, "$1")

    var sticky = new RegExp("([\\u4e00-\\u9fff])([嗯呃额唔]{1,3})(?=[\\u4e00-\\u9fffA-Za-z0-9])", "g")
    cleaned = cleaned.replace(sticky, "$1")

    cleaned = root.removeCjkSpaces(cleaned)
    cleaned = root.normalizePunctuation(cleaned)
    cleaned = root.removeCjkSpaces(cleaned)
    cleaned = root.restoreQuoted(cleaned, protectedText.placeholders)
    return cleaned.trim()
  }

  function removeCjkSpaces(text) {
    var cjk = "[\\u4e00-\\u9fff\\u3400-\\u4dbf\\uf900-\\ufaff]"
    var cjkPunct = "[\\u3000-\\u303f\\uff01-\\uff0f\\uff1a-\\uff20\\uff3b-\\uff40\\uff5b-\\uff65，。！？；：、“”‘’《》（）【】…—]"

    var res = String(text || "")

    // 1. Remove spaces between two CJK characters: "中 文" -> "中文"
    var reCjkCjk = new RegExp("(" + cjk + ")\\s+(" + cjk + ")", "g")
    var prev = ""
    while (prev !== res) {
      prev = res
      res = res.replace(reCjkCjk, "$1$2")
    }

    // 2. Remove spaces between CJK char and punctuation: "中 文 ，" -> "中文，"
    var reCjkPunct = new RegExp("(" + cjk + ")\\s+(" + cjkPunct + ")", "g")
    prev = ""
    while (prev !== res) {
      prev = res
      res = res.replace(reCjkPunct, "$1$2")
    }

    var rePunctCjk = new RegExp("(" + cjkPunct + ")\\s+(" + cjk + ")", "g")
    prev = ""
    while (prev !== res) {
      prev = res
      res = res.replace(rePunctCjk, "$1$2")
    }

    // 3. Remove spaces around opening and closing brackets/quotes
    res = res.replace(/([“「『《〈（(\[{])\s+/g, "$1")
    res = res.replace(/\s+([”」』》〉）)\]}])/g, "$1")

    // 4. Collapse multiple English spaces into single space
    res = res.replace(/[ \t]+/g, " ")

    return res.trim()
  }

  function protectQuoted(text) {
    var placeholders = []
    var re = /([“「『《〈][^”」』》〉]{0,80}[”」』》〉]|"[^"]{0,80}")/g
    var result = text.replace(re, function(match) {
      var ph = "__QASR_QUOTE_" + placeholders.length + "__"
      placeholders.push([ph, match])
      return ph
    })
    return { text: result, placeholders: placeholders }
  }

  function restoreQuoted(text, placeholders) {
    for (var i = 0; i < placeholders.length; i++) {
      text = text.split(placeholders[i][0]).join(placeholders[i][1])
    }
    return text
  }

  function normalizePunctuation(text) {
    var cleaned = String(text).replace(/\s+/g, " ").trim()
    cleaned = cleaned.replace(/\s+([，、。！？；：])/g, "$1")
    cleaned = cleaned.replace(/([，、。！？；：])\s+/g, "$1")
    cleaned = cleaned.replace(/[,，、]\s*[,，、]+/g, "，")
    cleaned = cleaned.replace(/[,，、]\s*([。！？!?；;：:])/g, "$1")
    cleaned = cleaned.replace(/([。！？!?；;：:])\s*[,，、]+/g, "$1")
    cleaned = cleaned.replace(/([。！？!?；;：:])\s*\1+/g, "$1")
    cleaned = cleaned.replace(/^[\s,，、。！？!?；;：:]+/, "")
    cleaned = cleaned.replace(/[\s,，、；;：:]+$/, "")
    return cleaned.trim()
  }

  // ---------------------------------------------------------------- history
  function appendHistory(text) {
    var stamp = root.fmtTime(new Date())
    var entry = "[" + stamp + "]\n" + text
    historyAppendProc.command = ["bash", "-c",
      "mkdir -p " + shellQuote(root.historyDir) + " && printf '%s\\n' "
      + shellQuote(entry) + " >> " + shellQuote(root.historyFile)]
    historyAppendProc.running = true
  }

  function loadHistory() {
    historyReadProc.command = ["bash", "-c", "tail -n 40 " + shellQuote(root.historyFile) + " 2>/dev/null"]
    historyReadProc.running = true
  }

  function onHistoryRead(raw) {
    var lines = String(raw).split("\n")
    var items = []
    var current = null
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var m = line.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*$/)
      if (m) {
        if (current && current.text !== "") items.push(current)
        current = { time: m[1], text: "" }
      } else if (current && line.trim() !== "") {
        current.text = current.text === "" ? line.trim() : current.text + " " + line.trim()
      }
    }
    if (current && current.text !== "") items.push(current)
    root.recent = items.slice(-10).reverse()
  }

  function fmtTime(d) {
    function p(n) { return n < 10 ? "0" + n : "" + n }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate())
      + " " + p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds())
  }

  function fmtTimeMs(d) {
    var ms = d.getMilliseconds()
    var suffix = ms < 10 ? "00" + ms : (ms < 100 ? "0" + ms : "" + ms)
    return root.fmtTime(d) + "." + suffix
  }

  function appendDiagnostic(eventName, fields) {
    var now = Date.now()
    var entry = {
      time: root.fmtTimeMs(new Date(now)),
      epoch_ms: now,
      event: eventName,
      trace_id: root.diagnosticTraceId
    }
    var values = fields || {}
    for (var key in values) entry[key] = values[key]
    root.diagnosticQueue = root.diagnosticQueue.concat(JSON.stringify(entry))
    root.flushDiagnosticQueue()
  }

  function flushDiagnosticQueue() {
    if (diagnosticAppendProc.running || root.diagnosticQueue.length === 0) return
    var line = root.diagnosticQueue[0]
    root.diagnosticQueue = root.diagnosticQueue.slice(1)
    diagnosticAppendProc.command = ["bash", "-c",
      "mkdir -p " + shellQuote(root.historyDir)
      + " && umask 077 && printf '%s\\n' " + shellQuote(line)
      + " >> " + shellQuote(root.diagnosticsFile)
      + " && chmod 600 " + shellQuote(root.diagnosticsFile)]
    diagnosticAppendProc.running = true
  }

  // ---------------------------------------------------------------- helpers
  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function removeFile(path) {
    rmProc.command = ["rm", "-f", path]
    rmProc.running = true
  }

  function clearHistory() {
    root.recent = []
    clearHistoryProc.command = ["bash", "-c", "rm -f " + shellQuote(root.historyFile)]
    clearHistoryProc.running = true
  }

  // Omarchy-native notification: glyph hint + user-action tagging go through
  // omarchy-notification-send. The default app name (omarchy-action) is what
  // makes the toast bypass Do Not Disturb — a transcript is feedback for a
  // deliberate user action, so it must show even when notifications are
  // silenced. Overriding --app-name would drop that bypass.
  function notify(glyph, title, body, urgency) {
    var g = glyph || "󰍬"
    notifyProc.command = ["omarchy-notification-send", "-g", g,
      "-u", urgency || "low", String(title), String(body)]
    notifyProc.running = true
  }

  // ------------------------------------------------------------------ procs
  // Each long-lived Process is reused; running:true (re)starts it. StdioCollector
  // buffers stdout; the "done" path reads `.text` after `exited`.
  Process {
    id: settingsReadProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code === 0) {
        var lines = settingsReadProc.stdout.text.split("\n")
        var ap = lines[0] ? lines[0].trim() : ""
        var sh = lines[1] ? lines[1].trim() : ""
        if (ap !== "") root.autoPaste = ap === "true"
        if (sh !== "") root.showHud = sh === "true"
      }
    }
  }

  Process {
    id: shortcutReadProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code === 0 && shortcutReadProc.stdout) {
        var key = shortcutReadProc.stdout.text.trim()
        if (key !== "") root.currentShortcut = key
      }
    }
  }

  Process {
    id: shortcutWriteProc
    property var callback: null
    property string targetKey: ""
    onExited: function(code) {
      if (code === 0) {
        if (shortcutWriteProc.targetKey !== "") {
          root.currentShortcut = shortcutWriteProc.targetKey
        }
        var icon = root.shortcutIcon(root.currentShortcut)
        var name = root.friendlyShortcutName(root.currentShortcut)
        root.notify(icon, "Omarvoice 快捷键已生效", "按住 [" + name + "] 即可直接语音输入", "low")
        if (shortcutWriteProc.callback) shortcutWriteProc.callback(true)
      } else {
        root.fail("修改快捷键失败", "recording")
        if (shortcutWriteProc.callback) shortcutWriteProc.callback(false)
      }
      shortcutWriteProc.callback = null
    }
  }

  Process {
    id: keyWriteProc
    property var callback: null
    onExited: function(code) {
      if (code === 0) {
        if (keyWriteProc.callback) keyWriteProc.callback()
        keyWriteProc.callback = null
      } else {
        root.fail("无法写入应用配置", "recording")
      }
    }
  }

  Process {
    id: pasteProc
  }



  Process {
    id: warmupProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var result = root.parseBridgeResult(warmupProc.stdout.text)
      root.serviceReady = code === 0 && result && result.ready === true
      root.appendDiagnostic("service_warmup", {
        outcome: root.serviceReady ? "success" : "error",
        timings: result ? (result.timings || {}) : {}
      })
    }
  }

  Process {
    id: daemonStatusProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var result = root.parseBridgeResult(daemonStatusProc.stdout.text)
      if (code === 0 && result && result.recording === true) {
        root.cancelOrphanedRecording("startup")
      }
    }
  }

  Process {
    id: recordingRecoveryProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var reason = root.recordingRecoveryReason
      root.recordingRecoveryReason = ""
      var result = root.parseBridgeResult(recordingRecoveryProc.stdout.text)
      if (code !== 0 || !result || result.status !== "cancelled") return
      root.appendDiagnostic("orphan_recording_recovered", {
        trigger: reason,
        audio_bytes: Number(result.audio_bytes || 0)
      })
      root.notify(
        "󰄬",
        "Omarvoice 已恢复",
        "上次中断的录音已停止；WAV 已保留",
        "low"
      )
    }
  }

  Process {
    id: recordStartProc
    property string contextPath: ""
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var output = recordStartProc.stdout.text
      var path = recordStartProc.contextPath
      recordStartProc.contextPath = ""
      root.onLiveStartFinished(output, path, code === 0)
    }
  }

  Process {
    id: recordStopProc
    property string contextPath: ""
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var output = recordStopProc.stdout.text
      var path = recordStopProc.contextPath
      recordStopProc.contextPath = ""
      root.onLiveStopFinished(output, path, code === 0)
    }
  }

  Process {
    id: authStatusProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var result = null
      try {
        result = JSON.parse(authStatusProc.stdout.text.trim())
      } catch (e) {
        result = null
      }
      root.authReady = code === 0 && result && result.ready === true
      root.authAccount = result ? String(result.email || "") : ""
      root.authMessage = result
        ? String(result.message || "Agent Panel 鉴权尚未就绪")
        : "无法读取 Agent Panel 鉴权状态"
      if (root.authReady) {
        root.authState = "ready"
        authPollTimer.stop()
        root.warmService()
      } else if (result && (result.code === "reauthorize_required"
                           || result.status === "reauthorize_required")) {
        root.authState = root.authState === "authorizing" ? "authorizing" : "reauthorize"
      } else {
        root.authState = root.authState === "authorizing" ? "authorizing" : "error"
      }
    }
  }

  Process {
    id: authorizeProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        root.authState = "error"
        root.authMessage = "无法启动 Agent Panel 授权"
        return
      }
      root.authState = "authorizing"
      root.authMessage = "授权链接已复制；完成登录后会自动刷新"
      root.authPollCount = 0
      authPollTimer.restart()
    }
  }

  Timer {
    id: authPollTimer
    interval: 5000
    repeat: true
    onTriggered: {
      root.authPollCount++
      if (root.authPollCount > 60) {
        authPollTimer.stop()
        root.authState = "reauthorize"
        root.authMessage = "授权等待超时，请重试"
        return
      }
      root.loadAuthStatus()
    }
  }

  Process {
    id: historyAppendProc
    onExited: function() { root.loadHistory() }
  }

  Process {
    id: diagnosticAppendProc
    onExited: function() { root.flushDiagnosticQueue() }
  }

  Process {
    id: historyReadProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code === 0) root.onHistoryRead(historyReadProc.stdout.text)
    }
  }

  Process {
    id: clearHistoryProc
    onExited: function() { root.loadHistory() }
  }

  Process {
    id: rmProc
  }

  Process {
    id: notifyProc
  }

  // ---------------------------------------------------------------- IPC
  // Reachable as: omarchy-shell qwen-asr start | stop | toggle | status
  IpcHandler {
    target: "qwen-asr"

    function start(): void { root.startRecording() }
    function stop(): void { root.stopRecording() }
    function toggle(): void {
      if (root.state === "arming" || root.state === "recording") root.stopRecording()
      else root.startRecording()
    }
    function status(): string {
      if (root.state !== "idle") return root.state
      if (root.errorKind === "offline") return "offline:" + root.lastError
      if (root.lastError !== "") return "error:" + root.lastError
      return "idle"
    }
    function level(): string {
      return root.state + "|" + root.level.toFixed(3) + "|" + root.barLevels.length
    }
    function shortcut(): string {
      return root.currentShortcut
    }
    function setShortcut(key: string): string {
      return root.setShortcut(key, null)
    }
  }

  Component.onCompleted: {
    root.appendDiagnostic("plugin_loaded", { model: root.model })
    root.reconcileServiceRecording()
    root.loadSettings()
    root.loadAuthStatus()
    root.loadShortcut()
    root.loadHistory()
  }

  Component.onDestruction: {
    if (root.state === "arming" || root.state === "recording") {
      Quickshell.execDetached([root.bridgeBinary, "record-cancel"])
    }
  }
}
