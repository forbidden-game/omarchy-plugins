import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Live network throughput on the bar.
//
// Sampling is split in two so the hot path stays cheap:
//   - ifaceProbe (30s) runs `ip -j route get` to learn the active interface.
//   - sampleTimer (1s) cats that interface's rx_bytes/tx_bytes and computes
//     deltas against the previous sample, so no process is spawned per second
//     beyond one trivial `cat`.
// The first sample after a probe only records a baseline; a rate needs two
// samples of the same interface to be real.
BarWidget {
  id: root
  moduleName: "eipi10.netrate"

  property string iface: ""
  property real prevRxBytes: 0
  property real prevTxBytes: 0
  property real prevSampleTime: 0
  property real downloadRate: 0 // bytes/sec
  property real uploadRate: 0 // bytes/sec

  readonly property bool hasIface: iface !== ""

  readonly property string rateLabel: hasIface
    ? "\uf063 " + compactRate(downloadRate) + " \uf062 " + compactRate(uploadRate)
    : ""

  readonly property string detailLabel: hasIface
    ? iface + " \u00b7 \uf063 " + compactBytes(prevRxBytes) + " \uf062 " + compactBytes(prevTxBytes)
    : "No network"

  visible: hasIface
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The label is always exactly 15 chars ("\uf063 xxxxx \uf062 xxxxx") and the
  // bar font is monospace, so this hidden probe measures the constant slot
  // width. Recomputes automatically if the font or size changes.
  Text {
    id: widthProbe
    visible: false
    text: "\uf063 " + "0.00K" + " \uf062 " + "0.00K"
    font.family: button.fontFamily
    font.pixelSize: Style.font.caption
    renderType: Text.NativeRendering
  }

  // Always returns exactly 5 characters so the rendered label width is
  // constant in the bar's monospace font: "x.xxU" / "xx.xU" / "xxx U".
  // Minimum unit is K (bytes are never shown).
  function compactRate(bytesPerSec) {
    var n = Number(bytesPerSec) / 1024
    if (!isFinite(n) || n < 0) n = 0
    var units = ["K", "M", "G", "T"]
    var u = 0
    while (n >= 1024 && u < units.length - 1) { n /= 1024; u++ }
    for (;;) {
      var s
      if (n < 10) s = n.toFixed(2)                       // 0.00 - 9.99
      else if (n < 100) s = n.toFixed(1)                 // 10.0 - 99.9
      else s = String(Math.round(n)).padStart(4, " ")   // 100 - 1000
      if (s.length <= 4) return s + units[u]
      // Rounding overflow (9.996 -> "10.00"): carry into the next unit.
      n /= 1024; u++
    }
  }

  function compactBytes(bytes) {
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) n = 0
    if (n < 1024) return Math.round(n) + "B"
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + "K"
    if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + "M"
    return (n / (1024 * 1024 * 1024)).toFixed(2) + "G"
  }

  function resetBaseline() {
    prevRxBytes = 0
    prevTxBytes = 0
    prevSampleTime = 0
    downloadRate = 0
    uploadRate = 0
  }

  function recordSample(raw) {
    var lines = String(raw || "").trim().split("\n")
    if (lines.length < 2) return
    var rx = parseFloat(lines[0]) || 0
    var tx = parseFloat(lines[1]) || 0
    var now = Date.now() / 1000
    if (prevSampleTime > 0) {
      var dt = now - prevSampleTime
      if (dt > 0) {
        downloadRate = Math.max(0, (rx - prevRxBytes) / dt)
        uploadRate = Math.max(0, (tx - prevTxBytes) / dt)
      }
    }
    prevRxBytes = rx
    prevTxBytes = tx
    prevSampleTime = now
  }

  // Active interface, rediscovered on a slow poll so a wired/wireless switch
  // is picked up without holding the hot path hostage to the probe.
  Timer {
    id: ifaceProbe
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!probeProc.running) probeProc.running = true
    }
  }

  Process {
    id: probeProc
    command: ["bash", "-c", "ip -j route get 1.1.1.1 2>/dev/null | jq -r '.[0].dev // \"\"'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dev = String(text || "").trim()
        if (dev === root.iface) return
        root.resetBaseline()
        root.iface = dev
      }
    }
  }

  // Throughput sample. One `cat` per second; rates come from deltas so the
  // interval can drift without skewing the numbers.
  Timer {
    id: sampleTimer
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!root.iface || readProc.running) return
      readProc.command = [
        "cat",
        "/sys/class/net/" + root.iface + "/statistics/rx_bytes",
        "/sys/class/net/" + root.iface + "/statistics/tx_bytes"
      ]
      readProc.running = true
    }
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.recordSample(text)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.rateLabel
    fontSize: Style.font.caption
    horizontalMargin: 6
    fixedWidth: widthProbe.width + scaledHorizontalMargin * 2
    tooltipText: root.detailLabel
    pressable: false
  }
}
