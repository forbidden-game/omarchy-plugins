import QtQuick
import qs.Commons
import qs.Ui

// A PanelSlider-shaped control with one deliberate interaction difference:
// wheel and two-finger scroll events pass through to the surrounding panel.
// Pointer values change only from a left-button press/drag; keyboard stepping
// remains owned by Touchpad.qml's h/l cursor model.
Item {
  id: root

  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property color trackColor: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "#333"
  property color fillColor: bar ? bar.foreground : Color.foreground
  property color knobColor: bar ? bar.foreground : Color.foreground
  property bool dragging: false
  property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  property real liveValue: value

  onValueChanged: if (!dragging) liveValue = value

  signal moved(real value)
  signal released(real value)

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
  readonly property bool hot: pointer.containsMouse || dragging

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: root.trackHeight
    radius: height / 2
    color: root.trackColor
  }

  Rectangle {
    anchors.left: track.left
    anchors.verticalCenter: track.verticalCenter
    width: track.width * root.progress
    height: track.height
    radius: track.radius
    color: root.fillColor

    Behavior on width {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }

  BorderSurface {
    width: root.knobSize
    height: root.knobSize
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progress - width / 2))
    scale: root.hot ? 1.15 : 1.0
    radius: root.knobSize / 2
    color: root.knobColor
    borderSpec: Border.flat(
      root.bar ? root.bar.background : "#101315",
      Math.max(1, Style.space(2))
    )

    Behavior on x {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor

    function valueFromX(position) {
      var clamped = Math.max(0, Math.min(track.width, position))
      var raw = root.minimum + (clamped / track.width) * root.range
      if (root.integer) raw = Math.round(raw)
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    onPressed: function(mouse) {
      root.dragging = true
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }

    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }

    onReleased: {
      root.dragging = false
      root.released(root.liveValue)
      root.liveValue = root.value
    }

    // Do not consume or translate scroll gestures into value changes. Marking
    // the event unaccepted lets the enclosing Flickable continue scrolling.
    onWheel: function(wheel) {
      wheel.accepted = false
    }
  }
}
