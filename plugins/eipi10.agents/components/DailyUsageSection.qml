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
  property double nowMs: Date.now()
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property color trackColor: Style.selectedFillFor(foreground, Color.accent)
  property string fontFamily: Style.font.family

  readonly property var days: root.provider ? (root.provider.recentDays || []) : []
  readonly property real peak: {
    var p = 0
    for (var i = 0; i < days.length; i++) p = Math.max(p, Number(days[i].messageCount || 0))
    return Math.max(1, p)
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function daySlices(day) {
    if (!day || !day.models) return []
    var totalTokens = Number(day.messageCount || 0)
    if (totalTokens <= 0) return []

    var normalizedModels = {}
    for (var m in day.models) {
      var entry = day.models[m] || {}
      var bucketTokens = Pricing.bucketTokenTotal(entry)
      var tokens = bucketTokens > 0 ? bucketTokens : Number(entry.tokens || 0)
      if (tokens <= 0) continue
      var breakdown = bucketTokens > 0 ? Pricing.calculateModelCost(m, entry, root.customRates) : null
      var cost = breakdown ? breakdown.total : Number(entry.cost || 0)
      var unrated = breakdown
        ? (breakdown.rated ? Number(entry.unclassifiedTokens || 0) : tokens)
        : 0
      var normId = Format.normalizeModelId(m)
      if (!normalizedModels[normId]) {
        normalizedModels[normId] = { tokens: 0, cost: 0.0, unratedTokens: 0 }
      }
      normalizedModels[normId].tokens += tokens
      normalizedModels[normId].cost += cost
      normalizedModels[normId].unratedTokens += unrated
    }

    var list = []
    for (var nm in normalizedModels) {
      var nEntry = normalizedModels[nm]
      if (nEntry.tokens > 0) {
        list.push({
          id: nm,
          name: ModelIcons.getModelLabel(nm),
          tokens: nEntry.tokens,
          fraction: nEntry.tokens / totalTokens,
          cost: Number(nEntry.cost || 0),
          unratedTokens: Number(nEntry.unratedTokens || 0),
          color: ModelIcons.getModelColor(nm, Color)
        })
      }
    }
    list.sort(function(a, b) { return b.tokens - a.tokens })
    return list
  }

  function dayCost(day) {
    var slices = daySlices(day)
    var total = 0
    for (var i = 0; i < slices.length; i++) total += Number(slices[i].cost || 0)
    return slices.length > 0 ? total : Number(day ? day.totalCost || 0 : 0)
  }

  function dayTooltip(day, isToday) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : Format.dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var count = Number(day.messageCount || 0)
    var cost = dayCost(day)

    var text = label + " · " + Format.formatTokenCount(count) + " tokens"
    if (cost > 0) text += " (" + Pricing.formatMoney(cost) + ")"

    var slices = daySlices(day)
    if (slices.length > 0) {
      text += "\n────────────────────────"
      for (var i = 0; i < slices.length; i++) {
        var s = slices[i]
        var pct = (s.fraction * 100).toFixed(1)
        text += "\n" + (i + 1) + ". " + s.name + ": "
          + Format.formatTokenCount(s.tokens) + " (" + pct + "%)"
        if (s.cost > 0) text += " → " + Pricing.formatMoney(s.cost)
        if (s.unratedTokens > 0) text += " · " + Format.formatTokenCount(s.unratedTokens) + " unrated"
      }
    }

    if (isToday && root.provider) {
      if (root.provider.hasPromptStats !== false) {
        text += "\n────────────────────────\nActivity: " + Number(root.provider.todayPrompts || 0) + " prompts · "
          + Number(root.provider.todaySessions || 0) + " sessions"
      }
    }
    return text
  }

  visible: !!root.provider && root.days.length > 0
  width: parent ? parent.width : 0
  spacing: Style.space(8)

  PanelSectionHeader {
    width: parent.width
    text: "TOKENS BY DAY · ALL AGENTS"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Repeater {
    model: root.days

    Item {
      id: dayRow
      required property var modelData
      required property int index

      readonly property bool isToday: String(modelData.date || "") === root.todayDate()
      readonly property real ratio: Number(modelData.messageCount || 0) / root.peak
      readonly property var slices: root.daySlices(dayRow.modelData)

      width: root.width
      implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

      // Date Label
      Text {
        id: dayLabel
        text: Format.dayLabel(dayRow.modelData ? dayRow.modelData.date : "", dayRow.isToday)
        color: dayRow.isToday ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: dayRow.isToday
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(46)
      }

      // Multi-Series Stacked Bar Chart
      Item {
        id: trackArea
        anchors.left: dayLabel.right
        anchors.right: dayValue.left
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(6)

        // Background track
        Rectangle {
          anchors.fill: parent
          radius: height / 2
          color: root.alpha(root.foreground, 0.10)
        }

        // Active Segmented Fill
        Item {
          id: barFillContainer
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Math.max(0, parent.width * root.clamp(dayRow.ratio, 0, 1))
          clip: true

          Behavior on width {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
          }

          Rectangle {
            anchors.fill: parent
            radius: parent.height / 2
            color: "transparent"
            clip: true

            Row {
              anchors.fill: parent
              spacing: 0

              Repeater {
                model: dayRow.slices

                Rectangle {
                  required property var modelData
                  width: Math.max(1, barFillContainer.width * modelData.fraction)
                  height: parent.height
                  color: modelData.color
                }
              }

              Rectangle {
                visible: dayRow.slices.length === 0 && dayRow.ratio > 0
                width: parent.width
                height: parent.height
                color: dayRow.isToday ? Color.accent : root.alpha(root.foreground, 0.45)
              }
            }
          }
        }
      }

      // Day Tokens & Cost
      Text {
        id: dayValue
        text: {
          var count = Format.formatTokenCount(dayRow.modelData ? Number(dayRow.modelData.messageCount || 0) : 0)
          var cost = root.dayCost(dayRow.modelData)
          return cost > 0 ? count + " (" + Pricing.formatMoney(cost) + ")" : count
        }
        color: dayRow.isToday ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: dayRow.isToday
        horizontalAlignment: Text.AlignRight
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(96)
      }

      MouseArea {
        id: dayHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      PanelToolTip {
        visible: dayHover.containsMouse
        text: root.dayTooltip(dayRow.modelData, dayRow.isToday)
        fontFamily: root.fontFamily
      }
    }
  }
}
