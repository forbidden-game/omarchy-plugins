import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omarvoice bar widget (the qwen-asr module id is retained for compatibility).
//
// Left button: push-to-talk — press to arm recording, release to transcribe & auto-paste.
// Right button: toggle the panel (device, Agent Panel auth, shortcuts, and history).
// Global push-to-talk: F9 via Hyprland bind -> `omarchy-shell qwen-asr start/stop`.
Panel {
  id: root
  moduleName: "qwen-asr"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  QwenAsrController {
    id: controller
  }

  // Floating capsule HUD overlay
  QwenAsrHud {
    controller: controller
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color barIconColor: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  readonly property bool arming: controller.state === "arming"
  readonly property bool recording: controller.state === "recording"
  readonly property bool transcribing: controller.state === "transcribing"
  readonly property bool offline: controller.errorKind === "offline"
  readonly property bool hasError: controller.lastError !== ""

  readonly property string iconText: root.hasError ? "!" : (root.transcribing ? "󰔟" : "󰍬")
  readonly property string timerText: {
    if (!recording && !transcribing) return ""
    var s = controller.elapsedSec
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  readonly property int meterBarWidth: 3
  readonly property int meterBarGap: 2
  readonly property int meterMaxHeight: Math.max(10, Math.round(root.barSize * 0.55))
  readonly property int meterWidth: controller.barCount * (meterBarWidth + meterBarGap) - meterBarGap

  // Shortcut capture state
  property bool capturingShortcut: false
  property string detectedKey: ""
  property string detectedDisplayName: ""

  function startCapturing() {
    root.capturingShortcut = true
    root.detectedKey = ""
    root.detectedDisplayName = ""
    Qt.callLater(function() {
      if (captureFocusItem) captureFocusItem.forceActiveFocus()
    })
  }

  function stopCapturing() {
    root.capturingShortcut = false
    root.detectedKey = ""
    root.detectedDisplayName = ""
  }

  function applyShortcut(key) {
    controller.setShortcut(key, function(ok) {
      if (ok) root.stopCapturing()
    })
  }

  function keyEventToHyprland(event) {
    var key = event.key
    var modifiers = event.modifiers

    if (key === Qt.Key_Control || key === Qt.Key_Shift || key === Qt.Key_Alt ||
        key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R ||
        key === Qt.Key_AltGr) {
      return null
    }

    var parts = []
    if (modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (modifiers & Qt.AltModifier) parts.push("ALT")
    if (modifiers & Qt.ShiftModifier) parts.push("SHIFT")

    var keyName = ""
    if (key >= Qt.Key_F1 && key <= Qt.Key_F35) {
      keyName = "F" + (key - Qt.Key_F1 + 1)
    } else if (key >= Qt.Key_A && key <= Qt.Key_Z) {
      keyName = String.fromCharCode(key)
    } else if (key >= Qt.Key_0 && key <= Qt.Key_9) {
      keyName = String.fromCharCode(key)
    } else {
      switch (key) {
        case Qt.Key_Space: keyName = "SPACE"; break
        case Qt.Key_Return: case Qt.Key_Enter: keyName = "Return"; break
        case Qt.Key_Tab: keyName = "Tab"; break
        case Qt.Key_Backtab: keyName = "Backtab"; break
        case Qt.Key_Backspace: keyName = "BackSpace"; break
        case Qt.Key_CapsLock: keyName = "Caps_Lock"; break
        case Qt.Key_ScrollLock: keyName = "Scroll_Lock"; break
        case Qt.Key_NumLock: keyName = "Num_Lock"; break
        case Qt.Key_Print: keyName = "Print"; break
        case Qt.Key_Pause: keyName = "Pause"; break
        case Qt.Key_Insert: keyName = "Insert"; break
        case Qt.Key_Delete: keyName = "Delete"; break
        case Qt.Key_Home: keyName = "Home"; break
        case Qt.Key_End: keyName = "End"; break
        case Qt.Key_PageUp: keyName = "Prior"; break
        case Qt.Key_PageDown: keyName = "Next"; break
        case Qt.Key_Up: keyName = "Up"; break
        case Qt.Key_Down: keyName = "Down"; break
        case Qt.Key_Left: keyName = "Left"; break
        case Qt.Key_Right: keyName = "Right"; break
        case Qt.Key_QuoteLeft: case Qt.Key_AsciiTilde: keyName = "grave"; break
        case Qt.Key_Minus: keyName = "minus"; break
        case Qt.Key_Equal: keyName = "equal"; break
        case Qt.Key_BracketLeft: keyName = "bracketleft"; break
        case Qt.Key_BracketRight: keyName = "bracketright"; break
        case Qt.Key_Backslash: keyName = "backslash"; break
        case Qt.Key_Semicolon: keyName = "semicolon"; break
        case Qt.Key_Apostrophe: keyName = "apostrophe"; break
        case Qt.Key_Comma: keyName = "comma"; break
        case Qt.Key_Period: keyName = "period"; break
        case Qt.Key_Slash: keyName = "slash"; break
        default:
          if (event.text && event.text.length === 1 && event.text.charCodeAt(0) > 32) {
            keyName = event.text.toUpperCase()
          }
          break
      }
    }

    if (!keyName) return null

    var res = []
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] !== keyName) res.push(parts[i])
    }
    res.push(keyName)
    return res.join(" + ")
  }

  function mouseEventToHyprland(mouse) {
    var btn = mouse.button
    var modifiers = mouse.modifiers || 0

    var parts = []
    if (modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (modifiers & Qt.AltModifier) parts.push("ALT")
    if (modifiers & Qt.ShiftModifier) parts.push("SHIFT")

    var mouseKey = ""
    if (btn === Qt.BackButton || btn === 8) mouseKey = "mouse:275"
    else if (btn === Qt.ForwardButton || btn === 16) mouseKey = "mouse:276"
    else if (btn === Qt.MiddleButton || btn === 4) mouseKey = "mouse:274"
    else if (btn === Qt.RightButton || btn === 2) mouseKey = "mouse:273"
    else if (btn === Qt.LeftButton || btn === 1) mouseKey = "mouse:272"
    else if (btn === Qt.TaskButton || btn === 32) mouseKey = "mouse:277"
    else if (btn === 64) mouseKey = "mouse:278"
    else if (btn === 128) mouseKey = "mouse:279"
    else return null

    parts.push(mouseKey)
    return parts.join(" + ")
  }

  function openHistoryFile() {
    if (root.bar) root.bar.run("omarchy launch editor " + Util.shellQuote(controller.historyFile))
    else controller.notify("󰈙", "Omarvoice", "记录文件：" + controller.historyFile, "low")
  }

  // ------------------------------------------------------------------ icon
  Item {
    id: button
    anchors.fill: parent
    implicitWidth: Style.bar.iconSlot
      + (root.recording ? root.meterWidth + Style.space(4) : 0)
      + ((root.recording || root.transcribing) ? timerLabel.implicitWidth + Style.space(4) : 0)
    implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onPressed: function(mouse) {
        if (mouse.button === Qt.LeftButton) {
          if (!controller.authReady) {
            controller.loadAuthStatus()
            controller.fail(controller.authMessage || "Agent Panel 鉴权尚未就绪", "auth")
            root.open()
            return
          }
          controller.startRecording()
        } else {
          root.toggle()
        }
      }
      onReleased: function(mouse) {
        if (mouse.button === Qt.LeftButton) controller.stopRecording()
      }
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(4)

      Item {
        width: Style.bar.iconSlot
        height: Style.bar.iconSlot

        Text {
          anchors.centerIn: parent
          text: root.iconText
          color: root.hasError ? root.urgent : (root.recording ? root.urgent : (root.arming ? "#F59E0B" : (root.transcribing ? root.accent : root.barIconColor)))
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          opacity: root.transcribing ? 0.65 : 1
        }
      }

      // Live recording level
      Item {
        id: meterWrap
        visible: root.recording
        width: root.recording ? root.meterWidth : 0
        height: root.barSize
        anchors.verticalCenter: parent.verticalCenter

        Behavior on width {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }

        LevelMeter {
          anchors.verticalCenter: parent.verticalCenter
          levels: controller.barLevels
          barWidth: root.meterBarWidth
          barGap: root.meterBarGap
          maxHeight: root.meterMaxHeight
          minHeight: 2
          color: root.foreground
          hotColor: root.urgent
        }
      }

      Text {
        id: timerLabel
        visible: root.recording || root.transcribing
        anchors.verticalCenter: parent.verticalCenter
        text: root.timerText
        color: root.recording ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Math.max(9, Style.font.body * 0.72)
        font.bold: true
      }
    }

    // Tooltip
    Rectangle {
      visible: mouseArea.containsMouse
      anchors.top: parent.bottom
      anchors.topMargin: Style.space(4)
      anchors.horizontalCenter: parent.horizontalCenter
      width: tipText.implicitWidth + Style.space(16)
      height: tipText.implicitHeight + Style.space(6)
      radius: Style.space(4)
      color: Color.popups.background
      border.color: Color.popups.border
      border.width: 1
      z: 100

      Text {
        id: tipText
        anchors.centerIn: parent
        text: root.arming ? "正在启动麦克风…"
          : (root.recording ? (controller.autoPaste ? "松开以转写并直接上屏" : "松开以转写到剪贴板")
             : (root.transcribing
                ? "Antigravity 云端转写中…"
                : (root.offline ? "网络不可用 · 右键查看"
                   : (root.hasError ? "上次出错 · 右键查看"
                      : (controller.authReady
                         ? ("按住录音 · 松开上屏 · " + controller.currentShortcutDisplay)
                         : "Agent Panel 鉴权未就绪 · 右键处理")))))
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // ----------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.capturingShortcut ? captureFocusItem : authButton
    contentWidth: Style.space(460)
    contentHeight: root.capturingShortcut ? Style.space(680) : Style.space(630)

    Behavior on contentHeight {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    Column {
      width: panel.contentWidth - Style.spacing.popupPadding * 2
      spacing: Style.space(10)

      // Header Status Card
      Rectangle {
        width: parent.width
        implicitHeight: headerCol.implicitHeight + Style.space(16)
        radius: Style.space(6)
        color: Style.selectedFillFor(root.foreground, root.accent)
        border.color: root.hasError ? root.urgent : Color.popups.border
        border.width: 1

        Column {
          id: headerCol
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(4)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: root.iconText
              color: (root.recording || root.hasError) ? root.urgent : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.space(18)
            }

            Column {
              Layout.fillWidth: true
              spacing: 1

              Text {
                text: root.arming ? "正在启动麦克风…"
                  : (root.recording ? "正在录音…"
                     : (root.transcribing
                        ? "正在通过 Antigravity 云端转写…"
                        : (root.offline ? "网络不可用"
                           : (root.hasError ? "上次出错" : "Omarvoice · Antigravity Cloud"))))
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                text: "当前设备：" + controller.activeMicName
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Math.max(10, Style.font.body * 0.76)
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // Error description if any
          Text {
            visible: root.hasError
            text: controller.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Math.max(10, Style.font.body * 0.78)
            wrapMode: Text.Wrap
            width: parent.width
          }
        }
      }

      // Feature Toggles Row
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        // Auto Paste Toggle
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(34)
          radius: Style.space(4)
          color: controller.autoPaste ? Style.selectedFillFor(root.accent, root.accent) : "transparent"
          border.color: controller.autoPaste ? root.accent : root.dim
          border.width: 1

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: controller.setAutoPaste(!controller.autoPaste)
          }

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: controller.autoPaste ? "󰄬" : "󰄱"
              color: controller.autoPaste ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "自动直接上屏"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Math.max(10, Style.font.body * 0.8)
              font.bold: controller.autoPaste
            }
          }
        }

        // Floating HUD Toggle
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(34)
          radius: Style.space(4)
          color: controller.showHud ? Style.selectedFillFor(root.accent, root.accent) : "transparent"
          border.color: controller.showHud ? root.accent : root.dim
          border.width: 1

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: controller.setShowHud(!controller.showHud)
          }

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: controller.showHud ? "󰄬" : "󰄱"
              color: controller.showHud ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "悬浮灵动胶囊"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Math.max(10, Style.font.body * 0.8)
              font.bold: controller.showHud
            }
          }
        }
      }

      // Shortcut Settings Card
      Rectangle {
        width: parent.width
        implicitHeight: shortcutCol.implicitHeight + Style.space(16)
        radius: Style.space(6)
        color: Style.selectedFillFor(root.foreground, root.accent)
        border.color: root.capturingShortcut ? root.accent : Color.popups.border
        border.width: 1

        Column {
          id: shortcutCol
          anchors.fill: parent
          anchors.margins: Style.space(10)
          spacing: Style.space(10)

          // 1. Header: Icon + Title + Custom Record Button
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: controller.shortcutIcon(controller.currentShortcut)
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.space(18)
            }

            Column {
              Layout.fillWidth: true
              spacing: 1
              Text {
                text: "按住对讲快捷键"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                text: "长按录音 · 松开转写 (支持键盘/鼠标侧键)"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Math.max(9, Style.font.body * 0.72)
              }
            }

            Button {
              text: root.capturingShortcut ? "取消" : "自定义录制"
              bordered: true
              foreground: root.capturingShortcut ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                if (root.capturingShortcut) root.stopCapturing()
                else root.startCapturing()
              }
            }
          }

          // 2. Interactive Key/Mouse Capture Area (Visible when capturingShortcut is true)
          Rectangle {
            visible: root.capturingShortcut
            width: parent.width
            height: Style.space(42)
            radius: Style.space(4)
            color: Style.selectedFillFor(root.accent, root.accent)
            border.color: root.accent
            border.width: 1

            Item {
              id: captureFocusItem
              anchors.fill: parent
              focus: root.capturingShortcut

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (!root.capturingShortcut) return
                if (event.key === Qt.Key_Escape) {
                  root.stopCapturing()
                  event.accepted = true
                  return
                }
                var combo = root.keyEventToHyprland(event)
                if (combo) {
                  root.detectedKey = combo
                  root.detectedDisplayName = controller.friendlyShortcutName(combo)
                  event.accepted = true
                }
              }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                hoverEnabled: true
                cursorShape: Qt.CrossCursor

                onPressed: function(mouse) {
                  if (!root.capturingShortcut) return
                  var combo = root.mouseEventToHyprland(mouse)
                  if (combo) {
                    root.detectedKey = combo
                    root.detectedDisplayName = controller.friendlyShortcutName(combo)
                    mouse.accepted = true
                  }
                }
              }

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                spacing: Style.space(8)

                Text {
                  text: root.detectedKey !== "" ? "󰄬" : "󰍬"
                  color: root.detectedKey !== "" ? "#34D399" : root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(15)
                }

                Text {
                  Layout.fillWidth: true
                  text: root.detectedKey !== ""
                    ? ("已捕获: " + root.detectedDisplayName)
                    : "请按键盘按键或点击鼠标键(支持侧键)..."
                  color: root.detectedKey !== "" ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Math.max(10, Style.font.body * 0.8)
                  font.bold: root.detectedKey !== ""
                  elide: Text.ElideRight
                }

                Button {
                  visible: root.detectedKey !== ""
                  text: "保存应用"
                  bordered: true
                  foreground: root.accent
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (root.detectedKey !== "") {
                      root.applyShortcut(root.detectedKey)
                    }
                  }
                }
              }
            }
          }

          // 3. Preset Chips (Clean consistent Omarchy tokens)
          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: [
                { icon: "󰌌", name: "F9 (默认)", key: "F9" },
                { icon: "󰍽", name: "侧键(后退·275)", key: "mouse:275" },
                { icon: "󰍽", name: "侧键(前进·276)", key: "mouse:276" },
                { icon: "󰍽", name: "中键(274)", key: "mouse:274" },
                { icon: "󰌌", name: "Super+Shift+F9", key: "SUPER + SHIFT + F9" }
              ]

              delegate: Rectangle {
                readonly property bool isSelected: controller.currentShortcut === modelData.key
                height: Style.space(26)
                width: chipRow.implicitWidth + Style.space(14)
                radius: Style.space(4)
                color: isSelected
                  ? Style.selectedFillFor(root.accent, root.accent)
                  : (chipHover.containsMouse ? Style.selectedFillFor(root.foreground, root.accent) : "transparent")
                border.color: isSelected ? root.accent : (chipHover.containsMouse ? root.accent : root.dim)
                border.width: 1

                MouseArea {
                  id: chipHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.applyShortcut(modelData.key)
                }

                Row {
                  id: chipRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: isSelected ? "󰄬" : modelData.icon
                    color: isSelected ? root.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(11)
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.name
                    color: isSelected ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Math.max(9, Style.font.body * 0.76)
                    font.bold: isSelected
                  }
                }
              }
            }
          }
        }
      }

      PanelSeparator {}

      // Recent Transcripts Header
      RowLayout {
        width: parent.width
        Text {
          text: "最近转写记录"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Math.max(10, Style.font.body * 0.8)
        }
        Item { Layout.fillWidth: true }
        Text {
          visible: controller.recent.length > 0
          text: "清空历史"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Math.max(10, Style.font.body * 0.76)
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: controller.clearHistory()
          }
        }
      }

      ListView {
        id: historyList
        width: parent.width
        height: Math.min(Style.space(160), Math.max(Style.space(50), controller.recent.length * Style.space(50)))
        clip: true
        model: controller.recent
        spacing: Style.space(4)

        delegate: Rectangle {
          width: historyList.width
          height: Style.space(48)
          radius: Style.space(4)
          color: mouse.containsMouse ? root.track : "transparent"
          border.color: mouse.containsMouse ? root.accent : "transparent"
          border.width: 1

          MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
              Quickshell.clipboardText = modelData.text
              controller.notify("󰆏", "Omarvoice", "已复制到剪贴板 (" + modelData.text.length + "字)", "low")
            }
          }

          RowLayout {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            spacing: Style.space(8)

            Column {
              Layout.fillWidth: true
              spacing: 2
              Row {
                spacing: Style.space(6)
                Text {
                  text: modelData.time
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Math.max(9, Style.font.body * 0.72)
                }
                Text {
                  text: "· " + modelData.text.length + " 字"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Math.max(9, Style.font.body * 0.72)
                }
              }
              Text {
                text: modelData.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Math.max(11, Style.font.body * 0.85)
                elide: Text.ElideRight
                width: parent.width
              }
            }

            // Copy Icon Button
            Text {
              visible: mouse.containsMouse
              text: "󰆏"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.space(14)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: controller.recent.length === 0
          text: "暂无转写记录 · 按住 " + controller.currentShortcutDisplay + " 开始语音输入"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      PanelSeparator {}

      // Agent Panel owns long-lived OAuth; Omarvoice only reports readiness.
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: controller.authReady ? "󰄬"
            : (controller.authState === "checking" || controller.authState === "authorizing"
               ? "󰔟" : "󰅚")
          color: controller.authReady ? root.accent
            : (controller.authState === "checking" || controller.authState === "authorizing"
               ? root.dim : root.urgent)
          font.family: root.fontFamily
          font.pixelSize: Style.space(16)
        }

        Column {
          Layout.fillWidth: true
          spacing: 1

          Text {
            text: "Agent Panel 长期鉴权"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            width: parent.width
            text: (controller.authAccount !== "" ? controller.authAccount + " · " : "")
              + controller.authMessage
            color: controller.authReady ? root.dim : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Math.max(9, Style.font.body * 0.72)
            elide: Text.ElideRight
          }
        }

        Button {
          id: authButton
          text: controller.authReady ? "刷新"
            : (controller.authState === "authorizing" || controller.authState === "checking"
               ? "检查" : "重新授权")
          bordered: true
          foreground: controller.authReady ? root.foreground : root.accent
          fontFamily: root.fontFamily
          onClicked: {
            if (controller.authReady || controller.authState === "authorizing"
                || controller.authState === "checking") {
              controller.loadAuthStatus()
            } else {
              controller.beginAuthorization()
            }
          }
        }
      }

      // Footer actions
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Button {
          text: "打开记录文件"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openHistoryFile()
        }
        Button {
          text: "清除错误"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: controller.clearError()
        }
        Item { Layout.fillWidth: true }
        Text {
          text: controller.shortcutIcon(controller.currentShortcut) + " " + controller.currentShortcutDisplay
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Math.max(10, Style.font.body * 0.78)
          elide: Text.ElideRight
          Layout.maximumWidth: Style.space(180)
        }
      }
    }
  }
}
