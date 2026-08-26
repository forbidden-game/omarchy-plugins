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

  // Turn one provider's model-usage map into display rows, merged by
  // normalized model id, rated at API list prices, heaviest first.
  function buildRows(source, colorOffset) {
    var normalizedBuckets = {}
    for (var rawId in source) {
      var bucket = source[rawId] || {}
      if (bucketTotal(bucket) <= 0) continue
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
    }

    var totalTokensSum = 0
    var rawRows = []
    for (var modelId in normalizedBuckets) {
      var nBucket = normalizedBuckets[modelId]
      var nTot = bucketTotal(nBucket)
      if (nTot <= 0) continue
      var costBreakdown = Pricing.calculateModelCost(modelId, nBucket, root.customRates)
      totalTokensSum += nTot
      rawRows.push({
        id: modelId,
        name: ModelIcons.getModelLabel(modelId),
        total: nTot,
        input: Number(nBucket.inputTokens),
        output: Number(nBucket.outputTokens),
        cacheRead: Number(nBucket.cacheReadInputTokens),
        cacheWrite: Number(nBucket.cacheCreationInputTokens),
        cost: costBreakdown.total,
        costBreakdown: costBreakdown
      })
    }

    rawRows.sort(function(a, b) { return b.total - a.total })

    var rows = []
    for (var i = 0; i < rawRows.length; i++) {
      var r = rawRows[i]
      r.color = ModelIcons.getModelColor(r.id, Color, colorOffset + i)
      r.sharePct = totalTokensSum > 0 ? ((r.total / totalTokensSum) * 100).toFixed(1) + "%" : "0%"
      rows.push(r)
    }
    return rows
  }

  // One group per enabled agent — today's numbers when the agent has any,
  // all-time otherwise — each with a rated subtotal, heaviest agent first.
  readonly property var tableData: {
    var p = root.provider
    if (!p) return { groups: [], scope: "TODAY" }
    var agents = (Array.isArray(p.agents) && p.agents.length > 0)
      ? p.agents
      : [{ providerId: p.providerId, providerName: p.providerName, todayModelUsage: p.todayModelUsage || {}, modelUsage: p.modelUsage || {} }]

    var groups = []
    var colorIndex = 0
    var anyToday = false
    for (var i = 0; i < agents.length; i++) {
      var agent = agents[i]
      var today = agent.todayModelUsage || {}
      var hasToday = false
      for (var id in today) {
        if (bucketTotal(today[id]) > 0) { hasToday = true; break }
      }
      if (hasToday) anyToday = true
      var rows = buildRows(hasToday ? today : (agent.modelUsage || {}), colorIndex)
      colorIndex += rows.length
      if (rows.length === 0) continue
      var subtotalTokens = 0
      var subtotalCost = 0
      for (var r2 = 0; r2 < rows.length; r2++) {
        subtotalTokens += rows[r2].total
        subtotalCost += rows[r2].cost
      }
      groups.push({
        providerId: agent.providerId,
        name: agent.providerName,
        rows: rows,
        subtotalTokens: subtotalTokens,
        subtotalCost: subtotalCost
      })
    }

    groups.sort(function(a, b) { return b.subtotalTokens - a.subtotalTokens })
    return { groups: groups, scope: anyToday ? "TODAY" : "ALL-TIME" }
  }

  function modelTooltip(row) {
    if (!row) return ""
    var cb = row.costBreakdown || {}
    var rate = cb.rate || {}
    var inputTotal = Number(row.input || 0) + Number(row.cacheRead || 0) + Number(row.cacheWrite || 0)
    var hitRateStr = inputTotal > 0 ? ((Number(row.cacheRead || 0) / inputTotal) * 100).toFixed(1) + "%" : "0.0%"

    var text = row.name + " (" + row.id + ")\n"
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

  visible: root.tableData.groups.length > 0
  width: parent ? parent.width : 0
  spacing: Style.space(6)

  PanelSectionHeader {
    width: parent.width
    text: "SPEND BY AGENT · " + root.tableData.scope
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Repeater {
    model: root.tableData.groups

    delegate: Column {
      id: groupBlock
      required property var modelData
      width: root.width
      spacing: Style.space(2)

      // Agent subtotal: the bold line that answers "how much did this one cost"
      Item {
        width: parent.width
        implicitHeight: Style.space(24)

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: root.alpha(root.foreground, 0.07)
        }

        Row {
          id: subtotalLeft
          anchors.left: parent.left
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Rectangle {
            width: Style.space(4)
            height: Style.space(10)
            radius: Style.space(2)
            color: root.foreground
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: groupBlock.modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: Format.formatTokenCount(groupBlock.modelData.subtotalTokens) + " (" + Pricing.formatMoney(groupBlock.modelData.subtotalCost) + ")"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Repeater {
        model: groupBlock.modelData.rows

        delegate: ModelRow {
          rowData: modelData
          groupMax: groupBlock.modelData.rows.length > 0 ? groupBlock.modelData.rows[0].total : 1
        }
      }

      Item { width: parent.width; implicitHeight: Style.space(6) }
    }
  }

  component ModelRow: Item {
    id: modelRow
    property var rowData: null
    property real groupMax: 1

    readonly property real share: rowData ? root.clamp(rowData.total / Math.max(1, modelRow.groupMax), 0, 1) : 0

    width: root.width
    implicitHeight: Style.space(24)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.04)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: (parent.width - Style.space(10)) * modelRow.share
      radius: Style.cornerRadius
      color: root.alpha(modelRow.rowData ? modelRow.rowData.color : root.foreground, 0.12)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Item {
      anchors.fill: parent
      anchors.leftMargin: Style.space(16)
      anchors.rightMargin: Style.space(16)

      Row {
        id: leftPart
        anchors.left: parent.left
        anchors.right: rightPart.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Rectangle {
          width: Style.space(4)
          height: Style.space(10)
          radius: Style.space(2)
          color: modelRow.rowData ? modelRow.rowData.color : root.foreground
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: modelRow.rowData ? modelRow.rowData.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        id: rightPart
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Text {
          text: modelRow.rowData ? modelRow.rowData.sharePct : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: {
            if (!modelRow.rowData) return ""
            return Format.formatTokenCount(modelRow.rowData.total) + " (" + Pricing.formatMoney(modelRow.rowData.cost) + ")"
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
      text: root.modelTooltip(modelRow.rowData)
      fontFamily: root.fontFamily
    }
  }
}
