import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Floating capsule HUD for Qwen ASR push-to-talk.
// Renders a smooth, non-intrusive pill at the bottom-center of the screen
// during cold-start arming, active recording, transcription, and instant completion.
//
// Uses WlrKeyboardFocus.None so it never steals focus from the user's active
// text editor, browser, or terminal.
PanelWindow {
  id: hud

  required property var controller

  screen: Quickshell.focusedScreen || (Quickshell.screens && Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)

  anchors {
    bottom: true
  }
  margins {
    bottom: Style.space(76)
  }

  readonly property bool active: controller.showHud && controller.hudVisible

  // Fixed canvas size for the Wayland surface.
  // This guarantees the LayerShell surface is NEVER resized or re-anchored by the compositor,
  // completely eliminating all window tearing, layout fighting, and jitter.
  implicitWidth: Style.space(400)
  implicitHeight: Style.space(56)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "qwen-asr-hud"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  visible: active

  readonly property color bg: Color.popups.background
  readonly property color borderCol: Color.popups.border
  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color amber: "#F59E0B"
  readonly property color mintGreen: "#34D399"
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: Style.font.family

  readonly property string status: hud.controller.hudStatus // arming | recording | transcribing | success | error

  Rectangle {
    id: capsule
    anchors.centerIn: parent
    implicitHeight: Style.space(42)
    radius: height / 2
    color: hud.bg
    border.width: Math.max(1, Style.space(1.5))
    clip: true

    border.color: {
      if (hud.status === "error") return hud.urgent
      if (hud.status === "recording") return hud.urgent
      if (hud.status === "arming") return hud.amber
      if (hud.status === "transcribing") return hud.accent
      if (hud.status === "success") return hud.mintGreen
      return hud.borderCol
    }

    implicitWidth: {
      if (hud.status === "arming") return Style.space(220)
      if (hud.status === "recording") return Style.space(240)
      if (hud.status === "transcribing") return Style.space(190)
      if (hud.status === "success") return Math.max(Style.space(210), labelText.implicitWidth + Style.space(72))
      if (hud.status === "error") return Math.min(Style.space(360), labelText.implicitWidth + Style.space(60))
      return Style.space(200)
    }

    opacity: hud.active ? 1.0 : 0.0
    scale: hud.active ? 1.0 : 0.90

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutQuad }
    }
    Behavior on scale {
      NumberAnimation { duration: 160; easing.type: Easing.OutBack; easing.overshoot: 1.08 }
    }
    Behavior on implicitWidth {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }
    Behavior on border.color {
      ColorAnimation { duration: 150 }
    }

    RowLayout {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(10)

      // State Icon / Badge
      Item {
        Layout.preferredWidth: Style.space(20)
        Layout.preferredHeight: Style.space(20)

        // 1. Arming / Cold Start: Pulsing Amber Mic
        Text {
          anchors.centerIn: parent
          visible: hud.status === "arming"
          text: "󰍬"
          color: hud.amber
          font.family: hud.fontFamily
          font.pixelSize: Style.space(16)

          SequentialAnimation on opacity {
            running: hud.status === "arming"
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.25; duration: 320; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.25; to: 1.0; duration: 320; easing.type: Easing.InOutQuad }
          }
        }

        // 2. Active Recording: Glowing Red Mic
        Text {
          anchors.centerIn: parent
          visible: hud.status === "recording"
          text: "󰍬"
          color: hud.urgent
          font.family: hud.fontFamily
          font.pixelSize: Style.space(16)

          SequentialAnimation on opacity {
            running: hud.status === "recording"
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.45; duration: 480; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.45; to: 1.0; duration: 480; easing.type: Easing.InOutQuad }
          }
        }

        // 3. Transcribing: Rotating Accent Spinner
        Text {
          anchors.centerIn: parent
          visible: hud.status === "transcribing"
          text: "󰔟"
          color: hud.accent
          font.family: hud.fontFamily
          font.pixelSize: Style.space(16)

          RotationAnimation on rotation {
            running: hud.status === "transcribing"
            from: 0
            to: 360
            duration: 1100
            loops: Animation.Infinite
          }
        }

        // 4. Success: Mint Green Checkmark
        Text {
          anchors.centerIn: parent
          visible: hud.status === "success"
          text: "󰄬"
          color: hud.mintGreen
          font.family: hud.fontFamily
          font.pixelSize: Style.space(16)
        }

        // 5. Error: Red Cross/Exclamation
        Text {
          anchors.centerIn: parent
          visible: hud.status === "error"
          text: "󰅚"
          color: hud.urgent
          font.family: hud.fontFamily
          font.pixelSize: Style.space(16)
        }
      }

      // Middle Content: Waveform during recording, text label for other states
      Item {
        Layout.preferredHeight: Style.space(28)
        Layout.preferredWidth: {
          if (hud.status === "recording") return meter.implicitWidth
          return labelText.implicitWidth
        }

        Behavior on Layout.preferredWidth {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }

        // Live Audio Waveform (shown strictly during active recording)
        LevelMeter {
          id: meter
          visible: hud.status === "recording"
          anchors.centerIn: parent
          levels: hud.controller.barLevels
          barWidth: 4
          barGap: 3
          maxHeight: Style.space(26)
          minHeight: 4
          color: hud.fg
          hotColor: hud.urgent
        }

        // Text Label (arming, transcribing, success, error)
        Text {
          id: labelText
          visible: hud.status !== "recording"
          anchors.centerIn: parent
          text: {
            if (hud.status === "arming") return "正在唤醒麦克风…"
            if (hud.status === "transcribing") {
              return hud.controller.retryAttempt > 0
                ? "重试识别 " + hud.controller.retryAttempt + "/3…"
                : "正在转写…"
            }
            if (hud.status === "success") return hud.controller.hudMessage || "已直接上屏"
            if (hud.status === "error") return hud.controller.hudMessage || "识别失败"
            return ""
          }
          color: {
            if (hud.status === "arming") return hud.amber
            if (hud.status === "error") return hud.urgent
            if (hud.status === "transcribing") return hud.accent
            if (hud.status === "success") return hud.mintGreen
            return hud.fg
          }
          font.family: hud.fontFamily
          font.pixelSize: Style.font.body
          font.bold: hud.status === "success"
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }

      // Right Content: Elapsed Timer (shown during recording, frozen total duration during transcribing/success)
      Text {
        visible: hud.status === "recording" || hud.status === "transcribing" || hud.status === "success"
        text: {
          var s = hud.controller.elapsedSec
          return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
        }
        color: {
          if (hud.status === "recording") return hud.urgent
          if (hud.status === "success") return hud.mintGreen
          if (hud.status === "transcribing") return hud.accent
          return hud.dim
        }
        font.family: hud.fontFamily
        font.pixelSize: Math.max(10, Style.font.body * 0.8)
        font.bold: true
      }
    }
  }
}
