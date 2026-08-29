import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components" as Comp

// Touchpad settings as a reversible interaction loop:
//
//   open -> read effective Hyprland values -> edit with live preview
//        -> Save (persist one managed block) or close/Revert (restore snapshot)
//
// QML deliberately knows nothing about config-file syntax. The companion
// controller is the single system boundary and always returns JSON.
Panel {
  id: root
  moduleName: "eipi10.touchpad"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string controllerPath:
    home + "/.config/omarchy/plugins/eipi10.touchpad/bin/omarchy-touchpad-ctl"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property string phase: "loading" // loading, ready, empty, error
  property var devices: []
  property var saved: ({})
  property var draft: ({})
  property var presets: ({
    typing: {
      disableWhileTyping: true, naturalScroll: false, scrollFactor: 0.4,
      clickfingerBehavior: true, tapToClick: false, tapAndDrag: false,
      dragLock: 0, sensitivity: -0.1
    },
    balanced: {
      disableWhileTyping: true, naturalScroll: false, scrollFactor: 0.65,
      clickfingerBehavior: true, tapToClick: true, tapAndDrag: true,
      dragLock: 1, sensitivity: 0
    },
    gesture: {
      disableWhileTyping: true, naturalScroll: true, scrollFactor: 0.85,
      clickfingerBehavior: true, tapToClick: true, tapAndDrag: true,
      dragLock: 1, sensitivity: 0.1
    }
  })
  property bool managed: false
  property bool mixedSensitivity: false
  property bool previewQueued: false
  property bool refreshAfterRestore: false
  property string statusMessage: ""
  property string statusKind: "info" // info, success, error
  property int cursorIndex: 0

  readonly property bool ready: phase === "ready"
  readonly property bool busy:
    statusProc.running || restoreProc.running || applyProc.running || resetProc.running
  readonly property bool dirty: ready && !sameSettings(saved, draft)
  readonly property string selectedPreset: presetFor(draft)
  readonly property string cursorKey: {
    var keys = actionKeys()
    return keys.length > 0 ? keys[Math.max(0, Math.min(cursorIndex, keys.length - 1))] : ""
  }
  readonly property string deviceSummary: {
    if (devices.length === 0) return "No touchpad detected"
    if (devices.length === 1) return String(devices[0].displayName || devices[0].name)
    return devices.length + " touchpads · shared settings"
  }

  function copySettings(source) {
    var copy = {}
    if (!source) return copy
    var keys = [
      "disableWhileTyping", "naturalScroll", "scrollFactor",
      "clickfingerBehavior", "tapToClick", "tapAndDrag",
      "dragLock", "sensitivity"
    ]
    for (var i = 0; i < keys.length; i++) copy[keys[i]] = source[keys[i]]
    return copy
  }

  function sameSettings(a, b) {
    if (!a || !b) return false
    var keys = [
      "disableWhileTyping", "naturalScroll", "scrollFactor",
      "clickfingerBehavior", "tapToClick", "tapAndDrag",
      "dragLock", "sensitivity"
    ]
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      if (typeof a[key] === "number" || typeof b[key] === "number") {
        if (Math.abs(Number(a[key]) - Number(b[key])) > 0.001) return false
      } else if (a[key] !== b[key]) {
        return false
      }
    }
    return true
  }

  function presetFor(values) {
    if (sameSettings(values, presets.typing)) return "typing"
    if (sameSettings(values, presets.balanced)) return "balanced"
    if (sameSettings(values, presets.gesture)) return "gesture"
    return ""
  }

  function normalized(next) {
    var result = copySettings(next)
    result.scrollFactor = Math.max(0.1, Math.min(2.0, Number(result.scrollFactor)))
    result.sensitivity = Math.max(-1.0, Math.min(1.0, Number(result.sensitivity)))
    result.dragLock = Math.max(0, Math.min(2, Math.round(Number(result.dragLock))))
    if (!result.tapToClick) result.tapAndDrag = false
    if (!result.tapAndDrag) result.dragLock = 0
    return result
  }

  function setValue(key, value) {
    if (!ready || busy) return
    var next = copySettings(draft)
    next[key] = value
    draft = normalized(next)
    statusMessage = ""
    schedulePreview()
  }

  function usePreset(name) {
    if (!presets[name]) return
    draft = normalized(presets[name])
    statusMessage = ""
    schedulePreview()
  }

  function actionKeys() {
    var keys = [
      "preset-typing", "preset-balanced", "preset-gesture",
      "natural", "scroll", "tap", "click-mode", "tap-drag"
    ]
    if (draft.tapAndDrag) keys.push("drag-lock")
    keys.push("typing-protection", "pointer-speed", "reset", "revert", "save")
    return keys
  }

  function actionEnabled(key) {
    if (busy) return false
    if (key === "tap-drag") return draft.tapToClick === true
    if (key === "reset") return managed
    if (key === "revert" || key === "save") return dirty
    return ready
  }

  function setCursor(key) {
    var index = actionKeys().indexOf(key)
    if (index >= 0) cursorIndex = index
  }

  function advanceCursor(direction) {
    var keys = actionKeys()
    if (keys.length === 0) return
    var next = cursorIndex
    for (var tries = 0; tries < keys.length; tries++) {
      next = (next + direction + keys.length) % keys.length
      if (actionEnabled(keys[next])) {
        cursorIndex = next
        ensureCursorVisibleFor(keys[next])
        return
      }
    }
  }

  function moveCursor(dx, dy) {
    if (resetConfirm.opened) {
      if (dx !== 0 || dy !== 0) resetConfirm.selectedIndex = resetConfirm.selectedIndex === 0 ? 1 : 0
      return
    }
    if (dy !== 0) {
      advanceCursor(dy > 0 ? 1 : -1)
      return
    }
    if (dx === 0) return

    var direction = dx > 0 ? 1 : -1
    if (cursorKey.indexOf("preset-") === 0) {
      var presetIndex = Math.max(0, Math.min(2, cursorIndex + direction))
      cursorIndex = presetIndex
      ensureCursorVisibleFor(actionKeys()[presetIndex])
    } else if (cursorKey === "scroll") {
      setValue("scrollFactor", Number(draft.scrollFactor) + direction * 0.05)
    } else if (cursorKey === "pointer-speed") {
      setValue("sensitivity", Number(draft.sensitivity) + direction * 0.05)
    } else if (cursorKey === "click-mode") {
      setValue("clickfingerBehavior", !draft.clickfingerBehavior)
    } else if (cursorKey === "drag-lock") {
      setValue("dragLock", (Number(draft.dragLock) + direction + 3) % 3)
    }
  }

  function activateCursor() {
    if (resetConfirm.opened) {
      if (resetConfirm.selectedIndex === 0) resetConfirm.canceled()
      else resetConfirm.confirmed()
      return
    }
    switch (cursorKey) {
      case "preset-typing": usePreset("typing"); break
      case "preset-balanced": usePreset("balanced"); break
      case "preset-gesture": usePreset("gesture"); break
      case "natural": setValue("naturalScroll", !draft.naturalScroll); break
      case "tap": setValue("tapToClick", !draft.tapToClick); break
      case "click-mode": setValue("clickfingerBehavior", !draft.clickfingerBehavior); break
      case "tap-drag": setValue("tapAndDrag", !draft.tapAndDrag); break
      case "drag-lock": setValue("dragLock", (Number(draft.dragLock) + 1) % 3); break
      case "typing-protection": setValue("disableWhileTyping", !draft.disableWhileTyping); break
      case "reset": resetConfirm.opened = true; break
      case "revert": revertDraft(); break
      case "save": saveDraft(); break
    }
  }

  function ensureVisible(item) {
    if (!item || !panelFlick || !settingsColumn) return
    var point = item.mapToItem(settingsColumn, 0, 0)
    var top = point.y
    var bottom = top + item.height
    if (top < panelFlick.contentY) panelFlick.contentY = top
    else if (bottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = bottom - panelFlick.height
  }

  function ensureCursorVisibleFor(key) {
    var item = cursorItems[key]
    if (item) Qt.callLater(function() { root.ensureVisible(item) })
  }

  property var cursorItems: ({})

  function registerCursorItem(key, item) {
    var next = {}
    for (var existing in cursorItems) next[existing] = cursorItems[existing]
    next[key] = item
    cursorItems = next
  }

  function parseResponse(raw) {
    try {
      var lines = String(raw || "").trim().split("\n")
      for (var i = lines.length - 1; i >= 0; i--) {
        if (!lines[i].trim()) continue
        var parsed = JSON.parse(lines[i])
        if (parsed && typeof parsed === "object") return parsed
      }
    } catch (error) {
      console.warn("touchpad", "Bad controller response", error)
    }
    return null
  }

  function acceptStatus(raw) {
    var data = parseResponse(raw)
    if (!data || data.ok !== true) {
      phase = "error"
      statusKind = "error"
      statusMessage = data && data.error ? String(data.error) : "Could not read touchpad settings"
      return
    }

    devices = data.devices || []
    managed = data.managed === true
    mixedSensitivity = data.mixedSensitivity === true
    if (data.presets) presets = data.presets
    saved = normalized(data.values || {})
    draft = copySettings(saved)
    cursorIndex = 0
    phase = data.available ? "ready" : "empty"
    statusMessage = data.status === "reset" ? "Plugin overrides removed" : ""
    statusKind = "success"
  }

  function refreshStatus() {
    if (statusProc.running) return
    if (restoreProc.running) {
      refreshAfterRestore = true
      return
    }
    if (dirty) {
      refreshAfterRestore = true
      draft = copySettings(saved)
      restoreSaved()
      return
    }
    phase = "loading"
    statusMessage = ""
    statusProc.running = true
  }

  function schedulePreview() {
    if (!ready || devices.length === 0) return
    previewTimer.restart()
  }

  function runPreview() {
    if (!dirty || !ready) return
    if (previewProc.running) {
      previewQueued = true
      return
    }
    previewQueued = false
    previewProc.command = [controllerPath, "preview", "--json", JSON.stringify(draft)]
    previewProc.running = true
  }

  function restoreSaved() {
    previewTimer.stop()
    previewQueued = false
    if (previewProc.running) previewProc.running = false
    if (devices.length === 0 || Object.keys(saved).length === 0) return
    restoreProc.command = [controllerPath, "preview", "--json", JSON.stringify(saved)]
    restoreProc.running = true
  }

  function revertDraft() {
    draft = copySettings(saved)
    statusKind = "info"
    statusMessage = "Preview reverted"
    restoreSaved()
  }

  function saveDraft() {
    if (!dirty || busy) return
    previewTimer.stop()
    previewQueued = false
    if (previewProc.running) previewProc.running = false
    statusMessage = "Saving…"
    statusKind = "info"
    applyProc.command = [controllerPath, "apply", "--json", JSON.stringify(draft)]
    applyProc.running = true
  }

  function acceptApply(raw) {
    var data = parseResponse(raw)
    if (!data || data.ok !== true) {
      statusKind = "error"
      statusMessage = data && data.error ? String(data.error) : "Could not save settings"
      return
    }
    devices = data.devices || devices
    saved = normalized(data.values || draft)
    draft = copySettings(saved)
    managed = true
    statusKind = "success"
    statusMessage = "Saved to input.lua"
    successTimer.restart()
  }

  function acceptPreview(raw) {
    var data = parseResponse(raw)
    if (data && data.ok === false) {
      statusKind = "error"
      statusMessage = String(data.error || "Live preview failed")
    }
  }

  function requestReset() {
    resetConfirm.opened = false
    if (!managed || busy) return
    previewTimer.stop()
    if (previewProc.running) previewProc.running = false
    statusKind = "info"
    statusMessage = "Restoring Omarchy values…"
    resetProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      refreshStatus()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else if (dirty) {
      restoreSaved()
      draft = copySettings(saved)
    }
  }

  Component.onCompleted: refreshStatus()

  Timer {
    id: previewTimer
    interval: 140
    repeat: false
    onTriggered: root.runPreview()
  }

  Timer {
    id: successTimer
    interval: 2400
    repeat: false
    onTriggered: if (root.statusKind === "success") root.statusMessage = ""
  }

  Process {
    id: statusProc
    command: [root.controllerPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptStatus(text)
    }
  }

  Process {
    id: previewProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptPreview(text)
    }
    onExited: {
      if (root.previewQueued && root.opened) {
        Qt.callLater(function() { root.runPreview() })
      }
    }
  }

  Process {
    id: restoreProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptPreview(text)
    }
    onExited: {
      if (root.refreshAfterRestore) {
        root.refreshAfterRestore = false
        Qt.callLater(function() { root.refreshStatus() })
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptApply(text)
    }
  }

  Process {
    id: resetProc
    command: [root.controllerPath, "reset"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptStatus(text)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰟸"
    active: root.dirty || root.phase === "error"
    dimmed: root.phase === "empty"
    tooltipText: root.phase === "empty"
      ? "Touchpad · no device"
      : (root.dirty ? "Touchpad · unsaved preview" : "Touchpad settings")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshStatus()
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(settingsColumn.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        if (resetConfirm.opened) resetConfirm.opened = false
        else root.close()
      }
      onTabRequested: function(direction) {
        if (resetConfirm.opened) {
          resetConfirm.selectedIndex = resetConfirm.selectedIndex === 0 ? 1 : 0
        } else {
          root.switchPanel(direction)
        }
      }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshStatus()
        else if (text === "s" || text === "S") root.saveDraft()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: settingsColumn
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------------------------------------------------------- loading
          Column {
            visible: root.phase === "loading"
            width: parent.width
            spacing: Style.space(12)

            Text {
              text: "Detecting touchpad…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Repeater {
              model: [0.82, 1.0, 0.68]
              Rectangle {
                required property real modelData
                width: parent.width * modelData
                height: Style.space(16)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)

                SequentialAnimation on opacity {
                  loops: Animation.Infinite
                  NumberAnimation { from: 0.45; to: 0.9; duration: 650 }
                  NumberAnimation { from: 0.9; to: 0.45; duration: 650 }
                }
              }
            }
          }

          // ------------------------------------------------------ empty/error
          Column {
            visible: root.phase === "empty" || root.phase === "error"
            width: parent.width
            spacing: Style.space(12)

            Text {
              width: parent.width
              text: root.phase === "empty" ? "No touchpad detected" : "Touchpad settings unavailable"
              color: root.phase === "error" ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: root.phase === "empty"
                ? "Connect or enable a touchpad, then scan again. The panel stays available so recovery never depends on the missing device."
                : root.statusMessage
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Scan again"
              iconText: "󰑓"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              onClicked: root.refreshStatus()
            }
          }

          // ------------------------------------------------------------ ready
          Column {
            visible: root.ready
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              width: parent.width
              title: "Touchpad"
              meta: root.deviceSummary
              detail: root.dirty ? "PREVIEW" : (root.managed ? "SAVED" : "SYSTEM")
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  text: "󰟸"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            Text {
              visible: root.mixedSensitivity
              width: parent.width
              text: "Connected touchpads use different pointer speeds. Saving will align them."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "STARTING POINT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: presetRow
              width: parent.width
              spacing: Style.spacing.controlGap

              Repeater {
                model: [
                  { key: "typing", action: "preset-typing", label: "Typing" },
                  { key: "balanced", action: "preset-balanced", label: "Balanced" },
                  { key: "gesture", action: "preset-gesture", label: "Gesture" }
                ]

                Button {
                  required property var modelData
                  width: (presetRow.width - presetRow.spacing * 2) / 3
                  text: modelData.label
                  selected: root.selectedPreset === modelData.key
                  hasCursor: root.cursorKey === modelData.action
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.usePreset(modelData.key)
                  onHovered: function(active) { if (active) root.setCursor(modelData.action) }
                  Component.onCompleted: root.registerCursorItem(modelData.action, this)
                }
              }
            }

            Text {
              width: parent.width
              text: root.selectedPreset === "typing"
                ? "Physical clicks and conservative motion reduce accidental input while writing."
                : (root.selectedPreset === "gesture"
                  ? "Natural scrolling, taps, and drag lock favor touch-first navigation."
                  : (root.selectedPreset === "balanced"
                    ? "A moderate baseline for everyday pointing, scrolling, and dragging."
                    : "Custom values · choosing a preset replaces the current preview."))
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "SCROLLING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              id: naturalToggle
              width: parent.width
              label: "Natural scrolling"
              description: "Move the content in the same direction as your fingers."
              checked: root.draft.naturalScroll === true
              hasCursor: root.cursorKey === "natural"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setValue("naturalScroll", !root.draft.naturalScroll)
              onHovered: function(active) { if (active) root.setCursor("natural") }
              Component.onCompleted: root.registerCursorItem("natural", this)
            }

            Comp.SettingSlider {
              id: scrollSlider
              width: parent.width
              bar: root.bar
              label: "Scroll speed"
              description: "Hyprland touchpad scroll multiplier"
              value: Number(root.draft.scrollFactor || 0)
              valueText: Number(root.draft.scrollFactor || 0).toFixed(2) + "×"
              minimum: 0.1
              maximum: 2.0
              step: 0.05
              hasCursor: root.cursorKey === "scroll"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onMoved: function(value) { root.setValue("scrollFactor", value) }
              onReleased: function(value) { root.setValue("scrollFactor", value) }
              onHovered: function(active) { if (active) root.setCursor("scroll") }
              Component.onCompleted: root.registerCursorItem("scroll", this)
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "CLICKING & DRAGGING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              id: tapToggle
              width: parent.width
              label: "Tap to click"
              description: "One-, two-, and three-finger taps send left, right, and middle clicks."
              checked: root.draft.tapToClick === true
              hasCursor: root.cursorKey === "tap"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setValue("tapToClick", !root.draft.tapToClick)
              onHovered: function(active) { if (active) root.setCursor("tap") }
              Component.onCompleted: root.registerCursorItem("tap", this)
            }

            Comp.ChoiceSetting {
              id: clickChoice
              width: parent.width
              label: "Physical click"
              description: root.draft.clickfingerBehavior
                ? "Press with one, two, or three fingers for left, right, or middle click."
                : "The lower-left and lower-right areas choose the button."
              options: [
                { label: "Finger count", value: true },
                { label: "Button areas", value: false }
              ]
              value: root.draft.clickfingerBehavior === true
              hasCursor: root.cursorKey === "click-mode"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onSelected: function(value) { root.setValue("clickfingerBehavior", value) }
              onHovered: function(active) { if (active) root.setCursor("click-mode") }
              Component.onCompleted: root.registerCursorItem("click-mode", this)
            }

            Toggle {
              id: dragToggle
              width: parent.width
              label: "Tap and drag"
              description: root.draft.tapToClick
                ? "Tap, then keep the finger down to drag."
                : "Turn on tap to click before enabling this gesture."
              checked: root.draft.tapAndDrag === true
              enabled: root.draft.tapToClick === true
              opacity: enabled ? 1 : 0.48
              hasCursor: root.cursorKey === "tap-drag"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setValue("tapAndDrag", !root.draft.tapAndDrag)
              onHovered: function(active) { if (active && enabled) root.setCursor("tap-drag") }
              Component.onCompleted: root.registerCursorItem("tap-drag", this)
            }

            Comp.ChoiceSetting {
              id: dragLockChoice
              visible: root.draft.tapAndDrag === true
              width: parent.width
              label: "Drag lock"
              description: "Keep holding the dragged item when your finger briefly lifts."
              options: [
                { label: "Off", value: 0 },
                { label: "Timeout", value: 1 },
                { label: "Sticky", value: 2 }
              ]
              value: Number(root.draft.dragLock || 0)
              hasCursor: root.cursorKey === "drag-lock"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onSelected: function(value) { root.setValue("dragLock", value) }
              onHovered: function(active) { if (active) root.setCursor("drag-lock") }
              Component.onCompleted: root.registerCursorItem("drag-lock", this)
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "CONTROL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              id: typingToggle
              width: parent.width
              label: "Disable while typing"
              description: "Ignore touchpad movement while keys are being pressed."
              checked: root.draft.disableWhileTyping === true
              hasCursor: root.cursorKey === "typing-protection"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setValue("disableWhileTyping", !root.draft.disableWhileTyping)
              onHovered: function(active) { if (active) root.setCursor("typing-protection") }
              Component.onCompleted: root.registerCursorItem("typing-protection", this)
            }

            Comp.SettingSlider {
              id: pointerSlider
              width: parent.width
              bar: root.bar
              label: "Pointer speed"
              description: "Applied only to detected touchpads, not external mice"
              value: Number(root.draft.sensitivity || 0)
              valueText: {
                var number = Number(root.draft.sensitivity || 0)
                if (Math.abs(number) < 0.01) return "Default"
                return (number > 0 ? "+" : "") + number.toFixed(2)
              }
              minimum: -1.0
              maximum: 1.0
              step: 0.05
              hasCursor: root.cursorKey === "pointer-speed"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onMoved: function(value) { root.setValue("sensitivity", value) }
              onReleased: function(value) { root.setValue("sensitivity", value) }
              onHovered: function(active) { if (active) root.setCursor("pointer-speed") }
              Component.onCompleted: root.registerCursorItem("pointer-speed", this)
            }

            Comp.TestSurface {
              width: parent.width
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.statusMessage !== ""
              width: parent.width
              text: root.statusMessage
              color: root.statusKind === "error"
                ? root.urgent
                : (root.statusKind === "success" ? root.accent : root.dim)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            Row {
              id: actionRow
              width: parent.width
              spacing: Style.spacing.controlGap

              Button {
                id: resetButton
                width: Style.space(138)
                text: "Omarchy defaults"
                bordered: true
                enabled: root.managed && !root.busy
                opacity: enabled ? 1 : 0.45
                hasCursor: root.cursorKey === "reset"
                foreground: root.foreground
                accent: root.accent
                onClicked: resetConfirm.opened = true
                onHovered: function(active) { if (active && enabled) root.setCursor("reset") }
                Component.onCompleted: root.registerCursorItem("reset", this)
              }

              Item {
                width: Math.max(0, actionRow.width
                  - resetButton.width - revertButton.width - saveButton.width
                  - actionRow.spacing * 3)
                height: 1
              }

              Button {
                id: revertButton
                width: Style.space(76)
                text: "Revert"
                enabled: root.dirty && !root.busy
                opacity: enabled ? 1 : 0.45
                hasCursor: root.cursorKey === "revert"
                foreground: root.foreground
                accent: root.accent
                onClicked: root.revertDraft()
                onHovered: function(active) { if (active && enabled) root.setCursor("revert") }
                Component.onCompleted: root.registerCursorItem("revert", this)
              }

              Button {
                id: saveButton
                width: Style.space(76)
                text: root.busy ? "Saving…" : "Save"
                selected: root.dirty
                enabled: root.dirty && !root.busy
                opacity: enabled ? 1 : 0.45
                hasCursor: root.cursorKey === "save"
                foreground: root.foreground
                accent: root.accent
                onClicked: root.saveDraft()
                onHovered: function(active) { if (active && enabled) root.setCursor("save") }
                Component.onCompleted: root.registerCursorItem("save", this)
              }
            }

            Text {
              width: parent.width
              text: "Changes preview immediately. Closing the panel restores the last saved values."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }

      ConfirmDialog {
        id: resetConfirm
        anchors.fill: parent
        message: "Remove this plugin’s managed block and reload the values from your Omarchy configuration?"
        cancelText: "Cancel"
        confirmText: "Reset"
        foreground: root.foreground
        background: Color.popups.background
        fontFamily: root.fontFamily
        onCanceled: opened = false
        onConfirmed: root.requestReset()
      }
    }
  }
}
