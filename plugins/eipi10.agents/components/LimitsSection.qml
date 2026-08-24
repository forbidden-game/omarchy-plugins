import QtQuick
import qs.Commons
import qs.Ui
import "../js/Format.js" as Format

Column {
  id: root
  property var limits: []
  property double nowMs: Date.now()
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  visible: root.limits && root.limits.length > 0
  width: parent ? parent.width : 0
  spacing: Style.space(8)

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  PanelSectionHeader {
    text: "QUOTAS & REMAINING"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Repeater {
    model: root.limits

    Column {
      id: limitRow
      required property var modelData
      width: root.width
      spacing: Style.space(4)

      readonly property real remaining: modelData && modelData.remaining !== undefined
        ? Number(modelData.remaining)
        : (modelData && modelData.percent !== undefined ? Number(modelData.percent) : 1.0)

      readonly property bool alarming: remaining <= 0.15

      Item {
        width: parent.width
        implicitHeight: Math.max(limitLabel.implicitHeight, rightCapsule.implicitHeight)

        Text {
          id: limitLabel
          text: modelData ? (modelData.title || "") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: rightCapsule.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: rightCapsule
          spacing: Style.space(6)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: resetText
            text: {
              if (!modelData || !modelData.resetsAt) return ""
              var resetTime = new Date(modelData.resetsAt).getTime()
              if (!isFinite(resetTime)) return ""
              var remainingMs = resetTime - root.nowMs
              return remainingMs > 0 ? "Resets in " + Format.formatDuration(remainingMs) : ""
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            spacing: Style.space(3)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              id: limitValue
              text: Math.round(limitRow.remaining * 100) + "%"
              color: limitRow.alarming ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: weeklyValue
              visible: modelData && modelData.weeklyPercent !== undefined && modelData.weeklyPercent !== null
              text: {
                if (!modelData || modelData.weeklyPercent === undefined || modelData.weeklyPercent === null) return ""
                var wp = Math.round(Number(modelData.weeklyPercent) * 100)
                return "(周 " + wp + "%)"
              }
              color: {
                if (!modelData || modelData.weeklyPercent === undefined || modelData.weeklyPercent === null) return root.dim
                var wp = Number(modelData.weeklyPercent)
                if (wp <= 0.15) return root.urgent
                return root.dim
              }
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: false
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      UsageMeter {
        width: parent.width
        value: limitRow.remaining
        alarming: limitRow.alarming
        foreground: limitRow.alarming ? root.urgent : root.accent
        urgent: root.urgent
      }
    }
  }
}
