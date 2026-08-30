import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  required property var entry
  required property int pairIndex
  property bool current: false
  property bool opened: false

  signal toggled()
  signal discussionEdited(string text)

  readonly property bool expanded: current || opened
  readonly property color foreground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property string fontFamily: Style.font.family

  implicitHeight: content.implicitHeight

  function sourceLabel() {
    var sourceClass = String(entry.sourceClass || "").trim()
    var sourceTitle = String(entry.sourceTitle || "").trim()
    if (sourceClass && sourceTitle) return sourceClass + " / " + sourceTitle
    return sourceTitle || sourceClass || "UNKNOWN"
  }

  function preview(text) {
    return String(text || "").replace(/\s+/g, " ").trim()
  }

  function focusEditor() {
    if (!expanded) return
    discussionEditor.forceActiveFocus()
    discussionEditor.cursorPosition = discussionEditor.length
  }

  Column {
    id: content
    width: parent.width
    spacing: Style.space(6)

    BorderSurface {
      id: collapsedSurface
      visible: !root.expanded
      width: parent.width
      height: visible ? Style.space(64) : 0
      radius: Style.cornerRadius
      color: collapsedMouse.containsMouse
        ? Style.hoverFillFor(root.foreground, root.accent)
        : Style.normalFillFor(root.foreground, root.accent)
      borderSpec: Border.controlSpec(
        collapsedMouse.containsMouse ? "hover-cursor" : "normal",
        root.foreground,
        root.accent
      )

      RowLayout {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        spacing: Style.space(10)

        Rectangle {
          Layout.preferredWidth: Style.space(26)
          Layout.preferredHeight: Style.space(26)
          Layout.alignment: Qt.AlignVCenter
          radius: width / 2
          color: root.accent

          Text {
            anchors.centerIn: parent
            text: String(root.pairIndex + 1)
            color: Color.background
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.space(2)

          Text {
            Layout.fillWidth: true
            text: "REF // " + root.sourceLabel()
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: Style.spaceReal(0.7)
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            text: root.preview(root.entry.text)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            text: root.preview(root.entry.discussion) || "NOTE // NULL"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          text: "OPEN"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: Style.spaceReal(0.7)
        }
      }

      MouseArea {
        id: collapsedMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
      }
    }

    Row {
      visible: root.expanded
      width: parent.width
      height: visible ? expandedColumn.implicitHeight : 0
      spacing: Style.space(10)

      Rectangle {
        width: Style.space(28)
        height: width
        radius: width / 2
        color: root.current ? root.accent : Style.normalFillFor(root.foreground, root.accent)
        border.color: root.accent
        border.width: root.current ? 0 : Math.max(1, Style.normalBorderWidth)

        Text {
          anchors.centerIn: parent
          text: String(root.pairIndex + 1)
          color: root.current ? Color.background : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Column {
        id: expandedColumn
        width: parent.width - Style.space(38)
        spacing: Style.space(8)

        BorderSurface {
          id: quoteSurface
          width: parent.width
          implicitHeight: quoteColumn.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(3)
            color: root.accent
          }

          Column {
            id: quoteColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            anchors.leftMargin: Style.space(14)
            spacing: Style.space(6)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                text: "REF // " + root.sourceLabel()
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: Style.spaceReal(0.7)
                elide: Text.ElideRight
              }

              Text {
                visible: !root.current
                text: "CLOSE"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: Style.spaceReal(0.7)

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(5)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggled()
                }
              }
            }

            Text {
              width: parent.width
              text: String(root.entry.text || "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
            }

            Text {
              visible: root.entry.truncated === true
              width: parent.width
              text: "TRUNCATED // 200K LIMIT"
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: Style.spaceReal(0.7)
              wrapMode: Text.WordWrap
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(5)

          Text {
            text: root.current ? "NOTE // LIVE" : "NOTE // ARCHIVE"
            color: root.current ? root.accent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: root.current
            font.letterSpacing: Style.spaceReal(0.7)
          }

          TextArea {
            id: discussionEditor
            width: parent.width
            height: Math.max(Style.space(88), contentHeight + topPadding + bottomPadding)
            text: String(root.entry.discussion || "")
            placeholderText: "INPUT NOTE..."
            placeholderTextColor: root.muted
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, root.accent)
            selectedTextColor: Color.background
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            padding: Style.space(10)

            background: BorderSurface {
              color: Style.normalFillFor(root.foreground, root.accent)
              radius: Style.cornerRadius
              borderSpec: Border.controlSpec(
                discussionEditor.activeFocus ? "focus" : "normal",
                root.foreground,
                root.accent
              )
            }

            onTextChanged: {
              if (text !== String(root.entry.discussion || ""))
                root.discussionEdited(text)
            }
          }
        }
      }
    }
  }
}
