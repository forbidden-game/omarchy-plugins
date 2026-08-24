import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Live CPU + RAM monitor for the bar.
//
// Sampling is a single `cat /proc/stat /proc/meminfo /proc/loadavg` per
// second — no second process spawns on the hot path. CPU usage comes from
// jiffie deltas between snapshots (the first sample only records a
// baseline), RAM is absolute and reparsed every tick. The popup layers the
// detail: a justified per-core grid with an avg/max/load footer, a
// used/cache/swap breakdown, and the six hungriest processes. The process
// list is sampled only while the popup is open, so the idle cost of the
// widget stays one trivial cat per second.
//
// Colors follow the shell's state vocabulary: the label and the popup switch
// from `foreground` to `urgent` once CPU or memory crosses its alert
// threshold (defaults: 85% cpu, 90% mem). The label is pure text — nerd
// icons lose all shape at caption size in the bar font, so the numbers carry
// the meaning. Vertical bars show the CPU percent only; details live in the
// tooltip.
Panel {
  id: root
  moduleName: "eipi10.cpu-ram"
  // No IPC surface: one bar instance exists per monitor anyway and there is
  // nothing to summon remotely, so skip the IpcHandler entirely.
  manageIpc: false

  // ------------------------------------------------------------- settings
  readonly property bool showCpu: setting("showCpu", true) === true
  readonly property bool showRam: setting("showRam", true) === true
  readonly property bool showTemp: setting("showTemp", true) === true
  readonly property int cpuAlert: clampAlert(setting("cpuAlert", 85))
  readonly property int memAlert: clampAlert(setting("memAlert", 90))
  readonly property int tempAlert: clampTempAlert(setting("tempAlert", 85))

  function clampAlert(v) {
    var n = Number(v)
    if (!isFinite(n) || n <= 0) return 85
    return Math.max(5, Math.min(100, Math.round(n)))
  }

  function clampTempAlert(v) {
    var n = Number(v)
    if (!isFinite(n) || n <= 0) return 85
    return Math.max(30, Math.min(110, Math.round(n)))
  }

  // ------------------------------------------------------------- live data
  property var prevStat: null
  property real cpuPercent: 0
  property var coreSamples: [] // [{ p: pct }, ...] — replaced wholesale each tick
  property var loadavg: [0, 0, 0] // [1min, 5min, 15min] from /proc/loadavg
  property var mem: ({ total: 0, used: 0, cache: 0, swapTotal: 0, swapUsed: 0 })
  property var topProcs: []
  property string tempPath: "" // thermal zone temp file, discovered by probe
  property real tempMilli: 0 // millidegrees; 0 = no sensor

  readonly property int coreCount: coreSamples.length

  // Footer stats for the per-core grid: mean and peak across cores.
  readonly property real coreAvg: {
    var sum = 0
    for (var i = 0; i < coreCount; i++) sum += coreSamples[i].p
    return coreCount > 0 ? sum / coreCount : 0
  }
  readonly property real coreMax: {
    var m = 0
    for (var i = 0; i < coreCount; i++) if (coreSamples[i].p > m) m = coreSamples[i].p
    return m
  }

  readonly property real ramPercent: Model.percentOf(mem.used, mem.total)
  readonly property bool swapActive: mem.swapUsed > 0
  readonly property real tempC: Model.celsius(tempMilli)
  readonly property bool tempKnown: tempC > 0
  readonly property bool hot: cpuPercent >= cpuAlert || ramPercent >= memAlert || (tempKnown && tempC >= tempAlert)

  // ------------------------------------------------------------- palette
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- sampling
  function consumeSample(raw) {
    var split = Model.splitProcOutput(raw)
    var stat = Model.parseStat(split.stat)
    if (stat.total) {
      var prev = root.prevStat
      root.cpuPercent = Model.cpuPercent(prev && prev.total, stat.total)
      var perCore = []
      for (var i = 0; i < stat.cores.length; i++) {
        perCore.push({ p: Model.cpuPercent(prev && prev.cores[i], stat.cores[i]) })
      }
      root.coreSamples = perCore
      root.prevStat = stat
    }
    var m = Model.parseMeminfo(split.meminfo)
    if (m.total > 0) root.mem = m
    root.tempMilli = Model.parseTemp(raw)
    root.loadavg = Model.parseLoadavg(raw)
  }

  // CPU temp source discovery. Thermal zone numbers are dynamic across
  // boots, so locate x86_pkg_temp (fallback: coretemp package) on a slow
  // probe and only cat the single file on the hot path.
  Timer {
    id: tempProbeTimer
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!tempProbeProc.running) tempProbeProc.running = true
    }
  }

  Process {
    id: tempProbeProc
    command: [
      "bash", "-c",
      "for z in /sys/class/thermal/thermal_zone*; do " +
      "[ \"$(cat \"$z/type\" 2>/dev/null)\" = \"x86_pkg_temp\" ] && { echo \"$z/temp\"; exit 0; }; " +
      "done; " +
      "for h in /sys/class/hwmon/hwmon*; do " +
      "[ \"$(cat \"$h/name\" 2>/dev/null)\" = \"coretemp\" ] && { echo \"$h/temp1_input\"; exit 0; }; " +
      "done"
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = String(text || "").trim()
        root.tempPath = p
        if (p === "") root.tempMilli = 0
      }
    }
  }

  Timer {
    id: sampleTimer
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (readProc.running) return
      var cmd = ["cat", "/proc/stat", "/proc/meminfo", "/proc/loadavg"]
      if (root.tempPath !== "") cmd.push(root.tempPath)
      readProc.command = cmd
      readProc.running = true
    }
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.consumeSample(text)
    }
  }

  // Top processes: sampled only while the popup is open.
  Timer {
    id: topTimer
    interval: 2000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!topProc.running) topProc.running = true
    }
  }

  Process {
    id: topProc
    command: ["bash", "-c", "ps -eo comm=,%cpu=,%mem= --sort=-%cpu | head -6"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.topProcs = Model.parseTop(text)
    }
  }

  // ------------------------------------------------------------- labels
  readonly property string cpuLabel: "CPU " + Math.round(cpuPercent) + "%"
  readonly property string tempLabel: tempC + "\u00b0C"
  readonly property string ramLabel: "RAM " + Math.round(ramPercent) + "% " + Model.compactBytes(mem.used) + "/" + Model.compactBytes(mem.total)

  // Vertical bars are too narrow for the full line; CPU percent only.
  readonly property string labelText: {
    if (root.vertical) return Math.round(cpuPercent) + "%"
    var parts = []
    if (showCpu) parts.push(cpuLabel)
    if (showTemp && tempKnown) parts.push(tempLabel)
    if (showRam) parts.push(ramLabel)
    return parts.join(" \u00b7 ")
  }

  readonly property string tooltipText: {
    var parts = []
    if (showCpu) parts.push("CPU " + Math.round(cpuPercent) + "% \u00b7 " + coreCount + " cores")
    if (showTemp && tempKnown) parts.push(tempC + "\u00b0C")
    if (showRam) parts.push("RAM " + Model.compactBytes(mem.used) + "/" + Model.compactBytes(mem.total) + " (" + Math.round(ramPercent) + "%)")
    if (swapActive) parts.push("swap " + Model.compactBytes(mem.swapUsed) + "/" + Model.compactBytes(mem.swapTotal))
    return parts.join(" \u00b7 ")
  }

  visible: showCpu || showRam
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    fontSize: Style.font.caption
    horizontalMargin: 6
    active: root.hot
    tooltipText: root.tooltipText
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- hero: CPU | RAM ----------
        Row {
          width: parent.width
          spacing: Style.space(16)

          HeroCell {
            title: "CPU"
            subtitle: root.coreCount + " cores"
            // Temp rides as its own trailing run so it can speak up (urgent)
            // without dragging the core count along.
            detail: root.tempKnown ? " \u00b7 " + root.tempC + "\u00b0C" : ""
            detailAlert: root.tempKnown && root.tempC >= root.tempAlert
            percent: Math.round(root.cpuPercent)
            tint: (root.cpuPercent >= root.cpuAlert || (root.tempKnown && root.tempC >= root.tempAlert))
              ? root.urgent : root.foreground
          }

          HeroCell {
            title: "RAM"
            subtitle: Model.compactBytes(root.mem.used) + " / " + Model.compactBytes(root.mem.total)
            percent: Math.round(root.ramPercent)
            tint: root.ramPercent >= root.memAlert ? root.urgent : root.foreground
          }
        }

        // ---------- per-core CPU ----------
        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "CPU CORES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(5)

          Column {
            width: parent.width
            spacing: Style.space(3)

            // Justified per-core grid: bars run edge-to-edge like every
            // other section. One row up to 16 cores; wider CPUs wrap every
            // 16. Fewer cores still spread full-width because columns
            // follows the count.
            Grid {
              id: coreGrid
              width: parent.width
              readonly property int cols: Math.max(1, Math.min(16, root.coreCount))
              columns: cols
              columnSpacing: Style.space(4)
              rowSpacing: Style.space(6)
              readonly property int barWidth: Math.floor((width - columnSpacing * (cols - 1)) / cols)

              Repeater {
                model: root.coreSamples
                delegate: CoreBar {
                  pct: modelData.p
                  width: coreGrid.barWidth
                }
              }
            }

            // Hairline the fills rise from — grounds the row edge-to-edge.
            PanelSeparator {
              foreground: root.foreground
              strength: 0.18
            }
          }

          // avg / max / load footer: labels dim, numbers foreground —
          // hierarchy from typography, not chrome.
          Row {
            visible: root.coreCount > 0
            spacing: Style.space(6)

            StatLabel { text: "AVG" }
            StatValue { text: Math.round(root.coreAvg) + "%" }
            StatLabel { text: "\u00b7" }
            StatLabel { text: "MAX" }
            StatValue {
              text: Math.round(root.coreMax) + "%"
              color: root.coreMax >= root.cpuAlert ? root.urgent : root.foreground
            }
            StatLabel { text: "\u00b7" }
            StatLabel { text: "LOAD" }
            StatValue {
              text: root.loadavg[0].toFixed(2) + " " + root.loadavg[1].toFixed(2) + " " + root.loadavg[2].toFixed(2)
            }
          }
        }

        // ---------- memory breakdown ----------
        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "MEMORY"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        MemRow {
          label: "Used"
          used: root.mem.used
          total: root.mem.total
        }

        MemRow {
          label: "Cache"
          used: root.mem.cache
          total: root.mem.total
          // Cache is reclaimable headroom, not pressure: no percent, no alert tint.
          pressure: false
        }

        MemRow {
          label: "Swap"
          used: root.mem.swapUsed
          total: root.mem.swapTotal
          visible: root.swapActive
        }

        // ---------- top processes ----------
        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "TOP PROCESSES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "PROCESS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            // 84 = cpu col (36) + gap (6) + mem col (36) + leading gap (6)
            width: parent.width - Style.space(84)
          }
          Text {
            text: "CPU"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            width: Style.space(36)
            horizontalAlignment: Text.AlignRight
          }
          Text {
            text: "MEM"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            width: Style.space(36)
            horizontalAlignment: Text.AlignRight
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(5)

          Repeater {
            model: root.topProcs
            delegate: TopRow { proc: modelData }
          }

          Text {
            visible: root.topProcs.length === 0
            text: "sampling\u2026"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components
  component HeroCell: Item {
    property string title: ""
    property string subtitle: ""
    // Trailing subtitle run (" · 50°C") with its own alert state, so a hot
    // reading can turn urgent without recoloring the whole line.
    property string detail: ""
    property bool detailAlert: false
    property int percent: 0
    property color tint: root.foreground

    width: (parent.width - parent.spacing) / 2
    // +8: capacity track (3px) plus breathing room under the labels.
    implicitHeight: Math.max(labels.implicitHeight, pctLabel.implicitHeight) + Style.space(8)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: pctLabel.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        text: title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        width: parent.width
      }

      Row {
        width: parent.width
        spacing: 0

        Text {
          text: subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width - detailText.width
        }

        Text {
          id: detailText
          text: detail
          visible: text !== ""
          color: detailAlert ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Text {
      id: pctLabel
      text: percent + "%"
      color: tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.displayLarge
      font.bold: true
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }

    // Capacity track anchors the big number and echoes the MemRow language:
    // same 3px pill, alpha track, fill in the cell's state color.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(3)
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

      Rectangle {
        width: Math.max(1, parent.width * (percent / 100))
        height: parent.height
        radius: height / 2
        color: tint

        Behavior on width {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
      }
    }
  }

  component CoreBar: Rectangle {
    property real pct: 0

    readonly property bool hot: pct >= root.cpuAlert
    // Two-tier ink: quiet cores dim their stub so an idle machine reads as
    // "calm", not "broken". Hot cores still get urgent.
    readonly property bool active: pct >= 5

    width: Style.space(12)
    height: Style.space(28)
    radius: Style.space(2)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: Math.max(Style.space(2), pct / 100 * parent.height)
      radius: parent.radius
      color: hot ? root.urgent
        : active ? root.foreground
        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)

      Behavior on height {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
      Behavior on color {
        ColorAnimation { duration: 120 }
      }
    }
  }

  // Footer stat typography for the CPU CORES section: dim bold labels,
  // foreground numbers — hierarchy from type, not chrome.
  component StatLabel: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  component StatValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component MemRow: Item {
    property string label: ""
    property real used: 0
    property real total: 0
    property bool pressure: true

    readonly property real pct: total > 0 ? Math.min(100, used / total * 100) : 0

    width: parent.width
    implicitHeight: Style.space(26)

    Text {
      id: labelText
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
    }

    Item {
      id: track
      anchors.left: labelText.right
      anchors.leftMargin: Style.space(8)
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(3)

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
        radius: height / 2
      }

      Rectangle {
        width: Math.max(1, parent.width * (pct / 100))
        height: parent.height
        radius: height / 2
        color: pressure && pct >= root.memAlert ? root.urgent : root.foreground

        Behavior on width {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: valueText
      text: {
        var right = Model.compactBytes(used)
        if (pressure && total > 0) right += " \u00b7 " + Math.round(pct) + "%"
        return right
      }
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component TopRow: Row {
    property var proc: null

    width: parent.width
    spacing: Style.space(6)

    Text {
      text: proc ? proc.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      // Same right-column budget as the header row.
      width: parent.width - Style.space(84)
    }

    Text {
      text: proc ? proc.cpu.toFixed(1) : ""
      color: proc && proc.cpu >= root.cpuAlert ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      width: Style.space(36)
      horizontalAlignment: Text.AlignRight
    }

    Text {
      text: proc ? proc.mem.toFixed(1) : ""
      color: proc && proc.mem >= root.memAlert / 10 ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      width: Style.space(36)
      horizontalAlignment: Text.AlignRight
    }
  }
}