import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Rectangle {
  id: root
  property string authUrl: ""
  property string status: "idle" // "idle", "listening", "success", "error"
  property string statusMessage: ""
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  signal copyLinkRequested()
  signal cancelRequested()

  width: parent ? parent.width : 0
  implicitHeight: contentCol.implicitHeight + Style.space(16)
  radius: Style.cornerRadius
  color: root.alpha(Color.accent, 0.08)
  border.color: root.status === "error"
    ? root.urgent
    : (root.status === "success" ? Color.accent : root.alpha(Color.accent, 0.35))
  border.width: 1

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  Column {
    id: contentCol
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(8)
    spacing: Style.space(8)

    // Title Row
    Text {
      text: root.status === "success"
        ? "Authorization Successful"
        : (root.status === "error" ? "Authorization Failed" : "Google OAuth Link Ready")
      color: root.status === "error"
        ? root.urgent
        : (root.status === "success" ? Color.accent : root.foreground)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    // Explanatory Text
    Text {
      width: parent.width
      text: root.status === "success"
        ? "Account added and activated. Quotas synced."
        : (root.status === "error"
            ? (root.statusMessage || "Failed to capture callback. Please check connection.")
            : "Link copied to clipboard. Paste into your browser to complete Google login.")
      color: root.alpha(root.foreground, 0.85)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Action Buttons & Pulse Indicator
    Row {
      width: parent.width
      spacing: Style.space(8)
      visible: root.status !== "success"

      // Copy Link Button
      Rectangle {
        id: copyBtn
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: copyBtnText.implicitWidth + Style.space(16)
        implicitHeight: copyBtnText.implicitHeight + Style.space(8)
        radius: Style.cornerRadius
        color: copyMa.containsMouse ? root.alpha(root.foreground, 0.2) : root.alpha(root.foreground, 0.1)
        border.color: root.alpha(root.foreground, 0.3)
        border.width: 1

        Text {
          id: copyBtnText
          anchors.centerIn: parent
          text: "Copy Link Again"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        MouseArea {
          id: copyMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.copyLinkRequested()
        }
      }

      // Cancel Button
      Rectangle {
        id: cancelBtn
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: cancelBtnText.implicitWidth + Style.space(16)
        implicitHeight: cancelBtnText.implicitHeight + Style.space(8)
        radius: Style.cornerRadius
        color: cancelMa.containsMouse ? root.alpha(root.urgent, 0.2) : root.alpha(root.foreground, 0.06)
        border.color: root.alpha(root.foreground, 0.25)
        border.width: 1

        Text {
          id: cancelBtnText
          anchors.centerIn: parent
          text: "Cancel"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: cancelMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.cancelRequested()
        }
      }

      // Pulse Waiting Animation
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)
        visible: root.status === "listening"

        Rectangle {
          id: pulseDot
          width: Style.space(6)
          height: Style.space(6)
          radius: height / 2
          color: Color.accent
          anchors.verticalCenter: parent.verticalCenter

          SequentialAnimation on opacity {
            running: root.status === "listening"
            loops: Animation.Infinite
            NumberAnimation { to: 0.2; duration: 600; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
          }
        }

        Text {
          text: "Waiting for callback..."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}
