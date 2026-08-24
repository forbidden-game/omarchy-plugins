import QtQuick
import qs.Commons
import qs.Ui

BorderSurface {
  id: root
  property string statusText: ""
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  visible: root.statusText !== ""
  width: parent ? parent.width : 0
  implicitHeight: label.implicitHeight + Style.spacing.xl * 2
  color: root.alpha(root.urgent, 0.10)
  borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
  radius: Style.cornerRadius

  Text {
    id: label
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    text: root.statusText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
