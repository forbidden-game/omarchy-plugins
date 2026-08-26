import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components" as Comp

Panel {
  id: root
  moduleName: "omarchy.agents"
  ipcTarget: "omarchy.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string home: Quickshell.env("HOME") || ""

  readonly property var providers: usage.enabledProviders
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].providerId === selectedProviderId) return i
    }
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  readonly property var headline: bindingWindow(provider)

  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent <= 0.15) || balanceAlarming

  // ------------------------------------------------------------- Antigravity OAuth & Switch
  property bool oauthActive: false
  property string oauthAuthUrl: ""
  property string oauthStatus: "idle" // "idle", "listening", "success", "error"
  property string oauthMessage: ""
  property bool accountSwitching: false
  property var proxyState: ({})
  property bool proxyBusy: false
  property string proxyMessage: ""

  Process {
    id: switchProc
    running: false
    onExited: function(exitCode) {
      root.accountSwitching = false
      if (exitCode === 0) {
        usage.refreshAll(true)
      }
    }
  }

  Process {
    id: oauthProc
    running: false
    stdout: StdioCollector {
      waitForEnd: false
      onStreamFinished: root.parseOAuthStream(text)
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.oauthStatus === "listening") {
        root.oauthStatus = "success"
        usage.refreshAll(true)
        autoCloseTimer.restart()
      } else if (exitCode !== 0 && root.oauthStatus === "listening") {
        root.oauthStatus = "error"
      }
    }
  }

  Timer {
    id: autoCloseTimer
    interval: 2500
    repeat: false
    onTriggered: {
      if (root.oauthStatus === "success") {
        root.oauthActive = false
        root.oauthStatus = "idle"
      }
    }
  }

  Process {
    id: oauthCancelProc
    running: false
    command: [root.home + "/.config/omarchy/plugins/eipi10.agents/bin/omarchy-antigravity-ctl", "oauth-cancel"]
  }

  Process {
    id: copyProc
    running: false
  }

  Process {
    id: proxyStatusProc
    running: false
    command: [root.home + "/.config/omarchy/plugins/eipi10.agents/bin/omarchy-antigravity-ctl", "proxy-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseProxyStatus(text)
    }
  }

  Process {
    id: proxyControlProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseProxyControl(text)
    }
    onExited: function(exitCode) {
      root.proxyBusy = false
      if (exitCode !== 0 && root.proxyMessage === "") root.proxyMessage = "代理操作失败"
      root.refreshProxyStatus()
    }
  }

  function switchAccount(accId) {
    if (accountSwitching || !accId) return
    accountSwitching = true
    switchProc.command = [root.home + "/.config/omarchy/plugins/eipi10.agents/bin/omarchy-antigravity-ctl", "switch", accId]
    switchProc.running = true
  }

  function startOAuth() {
    oauthActive = true
    oauthStatus = "listening"
    oauthAuthUrl = ""
    oauthMessage = ""
    oauthProc.command = [root.home + "/.config/omarchy/plugins/eipi10.agents/bin/omarchy-antigravity-ctl", "oauth-start"]
    oauthProc.running = true
  }

  function cancelOAuth() {
    oauthActive = false
    oauthStatus = "idle"
    if (oauthProc.running) {
      oauthProc.running = false
    }
    oauthCancelProc.running = true
  }

  function copyOAuthLink() {
    if (oauthAuthUrl !== "") {
      copyProc.command = ["wl-copy", oauthAuthUrl]
      copyProc.running = true
    }
  }

  function parseOAuthStream(txt) {
    var lines = String(txt || "").trim().split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line.charAt(0) === "{" && line.slice(-1) === "}") {
        try {
          var d = JSON.parse(line)
          if (d.status === "listening" && d.auth_url) {
            root.oauthAuthUrl = d.auth_url
            root.oauthStatus = "listening"
          } else if (d.status === "success") {
            root.oauthStatus = "success"
            usage.refreshAll(true)
            autoCloseTimer.restart()
          } else if (d.status === "error") {
            root.oauthStatus = "error"
            root.oauthMessage = d.error || "授权失败"
          }
        } catch (e) {}
      }
    }
  }

  function lastJsonLine(txt) {
    var lines = String(txt || "").trim().split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line.charAt(0) !== "{" || line.slice(-1) !== "}") continue
      try { return JSON.parse(line) } catch (e) {}
    }
    return null
  }

  function parseProxyStatus(txt) {
    var state = lastJsonLine(txt)
    if (state) proxyState = state
  }

  function parseProxyControl(txt) {
    var result = lastJsonLine(txt)
    if (!result) return
    if (result.status === "error") {
      proxyMessage = "操作失败：" + String(result.error || "未知错误")
    } else if (result.status === "copied") {
      proxyMessage = String(result.client || "").toUpperCase() + " 启动命令已复制"
    } else if (result.status === "running") {
      proxyMessage = "流式代理已启动"
    } else if (result.status === "stopped") {
      proxyMessage = "流式代理已停止"
    }
  }

  function refreshProxyStatus() {
    if (!proxyStatusProc.running) proxyStatusProc.running = true
  }

  function runProxyAction(action) {
    if (proxyBusy || proxyControlProc.running) return
    proxyBusy = true
    proxyMessage = ""
    var command = action === "start"
      ? "proxy-start"
      : (action === "stop" ? "proxy-stop" : "proxy-copy")
    proxyControlProc.command = [
      root.home + "/.config/omarchy/plugins/eipi10.agents/bin/omarchy-antigravity-ctl",
      command
    ]
    if (action === "copy-pi") proxyControlProc.command.push("pi")
    else if (action === "copy-omp") proxyControlProc.command.push("omp")
    proxyControlProc.running = true
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ------------------------------------------------------------- limits parsing
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) {
        var res = String(entry.resetsAt || entry.resetAt || "")
        out.push({
          title: String(entry.title || "") !== "" ? String(entry.title) : windowTitle(entry.label),
          percent: percent,
          remaining: entry.remaining !== undefined ? Number(entry.remaining) : percent,
          resetsAt: res,
          resetAt: res,
          weeklyPercent: entry.weeklyPercent !== undefined && entry.weeklyPercent !== null ? Number(entry.weeklyPercent) : null,
          weeklyResetAt: entry.weeklyResetAt ? String(entry.weeklyResetAt) : ""
        })
      }
    }
    return out
  }

  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0) {
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    }
    return ""
  }

  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: {
    if (panelFlick) panelFlick.contentY = 0
    if (provider && provider.providerId === "antigravity") refreshProxyStatus()
  }
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshAll(false)
    if (provider && provider.providerId === "antigravity") refreshProxyStatus()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 5000
    running: root.opened && !!root.provider && root.provider.providerId === "antigravity"
    repeat: true
    onTriggered: root.refreshProxyStatus()
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refreshNow(); return "ok" }
    function next() { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0) {
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
        }
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Provider switch (Top Tab Switcher) ----------
          Comp.ProviderSwitcher {
            providers: root.providers
            selectedIndex: root.providerIndex
            cursorActive: root.cursorActive
            foreground: root.foreground
            fontFamily: root.fontFamily
            onSelectRequested: function(idx) {
              root.cursorActive = true
              root.selectProvider(idx)
            }
          }

          // ---------- Hero: provider mark · name · plan · today cost ----------
          Comp.HeroSection {
            provider: root.provider
            customRates: usage.customRates
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
          }

          // ---------- Multi-Account Switcher (Antigravity) ----------
          PanelSeparator {
            visible: accSwitcher.visible
            foreground: root.foreground
          }

          Comp.AccountSwitcher {
            id: accSwitcher
            visible: !!root.provider && (root.provider.providerId === "antigravity" || (root.provider.accounts && root.provider.accounts.length > 0))
            accounts: root.provider ? (root.provider.accounts || []) : []
            currentAccountId: root.provider ? (root.provider.currentAccountId || "") : ""
            switching: root.accountSwitching
            nowMs: root.nowMs
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
            onSwitchRequested: function(accId) { root.switchAccount(accId) }
            onAddAccountRequested: function() { root.startOAuth() }
          }

          // ---------- OAuth Silent Link Box ----------
          Comp.OAuthLinkBox {
            id: oauthBox
            visible: root.oauthActive
            authUrl: root.oauthAuthUrl
            status: root.oauthStatus
            statusMessage: root.oauthMessage
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
            onCopyLinkRequested: function() { root.copyOAuthLink() }
            onCancelRequested: function() { root.cancelOAuth() }
          }

          // ---------- Local streaming proxy for pi / omp ----------
          PanelSeparator {
            visible: proxySec.visible
            foreground: root.foreground
          }

          Comp.ProxySection {
            id: proxySec
            visible: !!root.provider && root.provider.providerId === "antigravity"
            stateData: root.proxyState
            busy: root.proxyBusy
            message: root.proxyMessage
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
            onActionRequested: function(action) { root.runProxyAction(action) }
          }

          // ---------- Status Banner ----------
          Comp.StatusBanner {
            statusText: root.provider ? String(root.provider.authHelpText || "") : ""
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSec.visible || limitsSec.visible
            foreground: root.foreground
          }

          Comp.BalanceSection {
            id: balanceSec
            balance: root.balance
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
          }

          Comp.LimitsSection {
            id: limitsSec
            limits: root.limits
            nowMs: root.nowMs
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
          }

          // ---------- Daily Usage ----------
          PanelSeparator {
            visible: dailySec.visible
            foreground: root.foreground
          }

          Comp.DailyUsageSection {
            id: dailySec
            provider: usage.aggregateProvider || root.provider
            customRates: usage.customRates
            nowMs: root.nowMs
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            trackColor: root.track
            fontFamily: root.fontFamily
          }

          // ---------- Models & Cost ----------
          PanelSeparator {
            visible: modelSec.visible
            foreground: root.foreground
          }

          Comp.ModelUsageSection {
            id: modelSec
            provider: usage.aggregateProvider || root.provider
            customRates: usage.customRates
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
          }

          // ---------- Footer (Sync Info) ----------
          Text {
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
