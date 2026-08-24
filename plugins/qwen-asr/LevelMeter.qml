import QtQuick
import qs.Commons

// Segmented symmetrical acoustic waveform visualizer.
//
// Uses fixed 9 bars with acoustic center-weighting and outward ripple propagation.
// Guarantees constant implicitWidth so container surfaces never oscillate or jitter.
Item {
  id: root

  property var levels: []
  property int count: 9
  property int barWidth: 3
  property int barGap: 2
  property int maxHeight: 18
  property int minHeight: 3
  property color color: Color.foreground
  property color hotColor: Color.urgent
  property real hotThreshold: 0.82
  property real radius: barWidth / 2

  // Fixed constant width -- never fluctuates or triggers surface reallocations
  implicitWidth: count * (barWidth + barGap) - barGap
  implicitHeight: maxHeight

  // Acoustic bell-curve weighting for symmetrical dynamic wave
  readonly property var weights: [0.40, 0.60, 0.82, 0.95, 1.0, 0.95, 0.82, 0.60, 0.40]

  Row {
    anchors.centerIn: parent
    spacing: root.barGap

    Repeater {
      model: root.count

      delegate: Rectangle {
        required property int index
        width: root.barWidth
        radius: root.radius
        anchors.verticalCenter: parent.verticalCenter

        // Sample rolling history with outward ripple from the center
        readonly property real rawSample: {
          if (!root.levels || root.levels.length === 0) return 0
          var len = root.levels.length
          var center = Math.floor(root.count / 2)
          var dist = Math.abs(index - center)
          var idx = Math.max(0, len - 1 - dist)
          return Number(root.levels[idx]) || 0
        }

        readonly property real weight: (index < root.weights.length) ? root.weights[index] : 1.0
        readonly property real dynamicHeight: {
          var h = root.minHeight + rawSample * weight * (root.maxHeight - root.minHeight)
          return Math.max(root.minHeight, Math.min(root.maxHeight, Math.round(h)))
        }

        height: dynamicHeight
        color: rawSample >= root.hotThreshold ? root.hotColor : root.color

        Behavior on height {
          NumberAnimation {
            duration: 45
            easing.type: Easing.OutQuad
          }
        }

        Behavior on color {
          ColorAnimation { duration: 100 }
        }
      }
    }
  }
}
