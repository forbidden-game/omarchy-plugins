import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"

Item {
  id: root

  property var shell: null
  property bool closingFromHost: false
  property bool draftHydrated: false
  property bool confirming: false
  property int confirmCount: 0
  property int expandedHistoryIndex: -1
  property var entries: []
  property var captureQueue: []
  property var deferredRecords: []
  property string statusText: ""
  property string statusKind: "info"
  property string consumeError: ""
  property string copyError: ""

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string stateDir: stateHome + "/omarchy/discuss"
  readonly property string draftPath: stateDir + "/draft.json"
  readonly property string controlPath: root.home + "/.config/omarchy/plugins/eipi10.discuss/bin/discuss-ctl"
  readonly property color foreground: Color.popups.text
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property int windowHeightLimit: window.screen
    ? Math.max(Style.space(420), Math.floor(window.screen.height * 0.75))
    : Style.space(720)

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true

    var payload = null
    if (payloadJson) {
      try {
        payload = JSON.parse(String(payloadJson))
      } catch (error) {
        showStatus("呼出参数无法解析", "error")
      }
    }

    if (payload && payload.error) {
      showStatus(payload.message || "没有读到当前选区；请先选中文字", "error")
    } else if (payload && typeof payload.path === "string") {
      enqueueCapture(payload.path)
    }

    Qt.callLater(function() {
      if (entries.length > 0) focusCurrentEditor()
      else focusScope.forceActiveFocus()
    })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("eipi10.discuss")
    else window.visible = false
  }

  function showStatus(message, kind) {
    statusText = String(message || "")
    statusKind = kind || "info"
    statusTimer.restart()
  }

  function enqueueCapture(path) {
    captureQueue = captureQueue.concat([path])
    runNextCapture()
  }

  function runNextCapture() {
    if (consumeProcess.running || captureQueue.length === 0) return
    var nextPath = captureQueue[0]
    captureQueue = captureQueue.slice(1)
    consumeError = ""
    consumeProcess.command = [controlPath, "consume", nextPath]
    consumeProcess.running = true
  }

  function acceptCapture(raw) {
    var record
    try {
      record = JSON.parse(String(raw || ""))
    } catch (error) {
      showStatus("选区记录无法解析", "error")
      return
    }
    if (!record || typeof record.text !== "string" || !record.text.trim()) {
      showStatus("没有读到有效选区", "error")
      return
    }
    record.discussion = ""

    if (!draftHydrated || confirming) {
      deferredRecords = deferredRecords.concat([record])
      return
    }
    appendRecord(record)
  }

  function isDuplicate(previous, record) {
    return previous
      && String(previous.text || "") === String(record.text || "")
      && String(previous.sourceClass || "") === String(record.sourceClass || "")
      && Math.abs(Number(previous.capturedAtMs || 0) - Number(record.capturedAtMs || 0)) < 1500
  }

  function appendRecord(record) {
    var previous = entries.length > 0 ? entries[entries.length - 1] : null
    if (isDuplicate(previous, record)) {
      showStatus("已忽略一次重复呼出", "info")
      return
    }

    expandedHistoryIndex = -1
    entries = entries.concat([record])
    saveNow()
    showStatus("已加入第 " + entries.length + " 组选区", "info")
    Qt.callLater(function() {
      scrollToBottom()
      focusCurrentEditor()
    })
  }

  function applyDeferredRecords() {
    if (!draftHydrated || confirming || deferredRecords.length === 0) return
    var waiting = deferredRecords
    deferredRecords = []
    var merged = entries.slice()
    for (var i = 0; i < waiting.length; i++) {
      var previous = merged.length > 0 ? merged[merged.length - 1] : null
      if (!isDuplicate(previous, waiting[i])) merged.push(waiting[i])
    }
    if (merged.length === entries.length) {
      showStatus("已忽略一次重复呼出", "info")
      return
    }
    expandedHistoryIndex = -1
    entries = merged
    saveNow()
    showStatus("已加入第 " + entries.length + " 组选区", "info")
    Qt.callLater(function() {
      scrollToBottom()
      focusCurrentEditor()
    })
  }

  function restoreDraft(raw) {
    if (draftHydrated) return
    var restored = []
    try {
      var parsed = JSON.parse(String(raw || ""))
      var candidate = parsed && Array.isArray(parsed.entries) ? parsed.entries : []
      for (var i = 0; i < candidate.length; i++) {
        var entry = candidate[i]
        if (!entry || typeof entry.text !== "string" || !entry.text.trim()) continue
        restored.push({
          schemaVersion: 1,
          id: String(entry.id || ""),
          text: entry.text,
          discussion: String(entry.discussion || ""),
          sourceClass: String(entry.sourceClass || ""),
          sourceTitle: String(entry.sourceTitle || ""),
          capturedAt: String(entry.capturedAt || ""),
          capturedAtMs: Number(entry.capturedAtMs || 0),
          truncated: entry.truncated === true
        })
      }
    } catch (error) {
      if (String(raw || "").trim()) showStatus("草稿损坏，已从空白轮次继续", "error")
    }
    entries = restored
    draftHydrated = true
    applyDeferredRecords()
  }

  function updateDiscussion(index, text) {
    if (index < 0 || index >= entries.length) return
    if (String(entries[index].discussion || "") === String(text)) return
    entries[index].discussion = String(text)
    saveDebounce.restart()
  }

  function toggleHistory(index) {
    if (index < 0 || index >= entries.length - 1) return
    expandedHistoryIndex = expandedHistoryIndex === index ? -1 : index
  }

  function serializedDraft() {
    return JSON.stringify({
      schemaVersion: 1,
      entries: entries
    }, null, 2) + "\n"
  }

  function secureDraft() {
    if (!draftPermissions.running) draftPermissions.running = true
  }

  function saveNow() {
    saveDebounce.stop()
    if (!draftHydrated) return
    draftFile.setText(serializedDraft())
  }

  function confirmRound() {
    if (confirming || entries.length === 0) return
    confirming = true
    confirmCount = entries.length
    copyError = ""
    saveDebounce.stop()
    draftFile.setText(serializedDraft())
    showStatus("正在整理并复制本轮…", "info")
  }

  function finishCopy() {
    var copiedCount = confirmCount
    var waiting = deferredRecords
    deferredRecords = []
    confirming = false
    confirmCount = 0
    expandedHistoryIndex = -1
    var nextRound = []
    for (var i = 0; i < waiting.length; i++) {
      var previous = nextRound.length > 0 ? nextRound[nextRound.length - 1] : null
      if (!isDuplicate(previous, waiting[i])) nextRound.push(waiting[i])
    }
    entries = nextRound
    saveNow()
    showStatus("已复制 " + copiedCount + " 组选区与讨论", "success")
    Qt.callLater(function() {
      if (entries.length > 0) focusCurrentEditor()
      else focusScope.forceActiveFocus()
    })
  }

  function failCopy(message) {
    var waiting = deferredRecords
    deferredRecords = []
    confirming = false
    confirmCount = 0
    if (waiting.length > 0) {
      var merged = entries.slice()
      for (var i = 0; i < waiting.length; i++) {
        var previous = merged.length > 0 ? merged[merged.length - 1] : null
        if (!isDuplicate(previous, waiting[i])) merged.push(waiting[i])
      }
      expandedHistoryIndex = -1
      entries = merged
      saveNow()
    }
    showStatus(message || "复制失败，草稿仍然保留", "error")
  }

  function focusCurrentEditor() {
    if (entries.length === 0) return
    var pair = pairRepeater.itemAt(entries.length - 1)
    if (pair) pair.focusEditor()
  }

  function scrollToBottom() {
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    flick.contentY = Math.max(0, flick.contentHeight - flick.height)
  }

  Timer {
    id: saveDebounce
    interval: 220
    repeat: false
    onTriggered: root.saveNow()
  }

  Timer {
    id: statusTimer
    interval: 4200
    repeat: false
    onTriggered: root.statusText = ""
  }

  Process {
    id: ensureStateDirectory
    running: false
    command: ["mkdir", "-m", "700", "-p", root.stateDir]
    onExited: draftFile.reload()
  }

  Process {
    id: draftPermissions
    running: false
    command: ["chmod", "600", root.draftPath]
  }

  Process {
    id: consumeProcess
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptCapture(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.consumeError = String(text || "").trim()
    }

    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.showStatus(root.consumeError || "无法读取这次选区", "error")
      root.runNextCapture()
    }
  }

  Process {
    id: copyProcess
    running: false
    command: [root.controlPath, "copy", root.draftPath]

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.copyError = String(text || "").trim()
    }

    onExited: function(exitCode) {
      if (exitCode === 0) root.finishCopy()
      else root.failCopy(root.copyError || "复制失败，草稿仍然保留")
    }
  }

  FileView {
    id: draftFile
    path: root.draftPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.secureDraft()
      root.restoreDraft(text())
    }
    onLoadFailed: function(_error) {
      if (!root.draftHydrated) root.restoreDraft("")
    }
    onSaved: {
      root.secureDraft()
      if (root.confirming && !copyProcess.running) {
        root.copyError = ""
        copyProcess.running = true
      }
    }
    onSaveFailed: function(_error) {
      if (root.confirming) root.failCopy("无法保存草稿，尚未写入剪贴板")
      else root.showStatus("草稿保存失败", "error")
    }
  }

  Component.onCompleted: ensureStateDirectory.running = true

  FloatingWindow {
    id: window
    title: "Discuss"
    color: root.background
    visible: false
    implicitWidth: Style.space(540)
    implicitHeight: Math.min(Style.space(610), root.windowHeightLimit)
    minimumSize: Qt.size(Style.space(380), Style.space(420))
    maximumSize: Qt.size(Style.space(900), root.windowHeightLimit)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("eipi10.discuss")
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.requestClose()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Return) {
          root.confirmRound()
          event.accepted = true
        }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item {
          id: header
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(50)

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onPressed: window.startSystemMove()
          }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(9)

            Rectangle {
              Layout.preferredWidth: Style.space(22)
              Layout.preferredHeight: Style.space(22)
              radius: width / 2
              color: root.accent

              Text {
                anchors.centerIn: parent
                text: "D"
                color: Color.background
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0

              Text {
                text: "Discuss"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: root.entries.length > 0
                  ? root.entries.length + " 组配对 · 当前编辑第 " + root.entries.length + " 组"
                  : "选中任意文字，再按 Super + D"
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Button {
              text: "隐藏"
              focusable: true
              foreground: root.foreground
              background: "transparent"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(5)
              onClicked: root.requestClose()
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(1, Style.normalBorderWidth)
          color: Color.popups.border
        }

        BorderSurface {
          visible: root.statusText !== ""
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(14)
          Layout.rightMargin: Style.space(14)
          Layout.topMargin: visible ? Style.space(10) : 0
          Layout.preferredHeight: visible ? statusLabel.implicitHeight + Style.space(14) : 0
          radius: Style.cornerRadius
          color: root.statusKind === "error"
            ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
            : root.statusKind === "success"
              ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
              : Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.flat(
            root.statusKind === "error" ? Color.urgent : root.accent,
            Math.max(1, Style.normalBorderWidth)
          )

          Text {
            id: statusLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            text: root.statusText
            color: root.statusKind === "error" ? Color.urgent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        ScrollView {
          id: scrollArea
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.leftMargin: Style.space(14)
          Layout.rightMargin: Style.space(14)
          Layout.topMargin: Style.space(10)
          Layout.bottomMargin: Style.space(10)
          clip: true
          contentWidth: availableWidth
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          ScrollBar.vertical.policy: ScrollBar.AsNeeded

          Column {
            width: scrollArea.availableWidth
            spacing: Style.space(10)

            Item {
              visible: root.entries.length === 0
              width: parent.width
              height: visible ? Math.max(Style.space(210), scrollArea.availableHeight - Style.space(8)) : 0

              Column {
                anchors.centerIn: parent
                width: Math.min(parent.width - Style.space(40), Style.space(360))
                spacing: Style.space(10)

                Text {
                  width: parent.width
                  text: "还没有选区"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  width: parent.width
                  text: "在任何应用里选中文字，按 Super + D。\n每次选区都会和一段独立讨论成对加入当前轮次。"
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  horizontalAlignment: Text.AlignHCenter
                  lineHeight: 1.25
                }
              }
            }

            Repeater {
              id: pairRepeater
              model: root.entries

              delegate: DiscussionPair {
                required property int index
                required property var modelData

                width: scrollArea.availableWidth
                entry: modelData
                pairIndex: index
                current: index === root.entries.length - 1
                opened: root.expandedHistoryIndex === index
                onToggled: root.toggleHistory(index)
                onDiscussionEdited: function(text) {
                  root.updateDiscussion(index, text)
                }
              }
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(1, Style.normalBorderWidth)
          color: Color.popups.border
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(14)
          Layout.rightMargin: Style.space(14)
          Layout.topMargin: Style.space(11)
          Layout.bottomMargin: Style.space(11)
          spacing: Style.space(10)

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              text: "下一次 Super + D 会折叠当前配对并新建一组"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }

            Text {
              text: "确认后复制全部 Markdown；最后一段讨论可留空"
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }
          }

          Button {
            text: root.confirming ? "复制中…" : "确认本轮 · 复制"
            focusable: true
            selected: true
            bordered: true
            enabled: root.entries.length > 0 && !root.confirming
            foreground: root.foreground
            accent: root.accent
            onClicked: root.confirmRound()
          }
        }
      }

      Rectangle {
        width: Style.space(16)
        height: Style.space(16)
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: "transparent"

        Rectangle {
          width: Style.space(7)
          height: Math.max(1, Style.normalBorderWidth)
          color: root.muted
          rotation: -45
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: Style.space(2)
          anchors.bottomMargin: Style.space(4)
        }

        Rectangle {
          width: Style.space(11)
          height: Math.max(1, Style.normalBorderWidth)
          color: root.muted
          rotation: -45
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: Style.space(1)
          anchors.bottomMargin: Style.space(5)
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.SizeFDiagCursor
          onPressed: window.startSystemResize(Qt.RightEdge | Qt.BottomEdge)
        }
      }
    }
  }
}
