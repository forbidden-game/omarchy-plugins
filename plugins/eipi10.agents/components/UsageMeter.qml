import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root
  property real value: -1
  property bool alarming: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color trackColor: Style.selectedFillFor(foreground, Color.accent)
  property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

  implicitHeight: thickness

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  Rectangle {
    id: meterTrack
    anchors.fill: parent
    radius: height / 2
    color: root.trackColor
  }

  Rectangle {
    anchors.left: meterTrack.left
    anchors.verticalCenter: meterTrack.verticalCenter
    height: meterTrack.height
    radius: meterTrack.radius
    width: meterTrack.width * root.clamp(root.value, 0, 1)
    color: root.alarming ? root.urgent : root.foreground

    Behavior on width {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }
  }
}
