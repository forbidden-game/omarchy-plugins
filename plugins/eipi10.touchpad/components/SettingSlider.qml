import QtQuick
import qs.Commons
import qs.Ui

// A settings row with one semantic value, one slider, and one focus surface.
// The parent owns the value so preview, save, and rollback remain model-driven.
BorderSurface {
  id: root

  property QtObject bar: null
  property string label: ""
  property string description: ""
  property string valueText: ""
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool hasCursor: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal moved(real value)
  signal released(real value)
  signal hovered(bool active)

  implicitWidth: Style.space(320)
  implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX * 2
  radius: Style.cornerRadius
  color: Style.controlFill(false, hasCursor || hover.hovered, foreground, accent)
  borderSpec: Border.controlSpec(
    hasCursor || hover.hovered ? "hover-cursor" : "normal",
    foreground,
    accent
  )

  Behavior on color { ColorAnimation { duration: 100 } }

  HoverHandler {
    id: hover
    onHoveredChanged: root.hovered(hovered)
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.borderLeft + Style.spacing.rowPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.rowPaddingX
    spacing: Style.space(8)

    Row {
      width: parent.width

      Column {
        width: parent.width - valueLabel.width - Style.space(12)
        spacing: Style.spacing.xs

        Text {
          width: parent.width
          text: root.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          visible: root.description !== ""
          width: parent.width
          text: root.description
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: valueLabel
        anchors.verticalCenter: parent.verticalCenter
        text: root.valueText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }

    PanelSlider {
      width: parent.width
      bar: root.bar
      value: root.value
      minimum: root.minimum
      maximum: root.maximum
      step: root.step
      onMoved: function(next) { root.moved(next) }
      onReleased: function(next) { root.released(next) }
    }
  }
}
