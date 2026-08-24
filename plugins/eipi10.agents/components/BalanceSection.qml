import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: root
  property var balance: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property bool balanceAlarming: !!root.balance && root.balance.funded > 0
    && root.balance.remaining / root.balance.funded <= 0.1

  readonly property real ratio: root.balance && root.balance.funded > 0
    ? Math.max(0, Math.min(1, root.balance.remaining / root.balance.funded))
    : -1

  function formatMoney(value, currency) {
    var code = String(currency || "USD").toUpperCase()
    var prefix = code === "USD" ? "$" : (code === "EUR" ? "€" : (code === "GBP" ? "£" : code + " "))
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return prefix + amount.toFixed(2)
  }

  function balanceDetailText() {
    if (!root.balance || !(root.balance.funded > 0)) return ""
    var text = formatMoney(root.balance.spent, root.balance.currency) + " spent of "
      + formatMoney(root.balance.funded, root.balance.currency) + " funded"
    if (root.balance.estimated) text += " · estimated"
    return text
  }

  visible: !!root.balance
  width: parent ? parent.width : 0
  spacing: Style.space(10)

  PanelSectionHeader {
    width: parent.width
    text: "BALANCE"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

    Text {
      id: balanceLabel
      text: "Prepaid credits"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: balanceValue
      text: root.balance ? formatMoney(root.balance.remaining, root.balance.currency) : ""
      color: root.balanceAlarming ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  UsageMeter {
    visible: root.ratio >= 0
    width: parent.width
    value: root.ratio
    alarming: root.balanceAlarming
    foreground: root.foreground
    urgent: root.urgent
  }

  Text {
    visible: text !== ""
    width: parent.width
    text: balanceDetailText()
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
