import QtQuick
import qs.Commons
import qs.Ui
import "../js/Format.js" as Format

Column {
  id: root
  property var accounts: []
  property string currentAccountId: ""
  property bool switching: false
  property bool currentAppStatusKnown: false
  property bool currentAppReady: false
  property string verificationUrl: ""
  property string statusMessage: ""
  property bool statusError: false
  property double nowMs: Date.now()
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal switchRequested(string accountId)
  signal addAccountRequested()
  signal verifyRequested(string url)

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function accountTooltip(acc) {
    if (!acc) return ""
    var lines = []
    var email = String(acc.email || "")
    var name = String(acc.name || "")
    var tier = String(acc.tier || "")

    var title = email
    if (name && name !== email) title += " (" + name + ")"
    if (tier) title += " · " + tier
    lines.push(title)
    lines.push("────────────────────────")

    var hasDetails = false

    if (acc.geminiWeeklyPercent !== undefined && acc.geminiWeeklyPercent !== null) {
      hasDetails = true
      var gWp = Math.round(Number(acc.geminiWeeklyPercent) * 100)
      var gLine = "Gemini 周限额: " + gWp + "%"
      if (acc.geminiWeeklyResetAt) {
        var gReset = new Date(acc.geminiWeeklyResetAt).getTime()
        if (isFinite(gReset)) {
          var gRem = gReset - root.nowMs
          if (gRem > 0) gLine += " (" + Format.formatDuration(gRem) + " 后重置)"
        }
      }
      lines.push(gLine)
    }

    if (acc.claudeWeeklyPercent !== undefined && acc.claudeWeeklyPercent !== null) {
      hasDetails = true
      var cWp = Math.round(Number(acc.claudeWeeklyPercent) * 100)
      var cLine = "Claude 周限额: " + cWp + "%"
      if (acc.claudeWeeklyResetAt) {
        var cReset = new Date(acc.claudeWeeklyResetAt).getTime()
        if (isFinite(cReset)) {
          var cRem = cReset - root.nowMs
          if (cRem > 0) cLine += " (" + Format.formatDuration(cRem) + " 后重置)"
        }
      }
      lines.push(cLine)
    }

    if (acc.flashQuota !== undefined && acc.flashQuota !== null) {
      hasDetails = true
      var fLine = "5h 会话限额: " + Math.round(Number(acc.flashQuota)) + "%"
      if (acc.flashResetAt) {
        var fReset = new Date(acc.flashResetAt).getTime()
        if (isFinite(fReset)) {
          var fRem = fReset - root.nowMs
          if (fRem > 0) fLine += " (" + Format.formatDuration(fRem) + " 后重置)"
        }
      }
      lines.push(fLine)
    }

    if (!hasDetails) {
      lines.push("暂无可用配额数据")
    }

    return lines.join("\n")
  }

  visible: root.accounts && root.accounts.length > 0
  width: parent ? parent.width : 0
  spacing: Style.space(8)

  Item {
    width: parent.width
    implicitHeight: Math.max(headerText.implicitHeight, addBtn.implicitHeight)

    PanelSectionHeader {
      id: headerText
      text: "ACCOUNTS"
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: addBtn
      text: "+ Add"
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.addAccountRequested()
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: root.accounts

      Item {
        id: accountRow
        required property var modelData
        width: parent.width
        implicitHeight: Style.space(26)

        readonly property bool isCurrent: modelData && (modelData.isCurrent || modelData.id === root.currentAccountId)

        readonly property bool hasGeminiWeekly: modelData && modelData.geminiWeeklyPercent !== undefined && modelData.geminiWeeklyPercent !== null
        readonly property bool hasClaudeWeekly: modelData && modelData.claudeWeeklyPercent !== undefined && modelData.claudeWeeklyPercent !== null
        readonly property bool hasWeekly: hasGeminiWeekly || hasClaudeWeekly

        readonly property real geminiVal: hasGeminiWeekly ? Number(modelData.geminiWeeklyPercent) : 1.0
        readonly property real claudeVal: hasClaudeWeekly ? Number(modelData.claudeWeeklyPercent) : 1.0

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: accountRow.isCurrent
            ? root.alpha(root.foreground, 0.06)
            : (rowHover.containsMouse ? root.alpha(root.foreground, 0.03) : "transparent")
        }

        // Left section: radio dot + email
        Row {
          id: leftPart
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.right: rightPart.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Rectangle {
            width: Style.space(6)
            height: Style.space(6)
            radius: height / 2
            color: accountRow.isCurrent ? root.accent : root.alpha(root.foreground, 0.3)
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: emailText
            width: Math.min(implicitWidth, leftPart.width - Style.space(14))
            text: accountRow.modelData ? accountRow.modelData.email : ""
            color: accountRow.isCurrent ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: accountRow.isCurrent
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Right section: Weekly Quotas + (LIVE tag or Switch button)
        Row {
          id: rightPart
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          // Weekly Quota Indicators
          Row {
            id: quotaIndicators
            visible: accountRow.hasWeekly
            spacing: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              text: "周"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            // Gemini Weekly Quota
            Row {
              visible: accountRow.hasGeminiWeekly
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                text: accountRow.hasClaudeWeekly ? "G" : ""
                visible: text !== ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: Math.round(accountRow.geminiVal * 100) + "%"
                color: accountRow.geminiVal <= 0.15 ? root.urgent : (accountRow.isCurrent ? root.foreground : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: accountRow.isCurrent || accountRow.geminiVal <= 0.15
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Separator dot if both exist
            Text {
              text: "·"
              visible: accountRow.hasGeminiWeekly && accountRow.hasClaudeWeekly
              color: root.alpha(root.foreground, 0.25)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            // Claude Weekly Quota
            Row {
              visible: accountRow.hasClaudeWeekly
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                text: "C"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: Math.round(accountRow.claudeVal * 100) + "%"
                color: accountRow.claudeVal <= 0.15 ? root.urgent : (accountRow.isCurrent ? root.foreground : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: accountRow.isCurrent || accountRow.claudeVal <= 0.15
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // Action: native App auth state or Switch button
          Item {
            id: actionPart
            width: accountRow.isCurrent ? liveTag.width : switchChip.width
            height: accountRow.isCurrent ? liveTag.height : switchChip.height
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
              id: liveTag
              visible: accountRow.isCurrent
              width: liveLabel.implicitWidth + Style.space(12)
              height: liveLabel.implicitHeight + Style.space(4)
              radius: Style.cornerRadius
              color: root.alpha(
                root.currentAppReady ? root.accent : (
                  root.currentAppStatusKnown ? root.urgent : root.foreground
                ),
                verifyHover.containsMouse ? 0.25 : 0.15
              )
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right

              Text {
                id: liveLabel
                anchors.centerIn: parent
                text: root.currentAppReady
                  ? "LIVE"
                  : (root.currentAppStatusKnown ? "VERIFY" : "CHECK")
                color: root.currentAppReady
                  ? root.accent
                  : (root.currentAppStatusKnown ? root.urgent : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: verifyHover
                anchors.fill: parent
                visible: !root.currentAppReady && root.verificationUrl !== ""
                hoverEnabled: visible
                cursorShape: visible ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.verifyRequested(root.verificationUrl)
              }
            }

            Rectangle {
              id: switchChip
              visible: !accountRow.isCurrent
              width: switchLabel.implicitWidth + Style.space(14)
              height: switchLabel.implicitHeight + Style.space(4)
              radius: Style.cornerRadius
              color: switchHover.containsMouse ? root.alpha(root.foreground, 0.15) : root.alpha(root.foreground, 0.06)
              border.width: 1
              border.color: switchHover.containsMouse ? root.accent : root.alpha(root.foreground, 0.15)
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right

              Text {
                id: switchLabel
                anchors.centerIn: parent
                text: root.switching ? "Switching…" : "Switch"
                color: switchHover.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: switchHover
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.switching
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  if (accountRow.modelData && accountRow.modelData.id) {
                    root.switchRequested(accountRow.modelData.id)
                  }
                }
              }
            }
          }
        }

        // Hover area for tooltip
        MouseArea {
          id: rowHover
          anchors.left: parent.left
          anchors.right: rightPart.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: rowHover.containsMouse
          text: root.accountTooltip(accountRow.modelData)
          fontFamily: root.fontFamily
        }
      }
    }
  }

  Text {
    visible: root.statusMessage !== ""
    width: parent.width
    text: root.statusMessage
    color: root.statusError ? root.urgent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }
}
