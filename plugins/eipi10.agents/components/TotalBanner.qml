import QtQuick
import qs.Commons
import qs.Ui
import "../js/Pricing.js" as Pricing
import "../js/Format.js" as Format

// Grand total across every enabled agent, pinned to the top of the panel:
// today's rated spend plus the token and prompt counts behind it. Cost is
// computed with the same API list-price engine as the per-model rows, so the
// banner always equals the sum of the group subtotals below it.
Column {
  id: root

  property var aggregate: null
  property var customRates: ({})
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property real totalCost: root.aggregate
    ? Pricing.calculateTotalCost(root.aggregate.todayModelUsage || {}, root.customRates)
    : 0
  readonly property real totalTokens: root.aggregate ? Number(root.aggregate.todayTotalTokens || 0) : 0
  readonly property real unratedTokens: root.aggregate ? Number(root.aggregate.todayUnratedTokens || 0) : 0
  readonly property int totalPrompts: root.aggregate ? Number(root.aggregate.todayPrompts || 0) : 0
  readonly property int agentCount: root.aggregate ? Number(root.aggregate.agentCount || 0) : 0

  visible: root.aggregate !== null && (root.totalTokens > 0 || root.totalCost > 0)
  width: parent ? parent.width : 0
  spacing: Style.space(2)

  Row {
    width: parent.width

    Text {
      width: parent.width - totalCostText.implicitWidth
      text: "ALL AGENTS · TODAY"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: totalCostText
      text: Pricing.formatMoney(root.totalCost)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Text {
    width: parent.width
    text: {
      var value = root.agentCount + " agents · " + Format.formatTokenCount(root.totalTokens)
        + " tokens · " + root.totalPrompts + " prompts"
      if (root.unratedTokens > 0) value += " · " + Format.formatTokenCount(root.unratedTokens) + " unrated"
      return value
    }
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
