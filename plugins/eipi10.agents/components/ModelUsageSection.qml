import QtQuick
import qs.Commons
import qs.Ui
import "../js/Pricing.js" as Pricing
import "../js/Format.js" as Format
import "../js/ModelIcons.js" as ModelIcons

Column {
  id: root
  property var provider: null
  property var customRates: ({})
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function bucketTotal(bucket) {
    var b = bucket || {}
    return Number(b.inputTokens || b.input || 0) + Number(b.outputTokens || b.output || 0)
      + Number(b.cacheReadInputTokens || b.cacheRead || 0) + Number(b.cacheCreationInputTokens || b.cacheWrite || 0)
  }

  readonly property var tableData: {
    var p = root.provider
    var today = p ? (p.todayModelUsage || {}) : {}
    var owners = (p && p.todayModelOwners) || {}
    var anyToday = false
    for (var id in today) {
      if (bucketTotal(today[id]) > 0) { anyToday = true; break }
    }
    var source = anyToday ? today : (p ? (p.modelUsage || {}) : {})
    var rows = []
    var totalCostSum = 0
    var totalTokensSum = 0

    var normalizedBuckets = {}
    var normalizedOwners = {}
    for (var rawId in source) {
      var bucket = source[rawId] || {}
      var tot = bucketTotal(bucket)
      if (tot <= 0) continue
      var normId = Format.normalizeModelId(rawId)
      if (!normalizedBuckets[normId]) {
        normalizedBuckets[normId] = {
          inputTokens: 0,
          outputTokens: 0,
          cacheReadInputTokens: 0,
          cacheCreationInputTokens: 0
        }
      }
      normalizedBuckets[normId].inputTokens += Number(bucket.inputTokens || bucket.input || 0)
      normalizedBuckets[normId].outputTokens += Number(bucket.outputTokens || bucket.output || 0)
      normalizedBuckets[normId].cacheReadInputTokens += Number(bucket.cacheReadInputTokens || bucket.cacheRead || 0)
      normalizedBuckets[normId].cacheCreationInputTokens += Number(bucket.cacheCreationInputTokens || bucket.cacheWrite || 0)
      if (owners[rawId] && normalizedOwners[normId] !== undefined) {
        if (normalizedOwners[normId].indexOf(owners[rawId]) < 0) normalizedOwners[normId] += " / " + owners[rawId]
      } else if (owners[rawId]) {
        normalizedOwners[normId] = owners[rawId]
      }
    }

    var rawRows = []
    for (var modelId in normalizedBuckets) {
      var nBucket = normalizedBuckets[modelId]
      var nTot = bucketTotal(nBucket)
      if (nTot <= 0) continue
      var costBreakdown = Pricing.calculateModelCost(modelId, nBucket, root.customRates)
      totalCostSum += costBreakdown.total
      totalTokensSum += nTot
      rawRows.push({
        id: modelId,
        name: ModelIcons.getModelLabel(modelId),
        owner: normalizedOwners[modelId] || "",
        total: nTot,
        input: Number(nBucket.inputTokens),
        output: Number(nBucket.outputTokens),
        cacheRead: Number(nBucket.cacheReadInputTokens),
        cacheWrite: Number(nBucket.cacheCreationInputTokens),
        cost: costBreakdown.total,
        costBreakdown: costBreakdown
      })
    }

    // One flat ranking, heaviest token consumer first.
    rawRows.sort(function(a, b) { return b.total - a.total })

    for (var i = 0; i < rawRows.length; i++) {
      var r = rawRows[i]
      r.color = ModelIcons.getModelColor(r.id, Color, i)
      r.sharePct = totalTokensSum > 0 ? ((r.total / totalTokensSum) * 100).toFixed(1) + "%" : "0%"
      rows.push(r)
    }

    return {
      rows: rows,
      scope: anyToday ? "TODAY" : "ALL-TIME",
      totalCost: totalCostSum,
      totalTokens: totalTokensSum
    }
  }

  function modelTooltip(row) {
    if (!row) return ""
    var cb = row.costBreakdown || {}
    var rate = cb.rate || {}
    var inputTotal = Number(row.input || 0) + Number(row.cacheRead || 0) + Number(row.cacheWrite || 0)
    var hitRateStr = inputTotal > 0 ? ((Number(row.cacheRead || 0) / inputTotal) * 100).toFixed(1) + "%" : "0.0%"

    var text = row.name + " (" + row.id + ")" + (row.owner !== "" ? " · " + row.owner : "") + "\n"
      + "• In: " + Format.formatTokenCount(row.input) + " (" + Pricing.formatMoney(cb.inputCost) + " @ $" + (rate.input || 0) + "/M)\n"
      + "• Out: " + Format.formatTokenCount(row.output) + " (" + Pricing.formatMoney(cb.outputCost) + " @ $" + (rate.output || 0) + "/M)\n"
      + "• Cache Read: " + Format.formatTokenCount(row.cacheRead) + " (" + Pricing.formatMoney(cb.cacheReadCost) + " @ $" + (rate.cacheRead || 0) + "/M)"
    if (row.cacheWrite > 0) {
      text += "\n• Cache Write: " + Format.formatTokenCount(row.cacheWrite) + " (" + Pricing.formatMoney(cb.cacheWriteCost) + " @ $" + (rate.cacheWrite || 0) + "/M)"
    }
    text += "\n• KV Cache Hit Rate: " + hitRateStr
    text += "\n────────────────────────\nTotal: " + Format.formatTokenCount(row.total) + " tokens (" + row.sharePct + ") → " + Pricing.formatMoney(row.cost)
    return text
  }

  visible: root.tableData.rows.length > 0
  width: parent ? parent.width : 0
  spacing: Style.space(6)

  PanelSectionHeader {
    width: parent.width
    text: "TOKENS & COST BY MODEL · " + root.tableData.scope
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Repeater {
    model: root.tableData.rows

    Item {
      id: modelRow
      required property var modelData
      required property int index

      readonly property real share: root.tableData.rows.length > 0
        ? modelData.total / Math.max(1, root.tableData.rows[0].total) : 0

      width: root.width
      implicitHeight: Style.space(24)

      // Base background
      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: root.alpha(root.foreground, 0.04)
      }

      // Proportional highlight fill
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * modelRow.share
        radius: Style.cornerRadius
        color: root.alpha(modelRow.modelData.color, 0.12)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }

      Item {
        id: modelContent
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)

        // Left Section: Rank + Color Bar + Name + Owning agent
        Row {
          id: leftPart
          anchors.left: parent.left
          anchors.right: rightPart.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            id: rankText
            text: (modelRow.index + 1) + "."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Rectangle {
            id: colorBar
            width: Style.space(4)
            height: Style.space(10)
            radius: Style.space(2)
            color: modelRow.modelData.color
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: modelName
            text: modelRow.modelData ? modelRow.modelData.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: ownerName
            visible: modelRow.modelData && modelRow.modelData.owner !== ""
            text: modelRow.modelData && modelRow.modelData.owner !== "" ? "· " + modelRow.modelData.owner : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Right Section: Share Pct + Tokens & Cost
        Row {
          id: rightPart
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Text {
            id: shareText
            text: modelRow.modelData ? modelRow.modelData.sharePct : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: modelTokens
            text: {
              if (!modelRow.modelData) return ""
              var countStr = Format.formatTokenCount(modelRow.modelData.total)
              var costStr = Pricing.formatMoney(modelRow.modelData.cost)
              return countStr + " (" + costStr + ")"
            }
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      MouseArea {
        id: modelHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      PanelToolTip {
        visible: modelHover.containsMouse
        text: root.modelTooltip(modelRow.modelData)
        fontFamily: root.fontFamily
      }
    }
  }
}
