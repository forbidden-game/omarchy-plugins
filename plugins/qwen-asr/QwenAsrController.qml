import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Core of the Qwen ASR bar plugin: recording, live input level metering,
// cloud transcription, text cleaning, history, settings, clipboard, and the
// push-to-talk IPC surface.
//
// All state transitions run through `state`:
//   idle -> arming -> recording -> transcribing -> idle
// `arming` means MediaRecorder has been asked to record but its backend has
// not yet confirmed RecordingState. Errors return to idle and are classified
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
  readonly property string recordingsDir: historyDir + "/recordings"
  readonly property string model: "qwen-audio-3.0-asr-flash"
  readonly property int maxInlineAudioBytes: 7 * 1024 * 1024
  readonly property int sampleRate: 16000
  readonly property int channels: 1
  readonly property int minRecordingMs: 1000
  readonly property int maxNoWordsRetries: 3
  readonly property string baseUrl: {
    var env = Quickshell.env("DASHSCOPE_BASE_URL") || ""
    var origin = env !== "" ? env : "https://dashscope.aliyuncs.com"
    return origin + "/api/v1/services/aigc/multimodal-generation/generation"
  }

  // ---------------------------------------------------------------- state
  property string state: "idle" // idle | arming | recording | transcribing
  property string lastError: ""
  property string errorKind: "" // "" | offline | input | recording | asr
  property string lastTranscript: ""
  property bool apiKeyConfigured: false
  property int elapsedSec: 0
  property int retryAttempt: 0
  property var recent: [] // [{time, text}] most recent first, max 10

  // ----------------------------------------------------------- HUD & Features
  property bool autoPaste: true
  property bool showHud: true
  property bool hudVisible: false
  property string hudStatus: "idle" // idle | arming | recording | transcribing | success | error
  property string hudMessage: ""
  readonly property string activeMicName: mediaDevices.defaultAudioInput ? (mediaDevices.defaultAudioInput.description || "默认麦克风") : "未检测到麦克风"

  Timer {
    id: hudDismissTimer
    interval: 1200
    repeat: false
    onTriggered: {
      root.hudVisible = false
      root.hudStatus = "idle"
    }
  }

  Timer {
    id: armingTimer
    interval: 240
    repeat: false
    onTriggered: {
      if (root.state === "recording" && root.hudStatus === "arming") {
        root.hudStatus = "recording"
      }
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

  // -------------------------------------------------------------- settings
  property string apiKey: "" // env DASHSCOPE_API_KEY, else QSettings INI

  function loadApiKey() {
    var envKey = (Quickshell.env("DASHSCOPE_API_KEY") || "").trim()
    if (envKey !== "") {
      root.apiKey = envKey
      root.apiKeyConfigured = true
    }
    settingsReadProc.command = ["bash", "-c",
      "f=" + shellQuote(root.settingsFile) + "; "
      + "if [ -f \"$f\" ]; then "
      + "  k=$(grep -E '^[[:space:]]*apiKey[[:space:]]*=' \"$f\" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]'); "
      + "  ap=$(grep -E '^[[:space:]]*autoPaste[[:space:]]*=' \"$f\" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]'); "
      + "  sh=$(grep -E '^[[:space:]]*showHud[[:space:]]*=' \"$f\" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]'); "
      + "  printf '%s\\n%s\\n%s\\n' \"$k\" \"$ap\" \"$sh\"; "
      + "fi"]
    settingsReadProc.running = true
  }

  function setApiKey(newKey) {
    var key = String(newKey || "").trim()
    if (key === "") {
      root.lastError = "API Key 不能为空"
      root.errorKind = "input"
      return "API Key 不能为空"
    }
    writeConfigKey("apiKey", key, function() {
      root.loadApiKey()
      root.notify("󰄬", "Qwen ASR", "API Key 已保存", "low")
    })
    return "ok"
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
  property double armStartMs: 0
  property int coldStartMs: 0
  property bool isColdStart: false
  property bool discardNextStop: false
  property bool stopWhenReady: false

  property url recUrl: root.recPath === "" ? "" : "file://" + root.recPath

  // Runs only while recording so it freezes at the final audio duration when transcribing.
  Timer {
    id: recTimer
    interval: 1000
    repeat: true
    running: root.state === "recording"
    onTriggered: root.elapsedSec++
  }

  MediaDevices {
    id: mediaDevices
    onDefaultAudioInputChanged: {
      if (audioIn && mediaDevices.defaultAudioInput) {
        audioIn.device = mediaDevices.defaultAudioInput
      }
    }
  }

  CaptureSession {
    id: session
    audioInput: AudioInput {
      id: audioIn
      device: mediaDevices.defaultAudioInput
    }
    recorder: MediaRecorder {
      id: recorder
      outputLocation: root.recUrl
      // The FFmpeg backend chooses AAC/MP4 for this build. The file is
      // converted to a permanent 16k mono PCM WAV after recording stops.
      onRecorderStateChanged: {
        if (recorder.recorderState === MediaRecorder.RecordingState && root.state === "arming") {
          root.coldStartMs = Math.round(Date.now() - root.armStartMs)
          root.isColdStart = false
          root.recordStartMs = Date.now()
          root.elapsedSec = 0
          root.resetLevel()
          if (root.stopWhenReady) {
            root.stopWhenReady = false
            root.discardNextStop = true
            root.hudVisible = false
            root.hudStatus = "idle"
            recorder.stop()
            return
          }
          root.state = "recording"
          var elapsed = Date.now() - root.armStartMs
          if (elapsed < 240) {
            armingTimer.interval = Math.max(60, 240 - elapsed)
            armingTimer.restart()
          } else {
            root.hudStatus = "recording"
          }
          return
        }

        if (recorder.recorderState === MediaRecorder.StoppedState && root.recPath !== "") {
          var path = root.recPath
          root.recPath = ""
          if (root.discardNextStop) {
            root.discardNextStop = false
            root.stopWhenReady = false
            root.state = "idle"
            root.hudVisible = false
            root.hudStatus = "idle"
            removeFile(path)
            return
          }
          root.transcribe(path)
        }
      }
      onErrorOccurred: function(error, errorString) {
        root.recPath = ""
        root.discardNextStop = false
        root.stopWhenReady = false
        root.fail("录音失败：" + errorString, "recording")
      }
    }
  }

  function startRecording() {
    if (root.state !== "idle") return
    root.clearError()

    var dev = mediaDevices.defaultAudioInput
    if (!dev || !dev.id || dev.id === "") {
      root.fail("未检测到可用的录音设备，请检查麦克风", "recording")
      return
    }
    audioIn.device = dev

    var now = Date.now()
    root.recPath = "/tmp/qwen-asr-" + now + ".m4a"
    root.armStartMs = now
    root.coldStartMs = 0
    root.isColdStart = true
    root.recordStartMs = 0
    root.discardNextStop = false
    root.stopWhenReady = false
    root.elapsedSec = 0
    root.resetLevel()
    root.state = "arming"
    root.hudStatus = "arming"
    root.hudVisible = true
    hudDismissTimer.stop()
    recorder.record()
  }

  function stopRecording() {
    if (root.state === "arming") {
      // Do not treat key-down time as recorded audio. Once the backend really
      // reaches RecordingState, stop immediately and discard this tap.
      root.stopWhenReady = true
      return
    }
    if (root.state !== "recording") return
    if (Date.now() - root.recordStartMs < root.minRecordingMs) {
      root.discardNextStop = true
      root.hudVisible = false
      root.hudStatus = "idle"
    }
    recorder.stop() // async: transcribe runs from StoppedState
  }

  // ---------------------------------------------------------------- ASR
  function transcribe(path) {
    root.state = "transcribing"
    root.hudStatus = "transcribing"
    root.hudVisible = true
    hudDismissTimer.stop()
    root.retryAttempt = 0
    var name = path.slice(path.lastIndexOf("/") + 1, -4) + ".wav"
    var out = root.recordingsDir + "/" + name
    convertProc.command = ["bash", "-c",
      "mkdir -p " + shellQuote(root.recordingsDir)
      + " && exec ffmpeg -y -loglevel error -i " + shellQuote(path)
      + " -ar " + root.sampleRate + " -ac " + root.channels
      + " -c:a pcm_s16le " + shellQuote(out)]
    convertProc.srcPath = path
    convertProc.outPath = out
    convertProc.running = true
  }

  function onConverted(srcPath, outPath, ok, errorText) {
    if (!ok) {
      removeFile(srcPath)
      removeFile(outPath)
      var detail = errorText && errorText !== "" ? "（" + errorText.split("\n")[0] + "）" : ""
      root.fail("录音格式转换失败" + detail, "recording")
      return
    }
    removeFile(srcPath)
    speechProbeProc.command = ["ffmpeg", "-hide_banner", "-nostats", "-i", outPath,
      "-af", "silencedetect=noise=-25dB:d=0.2", "-f", "null", "-"]
    speechProbeProc.contextPath = outPath
    speechProbeProc.running = true
  }

  function onSpeechProbeReady(log, path, ok) {
    if (!ok) {
      root.fail("无法检测录音中的有效语音；WAV 已保留", "recording")
      return
    }
    var durationMatch = String(log).match(/Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/)
    if (!durationMatch) {
      root.fail("无法读取录音时长；WAV 已保留", "recording")
      return
    }
    var duration = Number(durationMatch[1]) * 3600
      + Number(durationMatch[2]) * 60 + Number(durationMatch[3])
    var silence = 0
    var silenceRe = /silence_duration:\s*([0-9.]+)/g
    var match = null
    while ((match = silenceRe.exec(String(log))) !== null) silence += Number(match[1])
    if (duration < 1 || duration - silence < 0.6) {
      root.fail("未检测到有效语音；WAV 已保留", "input")
      return
    }
    base64Proc.command = ["base64", "-w0", path]
    base64Proc.contextPath = path
    base64Proc.running = true
  }

  function onBase64Ready(b64, path) {
    if (b64 === null) {
      root.fail("读取录音文件失败；WAV 已保留", "recording")
      return
    }
    // base64 length * 3/4 = decoded bytes.
    if (b64.length * 0.75 > root.maxInlineAudioBytes) {
      root.fail("录音过长；当前 Base64 接口请控制在约 3 分 45 秒以内", "input")
      return
    }
    root.submit(b64, 0)
  }

  function submit(b64, attempt) {
    root.retryAttempt = attempt
    var dataUri = "data:audio/wav;base64," + b64
    var payload = {
      model: root.model,
      input: {
        messages: [ {
          role: "user",
          content: [ { type: "input_audio", input_audio: { data: dataUri } } ]
        } ]
      },
      parameters: {
        format: "wav",
        sample_rate: String(root.sampleRate),
        language_hints: []
      }
    }

    var xhr = new XMLHttpRequest()
    var settled = false
    xhr.open("POST", root.baseUrl, true)
    xhr.setRequestHeader("Content-Type", "application/json")
    xhr.setRequestHeader("Authorization", "Bearer " + root.apiKey)
    xhr.setRequestHeader("X-DashScope-SSE", "disable")
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE || settled) return
      settled = true
      if (xhr.status === 0) {
        root.fail("网络不可用，请检查连接后重试", "offline")
        return
      }
      if (xhr.status !== 200) {
        if (root.isNoWordsError(xhr.responseText) && attempt < root.maxNoWordsRetries) {
          root.submit(b64, attempt + 1)
          return
        }
        root.fail(root.apiErrorText(xhr.responseText, "ASR 请求失败（HTTP " + xhr.status + "）"), "asr")
        return
      }
      var text = root.parseRecognition(xhr.responseText)
      if (text === null) {
        root.fail(root.apiErrorText(xhr.responseText, "ASR 返回为空"), "asr")
        return
      }
      root.finishTranscript(text)
    }
    xhr.ontimeout = function() {
      if (settled) return
      settled = true
      root.fail("ASR 请求超时", "asr")
    }
    xhr.onerror = function() {
      if (settled) return
      settled = true
      root.fail("网络不可用，请检查连接后重试", "offline")
    }
    xhr.timeout = 120000
    xhr.send(JSON.stringify(payload))
  }

  function finishTranscript(rawText) {
    var text = root.cleanTranscript(rawText)
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
    root.retryAttempt = 0
  }

  function fail(message, kind) {
    root.state = "idle"
    root.retryAttempt = 0
    root.lastError = message
    root.errorKind = kind || "asr"
    root.hudStatus = "error"
    root.hudMessage = message
    root.hudVisible = true
    hudDismissTimer.interval = 2400
    hudDismissTimer.restart()
    root.notify("󰅚", "Qwen ASR 错误", message, "normal")
  }

  // ------------------------------------------------------ response parsing
  function parseRecognition(body) {
    var rootObj = null
    try {
      rootObj = JSON.parse(body)
    } catch (e) {
      return null
    }
    if (!rootObj || typeof rootObj !== "object") return null
    var output = rootObj.output || {}
    var text = String(output.text || "").trim()
    if (text === "") text = String((((output.output || {}).sentence) || {}).text || "").trim()
    if (text === "") text = String(((output.sentence) || {}).text || "").trim()
    return text === "" ? null : text
  }

  function apiErrorText(body, fallback) {
    var rootObj = null
    try {
      rootObj = JSON.parse(body)
    } catch (e) {
      return fallback
    }
    if (!rootObj || typeof rootObj !== "object") return fallback
    function errFrom(obj) {
      if (!obj || typeof obj !== "object") return ""
      var msg = obj.message || obj.error || ""
      var code = obj.code || ""
      if (String(msg).trim() === "") return ""
      return code !== "" ? code + "：" + msg : String(msg)
    }
    var nested = errFrom(rootObj.error) || errFrom(rootObj.output) || errFrom(rootObj)
    return nested !== "" ? nested : fallback
  }

  function isNoWordsError(body) {
    return String(body || "").indexOf("ASR_RESPONSE_HAVE_NO_WORDS") >= 0
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

    cleaned = root.normalizePunctuation(cleaned)
    cleaned = root.restoreQuoted(cleaned, protectedText.placeholders)
    return cleaned.trim()
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
        var k = lines[0] ? lines[0].trim() : ""
        var ap = lines[1] ? lines[1].trim() : ""
        var sh = lines[2] ? lines[2].trim() : ""
        if (root.apiKey === "" && k !== "") {
          root.apiKey = k
          root.apiKeyConfigured = true
        }
        if (ap !== "") root.autoPaste = ap === "true"
        if (sh !== "") root.showHud = sh === "true"
      }
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
    id: convertProc
    property string srcPath: ""
    property string outPath: ""
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var src = convertProc.srcPath
      var out = convertProc.outPath
      var err = convertProc.stderr ? convertProc.stderr.text.trim() : ""
      convertProc.srcPath = ""
      convertProc.outPath = ""
      root.onConverted(src, out, code === 0, err)
    }
  }

  Process {
    id: speechProbeProc
    property string contextPath: ""
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var path = speechProbeProc.contextPath
      var log = speechProbeProc.stderr.text
      speechProbeProc.contextPath = ""
      root.onSpeechProbeReady(log, path, code === 0)
    }
  }

  Process {
    id: base64Proc
    property string contextPath: ""
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var b64 = code === 0 ? base64Proc.stdout.text.trim() : null
      var path = base64Proc.contextPath
      base64Proc.contextPath = ""
      root.onBase64Ready(b64, path)
    }
  }

  Process {
    id: historyAppendProc
    onExited: function() { root.loadHistory() }
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
  }

  Component.onCompleted: {
    root.loadApiKey()
    root.loadHistory()
  }
}
