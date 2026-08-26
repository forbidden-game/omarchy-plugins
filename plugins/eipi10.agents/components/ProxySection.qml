import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: root

  property var stateData: ({})
  property bool busy: false
  property string message: ""
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  signal actionRequested(string action)

  readonly property bool active: !!stateData.active
  readonly property bool healthy: !!stateData.healthy
  readonly property bool installed: !!stateData.installed
  readonly property string statusText: busy
    ? "正在切换…"
    : (healthy ? "运行中" : (active ? "服务异常" : (installed ? "已停止" : "未安装")))
  readonly property color statusColor: healthy
    ? Color.accent
    : (active ? urgent : dim)

  width: parent ? parent.width : 0
  spacing: Style.space(8)

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  Row {
    width: parent.width
    spacing: Style.space(8)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: width
      radius: width / 2
      color: root.statusColor
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "本地流式代理 · " + root.statusText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  Text {
    width: parent.width
    text: "pi / omp · OpenAI Responses · SSE\n"
      + String(root.stateData.endpoint || "http://127.0.0.1:8317/v1")
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Flow {
    width: parent.width
    spacing: Style.space(8)

    Repeater {
      model: [
        {
          "action": root.active ? "stop" : "start",
          "label": root.active ? "停止服务" : "启动服务",
          "enabled": !root.busy
        },
        {"action": "copy-pi", "label": "复制 pi 命令", "enabled": root.healthy && !root.busy},
        {"action": "copy-omp", "label": "复制 omp 命令", "enabled": root.healthy && !root.busy}
      ]

      delegate: Rectangle {
        required property var modelData
        readonly property bool enabled: !!modelData.enabled

        implicitWidth: buttonText.implicitWidth + Style.space(16)
        implicitHeight: buttonText.implicitHeight + Style.space(8)
        radius: Style.cornerRadius
        color: enabled && mouseArea.containsMouse
          ? root.alpha(root.foreground, 0.18)
          : root.alpha(root.foreground, enabled ? 0.08 : 0.035)
        border.color: root.alpha(root.foreground, enabled ? 0.25 : 0.10)
        border.width: 1

        Text {
          id: buttonText
          anchors.centerIn: parent
          text: modelData.label
          color: root.alpha(root.foreground, parent.enabled ? 1.0 : 0.42)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: modelData.action === "start"
        }

        MouseArea {
          id: mouseArea
          anchors.fill: parent
          enabled: parent.enabled
          hoverEnabled: true
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: root.actionRequested(modelData.action)
        }
      }
    }
  }

  Text {
    visible: text !== ""
    width: parent.width
    text: root.message
    color: root.message.toLowerCase().indexOf("失败") >= 0 ? root.urgent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
