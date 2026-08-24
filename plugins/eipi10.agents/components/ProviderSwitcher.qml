import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Row {
  id: root
  property var providers: []
  property int selectedIndex: 0
  property bool cursorActive: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal selectRequested(int index)

  visible: root.providers && root.providers.length > 1
  width: parent ? parent.width : 0
  spacing: Style.spacing.md

  readonly property real cellWidth: root.providers && root.providers.length > 0
    ? (width - spacing * (root.providers.length - 1)) / root.providers.length
    : 0

  Repeater {
    model: root.providers

    Button {
      required property var modelData
      required property int index

      width: root.cellWidth
      text: modelData.providerName || modelData.providerId || ""
      selected: index === root.selectedIndex
      hasCursor: root.cursorActive && index === root.selectedIndex
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      verticalPadding: Style.spacing.controlPaddingY
      onClicked: root.selectRequested(index)
      onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
    }
  }
}
