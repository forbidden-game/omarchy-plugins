import QtQuick
import qs.Commons
import qs.Ui

// A compact labeled segmented choice. It is one keyboard cursor stop; h/l
// changes the option while direct pointer clicks still target each choice.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property var options: []
  property var value: null
  property bool hasCursor: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal selected(var value)
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

    Column {
      width: parent.width
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
        wrapMode: Text.WordWrap
      }
    }

    Row {
      id: choices
      width: parent.width
      spacing: Style.spacing.controlGap

      Repeater {
        model: root.options

        Button {
          required property var modelData
          width: (choices.width - choices.spacing * Math.max(0, root.options.length - 1))
                 / Math.max(1, root.options.length)
          text: String(modelData.label)
          selected: root.value === modelData.value
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.selected(modelData.value)
        }
      }
    }
  }
}
