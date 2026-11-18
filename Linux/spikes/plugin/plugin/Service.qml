import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Phase 0 spike. A helper process prints one JSON event per line; this file
// only shows the pictures it names and passes clicks and drags back.
Item {
  id: root

  property var shell: null
  readonly property string here: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string control: Quickshell.env("XDG_RUNTIME_DIR") + "/scriptwidget-spike/ctl"

  property string mode: "desktop"
  property var ids: []
  property var widgets: ({})

  function handle(line) {
    var event
    try { event = JSON.parse(line) } catch (error) { console.warn("scriptwidget-spike: bad line", line); return }
    if (event.event === "widget") {
      var next = Object.assign({}, widgets)
      next[event.id] = event
      widgets = next
      if (ids.indexOf(event.id) < 0) ids = ids.concat([event.id])
    } else if (event.event === "remove") {
      ids = ids.filter(function (id) { return id !== event.id })
    } else if (event.event === "mode") {
      mode = event.mode
    }
  }

  // Arguments are passed as an argument vector, never through a shell string.
  function send(words) {
    Quickshell.execDetached(["sh", here + "send.sh", control].concat(words.map(String)))
  }

  Process {
    id: watch
    command: ["bash", root.here + "fake-watch.sh"]
    running: true
    stdout: SplitParser { onRead: function (line) { root.handle(line) } }
  }

  Variants {
    model: root.ids

    PanelWindow {
      id: panel
      required property string modelData
      readonly property var widget: root.widgets[modelData]
      property int frame: 0
      property real dragX: 0
      property real dragY: 0

      anchors { top: true; left: true }
      margins { left: widget.x + dragX; top: widget.y + dragY }
      implicitWidth: widget.width
      implicitHeight: widget.height
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "scriptwidget"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.layer: root.mode === "peek" ? WlrLayer.Overlay : WlrLayer.Bottom

      Image {
        anchors.fill: parent
        cache: false
        source: "file://" + panel.widget.frames[panel.frame % panel.widget.frames.length]
      }

      Timer {
        interval: panel.widget.delay || 1000
        running: panel.widget.frames.length > 1
        repeat: true
        onTriggered: panel.frame = (panel.frame + 1) % panel.widget.frames.length
      }

      MouseArea {
        anchors.fill: parent
        property real startX: 0
        property real startY: 0
        property bool moved: false
        onPressed: function (mouse) { startX = mouse.x; startY = mouse.y; moved = false }
        onPositionChanged: function (mouse) {
          // The window follows the pointer, so the pointer's position inside it
          // returns to the press point after each step.
          var dx = mouse.x - startX, dy = mouse.y - startY
          if (!moved && Math.abs(dx) + Math.abs(dy) < 6) return
          moved = true
          panel.dragX += dx
          panel.dragY += dy
        }
        onReleased: function (mouse) {
          if (moved) {
            root.send(["move", panel.modelData, Math.round(panel.widget.x + panel.dragX), Math.round(panel.widget.y + panel.dragY)])
            return
          }
          var taps = panel.widget.taps || []
          for (var index = 0; index < taps.length; index++) {
            var tap = taps[index]
            if (mouse.x >= tap.x && mouse.x < tap.x + tap.width && mouse.y >= tap.y && mouse.y < tap.y + tap.height) {
              root.send(["tap", panel.modelData, tap.n])
              return
            }
          }
        }
      }

      // The helper answers a move with the new position; the drag offset ends then.
      onWidgetChanged: { dragX = 0; dragY = 0 }
    }
  }
}
