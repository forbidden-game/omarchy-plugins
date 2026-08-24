import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Native status and launcher for the official 365VPN client. Authentication,
// node selection, routing mode, and connection control stay in the vendor GUI.
BarWidget {
  id: root
  moduleName: "eipi10.365vpn"

  property string state: "checking"
  readonly property bool connected: state === "connected"
  readonly property bool available: state !== "missing"
  readonly property string label: connected ? "VPN ●" : (state === "running" ? "VPN ◇" : "VPN")
  readonly property string statusText: {
    if (state === "connected") return "365VPN connected · click to show client"
    if (state === "running") return "365VPN is open · connect in the official client"
    if (state === "ready") return "365VPN is ready · click to open"
    if (state === "stopped") return "365VPN helper is stopped · click to open"
    if (state === "missing") return "365VPN is not installed"
    return "Checking 365VPN…"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!probe.running) probe.running = true
  }

  function applyState(raw) {
    var value = String(raw || "").trim()
    state = value === "connected" || value === "running" || value === "ready"
      || value === "stopped" || value === "missing" ? value : "stopped"
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: probe
    command: [
      "bash", "-c",
      "if [ ! -x /usr/bin/365vpn ]; then echo missing; "
      + "elif pgrep -x 365vpn >/dev/null && ss -H -ltn 'sport = :57777' | read -r line; then echo connected; "
      + "elif pgrep -x 365vpn >/dev/null; then echo running; "
      + "elif systemctl is-active --quiet 365VPNDaemon.service; then echo ready; "
      + "else echo stopped; fi"
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
  }


  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: Style.font.caption
    horizontalMargin: 7
    dimmed: !root.connected
    interactive: root.available
    tooltipText: root.statusText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        root.refresh()
        return
      }
      Quickshell.execDetached(["/usr/bin/gtk-launch", "365vpn"])
    }
  }
}
