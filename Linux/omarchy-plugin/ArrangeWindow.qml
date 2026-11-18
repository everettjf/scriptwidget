import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons as Commons

// Arrange mode, one per screen: a window over the whole screen that shows the
// widgets of that screen and lets each be dragged, with a menu on right
// click. It takes the pointer only on the pictures, and on the whole screen
// while a button is held, so a fast drag cannot leave it: Hyprland stops
// sending pointer motion to a small surface once the pointer is outside it
// when no window has the keyboard, which is the usual state of an empty
// desktop.
PanelWindow {
  id: canvas

  required property var modelData
  required property var service
  property bool held: false

  screen: modelData
  visible: service.canvasShown
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "scriptwidget-arrange"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  WlrLayershell.layer: service.peek ? WlrLayer.Overlay : WlrLayer.Bottom

  mask: held ? null : pictures

  Region {
    id: pictures
    regions: canvas.pictureRegions
  }

  property list<Region> pictureRegions

  function collectRegions() {
    var found = []
    for (var index = 0; index < regionMaker.count; index++) {
      var region = regionMaker.objectAt(index)
      if (region) found.push(region)
    }
    pictureRegions = found
  }

  // Nothing is built, and no picture loaded, while the window is not shown.
  readonly property var ids: !visible ? [] : service.ids.filter(function (id) {
    var screen = canvas.service.screenFor(canvas.service.widgets[id] ? canvas.service.widgets[id].screen : "")
    return !!screen && screen.name === canvas.modelData.name
  })

  Instantiator {
    id: regionMaker
    model: canvas.ids
    delegate: Region {
      required property string modelData
      readonly property var widget: canvas.service.widgets[modelData] || canvas.service.noWidget
      x: widget.x
      y: widget.y
      width: widget.width
      height: widget.height
    }
    onObjectAdded: canvas.collectRegions()
    onObjectRemoved: canvas.collectRegions()
  }

  Repeater {
    model: canvas.ids

    Item {
      id: picture

      required property string modelData
      readonly property var widget: canvas.service.widgets[modelData] || canvas.service.noWidget

      // Where the picture is drawn relative to the place the service last
      // named, during a drag and until the service answers it.
      property real offsetX: 0
      property real offsetY: 0
      property real knownX: 0
      property real knownY: 0

      x: widget.x + offsetX
      y: widget.y + offsetY
      z: pointer.pressed ? 1 : 0
      width: widget.width
      height: widget.height

      onWidgetChanged: {
        if (pointer.moved) return
        if (widget.x !== knownX || widget.y !== knownY) {
          offsetX = 0
          offsetY = 0
          unanswered.stop()
        }
        knownX = widget.x
        knownY = widget.y
      }

      // The service answers a move with the widget's new place. If it does
      // not, the picture goes back to where the service has it.
      Timer {
        id: unanswered
        interval: 3000
        onTriggered: { picture.offsetX = 0; picture.offsetY = 0 }
      }

      Image {
        anchors.fill: parent
        source: canvas.service.imageUrl(picture.widget.image, picture.widget.stamp)
      }

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: Math.min(width, height) * 0.13
        border.width: 2
        border.color: Commons.Color.accent
      }

      MouseArea {
        id: pointer

        property real startX: 0
        property real startY: 0
        property real startOffsetX: 0
        property real startOffsetY: 0
        property bool moved: false

        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.SizeAllCursor

        onPressed: function (mouse) {
          if (mouse.button !== Qt.LeftButton) return
          var at = mapToItem(null, mouse.x, mouse.y)
          startX = at.x
          startY = at.y
          startOffsetX = picture.offsetX
          startOffsetY = picture.offsetY
          moved = false
          canvas.held = true
          canvas.service.refreshKeepOut()
        }

        onPositionChanged: function (mouse) {
          if (!(mouse.buttons & Qt.LeftButton)) return
          var at = mapToItem(null, mouse.x, mouse.y)
          if (!moved && Math.abs(at.x - startX) + Math.abs(at.y - startY) < 6) return
          moved = true
          picture.offsetX = startOffsetX + at.x - startX
          picture.offsetY = startOffsetY + at.y - startY
        }

        onReleased: function (mouse) {
          var widget = picture.widget
          if (mouse.button === Qt.RightButton) {
            var at = mapToItem(null, mouse.x, mouse.y)
            canvas.service.openMenu(picture.modelData, canvas.modelData, at.x, at.y)
            return
          }
          canvas.held = false
          if (!moved) return
          moved = false
          var placed = canvas.service.place(picture.modelData, canvas.modelData, picture.x, picture.y, widget.width, widget.height)
          if (placed.screen === canvas.modelData.name) {
            picture.offsetX = placed.x - widget.x
            picture.offsetY = placed.y - widget.y
          }
          unanswered.restart()
        }

        onCanceled: {
          canvas.held = false
          moved = false
          unanswered.restart()
        }
      }
    }
  }
}
