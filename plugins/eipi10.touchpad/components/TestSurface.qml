import QtQuick
import qs.Commons
import qs.Ui

// A real input surface, not a decorative demo: it receives the post-libinput
// clicks and wheel events produced by the settings currently being previewed.
BorderSurface {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property string feedback: "Waiting for input"
  property int scrollSteps: 0

  implicitWidth: Style.space(320)
  implicitHeight: Style.space(92)
  radius: Style.cornerRadius
  color: Style.normalFillFor(foreground, accent)
  borderSpec: Border.controlSpec(
    input.containsMouse ? "hover-cursor" : "normal",
    foreground,
    accent
  )

  Column {
    anchors.centerIn: parent
    width: parent.width - Style.space(28)
    spacing: Style.space(5)

    Text {
      width: parent.width
      text: "TRY IT HERE"
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.0
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      width: parent.width
      text: root.feedback
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      text: "Tap, press, or two-finger scroll; the preview is already live."
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }
  }

  MouseArea {
    id: input
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.AllButtons
    cursorShape: Qt.PointingHandCursor

    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton) root.feedback = "Right click received"
      else if (mouse.button === Qt.MiddleButton) root.feedback = "Middle click received"
      else root.feedback = "Left click received"
    }

    onWheel: function(wheel) {
      root.scrollSteps += wheel.angleDelta.y > 0 ? 1 : -1
      var direction = wheel.angleDelta.y > 0 ? "up" : "down"
      root.feedback = "Scrolled " + direction + " · " + Math.abs(root.scrollSteps) + " steps"
    }
  }
}
