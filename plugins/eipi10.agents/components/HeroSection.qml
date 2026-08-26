import QtQuick
import qs.Commons
import qs.Ui
import "../js/Pricing.js" as Pricing
import "../js/Format.js" as Format

Item {
  id: root
  property var provider: null
  property var customRates: ({})
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property string currentAccountEmail: root.provider ? String(root.provider.currentAccountEmail || "") : ""
  readonly property string tierLabel: root.provider ? String(root.provider.tierLabel || "") : ""

  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier
  }

  readonly property var activeSource: root.provider
  readonly property var todayUsage: activeSource ? (activeSource.todayModelUsage || {}) : {}
  readonly property real todayCost: {
    if (activeSource && activeSource.todayTotalCost > 0) return Number(activeSource.todayTotalCost)
    return Pricing.calculateTotalCost(root.todayUsage, root.customRates)
  }
  readonly property real todayTokens: activeSource ? Number(activeSource.todayTotalTokens || 0) : 0

  width: parent ? parent.width : 0
  implicitHeight: Math.max(leftBlock.implicitHeight, rightBlock.implicitHeight)

  Column {
    id: leftBlock
    anchors.left: parent.left
    anchors.right: rightBlock.left
    anchors.rightMargin: Style.spacing.md
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      id: titleText
      width: parent.width
      text: root.provider ? String(root.provider.providerName || "") : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      id: metaText
      width: parent.width
      text: {
        var meta = root.heroMeta(root.provider)
        if (root.currentAccountEmail !== "") {
          return meta !== "" ? meta + " · " + root.currentAccountEmail : root.currentAccountEmail
        }
        return meta
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Column {
    id: rightBlock
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)
    visible: root.todayTokens > 0 || root.todayCost > 0

    Text {
      id: costText
      visible: root.todayCost > 0
      text: Pricing.formatMoney(root.todayCost)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
    }

    Text {
      id: tokensText
      text: "Today · " + Format.formatTokenCount(root.todayTokens)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
    }
  }
}
