import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// One widget: a picture on the desktop layer. Only its tap regions take the
// pointer; everywhere else a click goes to whatever is below. While widgets
// are being arranged, ArrangeWindow shows the pictures instead.
PanelWindow {
  id: panel

  required property string modelData
  required property var service

  readonly property var widget: service.widgets[modelData] || service.noWidget
  readonly property var frames: widget.frames
  property int frame: 0

  // The only cheap sign that a widget cannot be seen: a fullscreen window on
  // the workspace in front of it.
  readonly property var monitor: Hyprland.monitorFor(screen)
  readonly property bool covered: !service.peek && !!monitor && !!monitor.activeWorkspace && monitor.activeWorkspace.hasFullscreen === true
  // Without the service the frame files may be gone, so the frame on show stays.
  readonly property bool animating: visible && frames.length > 1 && !covered && service.status === "running"

  screen: service.screenFor(widget.screen)
  visible: widget.width > 0 && !service.arranging && !moving
  // When the display a widget is on goes away, its window goes with it and
  // does not come up on the display it is given next. Hiding it for a moment
  // and showing it again does bring it up there.
  property bool moving: false
  // The trigger is the set of displays changing, not this window's own
  // "screen changed": the shell reports that one also while it is showing the
  // window, and reacting to it hid the window again. With a display added or
  // removed, every widget window is shown again, also one that stays where it is.
  Connections {
    target: Quickshell
    function onScreensChanged() { if (!panel.moving) { panel.moving = true; remap.restart() } }
  }
  Timer { id: remap; interval: 200; onTriggered: panel.moving = false }
  anchors { top: true; left: true }
  margins { left: widget.x; top: widget.y }
  implicitWidth: Math.max(1, widget.width)
  implicitHeight: Math.max(1, widget.height)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "scriptwidget"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Arrange mode hides these windows and the service turns "on top" on for
  // its duration. A window that was told to change layer around the time it
  // was hidden came back on the wrong layer, and stayed there. So "on top"
  // only counts outside arrange mode (the arrange canvas has its own layer),
  // the layer is only set while the window is shown, and it is set once more
  // a moment after the window is shown again.
  property int shownLayer: WlrLayer.Bottom
  function syncLayer() {
    if (visible && !service.arrange && !service.arranging) shownLayer = service.peek ? WlrLayer.Overlay : WlrLayer.Bottom
  }
  WlrLayershell.layer: shownLayer
  onVisibleChanged: layerSync.restart()
  Component.onCompleted: syncLayer()
  Connections {
    target: service
    // Later, so that "arrange" from the same event is already in place.
    function onPeekChanged() { Qt.callLater(panel.syncLayer) }
    function onArrangeChanged() { layerSync.restart() }
  }
  Timer { id: layerSync; interval: 350; onTriggered: panel.syncLayer() }

  // The whole widget takes the pointer: a left click on a tap region is a tap,
  // and a right click anywhere on it opens the widget's menu. (Earlier only
  // the tap regions took input and the menu existed in arrange mode alone,
  // which made a widget look as if it ignored the mouse.)

  onFramesChanged: if (frame >= frames.length) frame = 0

  Timer {
    interval: panel.frames.length > 0 ? panel.frames[panel.frame % panel.frames.length].ms : 1000
    running: panel.animating
    repeat: true
    onTriggered: panel.frame = (panel.frame + 1) % panel.frames.length
  }

  Image {
    anchors.fill: parent
    source: panel.service.imageUrl(panel.frames.length > 1 ? panel.frames[panel.frame % panel.frames.length].image : panel.widget.image, panel.widget.stamp)
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: true
    cursorShape: overRegion ? Qt.PointingHandCursor : Qt.ArrowCursor

    property bool overRegion: false

    // The tap region at a point, or null. Where regions overlap, the one named last is on top.
    function regionAt(x, y) {
      var regions = panel.widget.regions
      for (var index = regions.length - 1; index >= 0; index--) {
        var region = regions[index]
        if (x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height) return region
      }
      return null
    }

    onPositionChanged: function (mouse) { overRegion = regionAt(mouse.x, mouse.y) !== null }
    onExited: overRegion = false

    onClicked: function (mouse) {
      if (mouse.button === Qt.RightButton) {
        panel.service.openMenu(panel.modelData, panel.screen, panel.widget.x + mouse.x, panel.widget.y + mouse.y)
        return
      }
      var region = regionAt(mouse.x, mouse.y)
      if (region) panel.service.tap(panel.modelData, region.n)
    }
  }
}
