import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Qwen ASR bar widget.
//
// Left button: push-to-talk — press to arm recording, release to transcribe & auto-paste.
// Right button: toggle the panel (live meter, device status, toggles, recent transcripts, API key).
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

  function openHistoryFile() {
    if (root.bar) root.bar.run("omarchy launch editor " + Util.shellQuote(controller.historyFile))
    else controller.notify("󰈙", "Qwen ASR", "记录文件：" + controller.historyFile, "low")
  }

  function saveKey() {
    var result = controller.setApiKey(keyField.text)
    if (result === "ok") {
      keyField.text = ""
      root.close()
    }
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
          if (!controller.apiKeyConfigured) {
            controller.fail("缺少 DashScope API Key，请在面板中配置", "input")
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
                ? (controller.retryAttempt > 0 ? "识别为空，重试 " + controller.retryAttempt + "/3…" : "转写中…")
                : (root.offline ? "网络不可用 · 右键查看"
                   : (root.hasError ? "上次出错 · 右键查看"
                      : (controller.apiKeyConfigured ? "按住录音 · 松开上屏 · F9" : "未配置 API Key，点击右键配置")))))
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
    focusTarget: keyField
    contentWidth: Style.space(420)
    contentHeight: Style.space(560)

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

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.iconText
              color: (root.recording || root.hasError) ? root.urgent : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.space(18)
            }

            Column {
              width: parent.width - Style.space(26)
              spacing: 1

              Text {
                text: root.arming ? "正在启动麦克风…"
                  : (root.recording ? "正在录音…"
                     : (root.transcribing
                        ? (controller.retryAttempt > 0 ? "正在重试 " + controller.retryAttempt + "/3…" : "正在转写…")
                        : (root.offline ? "网络不可用"
                           : (root.hasError ? "上次出错" : "Qwen Audio 3.0 ASR"))))
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
      Row {
        width: parent.width
        spacing: Style.space(8)

        // Auto Paste Toggle
        Rectangle {
          width: (parent.width - Style.space(8)) / 2
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
          width: (parent.width - Style.space(8)) / 2
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

      PanelSeparator {}

      // Recent Transcripts Header
      Row {
        width: parent.width
        Text {
          text: "最近转写记录"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Math.max(10, Style.font.body * 0.8)
        }
        Item { Layout.fillWidth: true; width: parent.width - Style.space(120) }
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
        height: Math.min(Style.space(220), Math.max(Style.space(60), controller.recent.length * Style.space(52)))
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
              controller.notify("󰆏", "Qwen ASR", "已复制到剪贴板 (" + modelData.text.length + "字)", "low")
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
          text: "暂无转写记录 · 按住 F9 开始语音输入"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      PanelSeparator {}

      // Settings: API key
      Row {
        width: parent.width
        spacing: Style.space(8)

        TextField {
          id: keyField
          width: parent.width - saveButton.width - Style.space(8)
          placeholderText: controller.apiKeyConfigured ? "API Key 已配置（输入以更换）" : "输入 DashScope API Key"
          echoMode: TextInput.Password
          color: root.foreground
          placeholderTextColor: root.dim
          background: Rectangle {
            radius: Style.space(4)
            color: "transparent"
            border.width: 1
            border.color: root.dim
          }
          onAccepted: saveKey()
        }

        Button {
          id: saveButton
          text: "保存"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: saveKey()
        }
      }

      // Footer actions
      Row {
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
        Item { Layout.fillWidth: true; width: parent.width - Style.space(260) }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "快捷键 F9"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Math.max(10, Style.font.body * 0.8)
        }
      }
    }
  }
}
