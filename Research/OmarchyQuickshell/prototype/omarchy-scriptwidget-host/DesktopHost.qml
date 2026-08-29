import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons

// Phase-0 compositor smoke test. This intentionally executes no widget code.
Item {
  id: root

  readonly property var cards: [
    { title: "SCRIPTWIDGET", value: "OMARCHY", detail: "surface smoke test" },
    { title: "RUNTIME", value: "0.0.1", detail: "static fixture — no JS" },
    { title: "LAYER", value: "BOTTOM", detail: "click-through" }
  ]

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      visible: true
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      mask: Region {}

      WlrLayershell.namespace: "everettjf.scriptwidget-host-research"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Column {
        x: Math.round(parent.width * 0.035)
        y: Math.round(parent.height * 0.10)
        width: Math.max(260, Math.min(360, parent.width * 0.20))
        spacing: 12

        Repeater {
          model: root.cards

          Rectangle {
            required property var modelData
            width: parent.width
            height: 104
            radius: 16
            color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.88)
            border.width: 1
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)

            Column {
              anchors.fill: parent
              anchors.margins: 16
              spacing: 4

              Text {
                text: modelData.title
                color: Color.muted
                font.pixelSize: 11
                font.bold: true
                font.letterSpacing: 1.2
              }

              Text {
                text: modelData.value
                color: Color.foreground
                font.pixelSize: 26
                font.bold: true
              }

              Text {
                text: modelData.detail
                color: Color.muted
                font.pixelSize: 12
              }
            }
          }
        }
      }
    }
  }
}

