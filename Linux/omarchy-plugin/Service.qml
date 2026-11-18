import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons as Commons

// The display end of ScriptWidget on Omarchy. It runs `scriptwidget watch`,
// shows the pictures that command names on the desktop layer, and passes
// clicks and drags back as `scriptwidget tap`, `move`, `menu`, `screen` and
// `theme`. The protocol is section 4.8 of docs/linux/plan.md.
//
// This code runs unsandboxed inside the Omarchy shell, so it does as little
// as it can: it never reads a package, every command is an argument vector
// (no shell string is ever built), and the only files it opens are PNG
// pictures inside the frames directory of the background service.
Item {
  id: root

  // Filled in by the shell.
  property var shell: null
  property var manifest: null

  readonly property int protocol: 1

  // Development overrides, read from the environment of the shell process.
  readonly property string program: Quickshell.env("SCRIPTWIDGET_PLUGIN_BIN") || "scriptwidget"
  readonly property string studioProgram: Quickshell.env("SCRIPTWIDGET_PLUGIN_STUDIO_BIN") || "scriptwidget-studio"
  readonly property string framesDirectory: {
    var named = String(Quickshell.env("SCRIPTWIDGET_PLUGIN_FRAMES") || "")
    if (named === "") {
      var runtime = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
      named = runtime === "" ? "" : runtime + "/scriptwidget/frames"
    }
    named = named.replace(/\/+$/, "")
    return named.charAt(0) === "/" ? named : ""
  }

  // "starting", "running", "stopped" (installed, no service), "missing" (the
  // program could not be started) or "outdated" (another protocol version).
  property string status: "starting"
  property bool arrange: false
  property bool peek: false

  // Arrange mode hands the pictures over from the widget windows to
  // ArrangeWindow and back. For a moment both show the same picture in the
  // same place, so nothing blinks: `canvasShown` turns on first and off last,
  // `arranging` (the widget windows are hidden) the other way round.
  property bool canvasShown: false
  property bool arranging: false
  readonly property bool dark: {
    var color = Commons.Color.background
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b < 0.5
  }

  // Widget ids in the order they arrived, and the checked copy of the last
  // `widget` event of each.
  property var ids: []
  property var widgets: ({})
  readonly property var noWidget: ({ id: "", screen: "", x: 0, y: 0, width: 0, height: 0, image: "", version: 0, stamp: "", regions: [], frames: [] })

  // Counts connections, so a picture path that comes back with the same
  // version after the service restarted is not answered from Qt's cache. A
  // widget keeps the count it arrived with: its picture is not loaded again
  // when the service reconnects, only when the service names it again.
  property int epoch: 0
  property bool greeted: false
  // About the current run of `watch`: whether it started at all, and whether
  // it spoke another protocol version.
  property bool started: false
  property bool refused: false
  property var announced: ({})
  property var reportedScreens: ({})
  property int retryDelay: 2000

  // Layers the widgets should stay out of, by screen name, in screen
  // coordinates: the Omarchy dock while it is shown.
  property var keepOut: ({})

  property string menuWidget: ""
  property var menuScreen: null
  property real menuX: 0
  property real menuY: 0

  readonly property var limits: ({ widgets: 64, regions: 256, frames: 60, side: 8192, line: 262144 })
  readonly property var menuWords: ["resize-small", "resize-medium", "resize-large", "resize-extraLarge", "edit", "refresh", "remove"]

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // ---------------------------------------------------------------- checks

  function validId(value) {
    return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value)
  }

  function whole(value, low, high) {
    var number = Number(value)
    if (typeof value !== "number" || !isFinite(number)) return null
    number = Math.round(number)
    return number < low || number > high ? null : number
  }

  // A picture is accepted only when it is a .png inside the frames directory,
  // named with plain path components. Anything else is ignored.
  function framePath(value) {
    if (typeof value !== "string" || framesDirectory === "" || value.length > 4096) return ""
    var prefix = framesDirectory + "/"
    if (value.indexOf(prefix) !== 0 || !/\.png$/.test(value)) return ""
    var parts = value.substring(prefix.length).split("/")
    for (var index = 0; index < parts.length; index++) {
      if (!/^[A-Za-z0-9._-]+$/.test(parts[index]) || /^\.+$/.test(parts[index])) return ""
    }
    return value
  }

  // The query only keeps Qt from answering with a picture it loaded earlier
  // from the same path; `stamp` is the connection count and the version.
  function imageUrl(path, stamp) {
    return path === "" ? "" : "file://" + path + "?v=" + stamp
  }

  function checkedWidget(event) {
    if (!validId(event.id)) return null
    var width = whole(event.width, 1, limits.side), height = whole(event.height, 1, limits.side)
    var x = whole(event.x, -65536, 65536), y = whole(event.y, -65536, 65536)
    var version = whole(event.version, 0, 9007199254740991)
    var image = framePath(event.image)
    if (width === null || height === null || x === null || y === null || version === null || image === "") return null

    var regions = []
    var given = Array.isArray(event.regions) ? event.regions : []
    for (var index = 0; index < given.length && regions.length < limits.regions; index++) {
      var region = given[index]
      if (!region || typeof region !== "object") continue
      var n = whole(region.n, 0, 2147483647)
      var left = whole(region.x, -limits.side, limits.side), top = whole(region.y, -limits.side, limits.side)
      var across = whole(region.width, 1, limits.side), down = whole(region.height, 1, limits.side)
      if (n === null || left === null || top === null || across === null || down === null) continue
      regions.push({ n: n, x: left, y: top, width: across, height: down })
    }

    // One bad frame turns the animation off; the first picture still shows.
    var frames = []
    var steps = Array.isArray(event.frames) ? event.frames : []
    if (steps.length > 1 && steps.length <= limits.frames) {
      for (var step = 0; step < steps.length; step++) {
        var path = steps[step] && typeof steps[step] === "object" ? framePath(steps[step].image) : ""
        var ms = steps[step] && typeof steps[step] === "object" ? whole(steps[step].ms, 0, 600000) : null
        if (path === "" || ms === null) { frames = []; break }
        frames.push({ image: path, ms: Math.max(20, ms) })
      }
    }

    return {
      id: event.id, screen: typeof event.screen === "string" ? event.screen.substring(0, 128) : "",
      x: x, y: y, width: width, height: height, image: image, version: version, stamp: epoch + "." + version,
      regions: regions, frames: frames
    }
  }

  // --------------------------------------------------------------- protocol

  function handle(line) {
    if (line.length === 0 || line.length > limits.line) return
    var event
    try { event = JSON.parse(line) } catch (error) { return }
    if (!event || typeof event !== "object" || typeof event.event !== "string") return

    if (!greeted) {
      if (event.event !== "hello" || refused) return
      if (event.protocol !== protocol) {
        // Another version: show nothing, and wait for an update.
        refused = true
        status = "outdated"
        dropAll()
        return
      }
      greeted = true
      epoch += 1
      retryDelay = 2000
      arrange = event.arrange === true
      peek = event.peek === true
      status = "running"
      // The service names every widget again after hello. What it has not
      // named a moment later is gone.
      announced = ({})
      sweep.restart()
      reportedScreens = ({})
      for (var index = 0; index < screenReports.instances.length; index++) screenReports.instances[index].send()
      monitorsSoon.restart()
      reportTheme()
      return
    }

    if (event.event === "widget") {
      var widget = checkedWidget(event)
      if (!widget) return
      if (ids.indexOf(widget.id) < 0) {
        if (ids.length >= limits.widgets) return
        ids = ids.concat([widget.id])
      }
      var next = Object.assign({}, widgets)
      next[widget.id] = widget
      widgets = next
      announced[widget.id] = true
    } else if (event.event === "remove") {
      if (validId(event.id)) drop([event.id])
    } else if (event.event === "mode") {
      var arranging = arrange
      arrange = event.arrange === true
      peek = event.peek === true
      // A menu opened in arrange mode goes with it; one opened outside it stays.
      if (arranging && !arrange) closeMenu()
    } else if (event.event === "bye") {
      // The pictures stay; the retry below finds the service again.
      greeted = false
      status = "stopped"
      closeMenu()
    }
  }

  function drop(gone) {
    var left = ids.filter(function (id) { return gone.indexOf(id) < 0 })
    if (left.length === ids.length) return
    ids = left
    var next = ({})
    for (var index = 0; index < left.length; index++) next[left[index]] = widgets[left[index]]
    widgets = next
    if (gone.indexOf(menuWidget) >= 0) closeMenu()
  }

  function dropAll() {
    ids = []
    widgets = ({})
    closeMenu()
  }

  function watchEnded() {
    greeted = false
    sweep.stop()
    closeMenu()
    if (!started) status = "missing"
    else if (!refused) status = "stopped"
    retry.interval = retryDelay
    retry.restart()
    retryDelay = Math.min(30000, retryDelay * 2)
  }

  // Commands of the display protocol. They mean nothing without the service.
  function send(words) {
    if (status !== "running") return
    Quickshell.execDetached([program].concat(words.map(String)))
  }

  function tap(id, n) { send(["tap", id, n]) }
  function togglePeek() { send(["peek"]) }
  function toggleArrange() { send(["arrange"]) }
  function openStudio() { Quickshell.execDetached([studioProgram]) }

  function reportTheme() { send(["theme", dark ? "dark" : "light"]) }
  onDarkChanged: reportTheme()

  function reportScreen(name, scale, width, height) {
    if (status !== "running" || name === "" || !(width > 0) || !(height > 0)) return
    var figures = [String(Math.round(scale * 10000) / 10000), String(width), String(height)]
    if (reportedScreens[name] === figures.join(" ")) return
    reportedScreens[name] = figures.join(" ")
    send(["screen", name].concat(figures))
  }

  function screenFor(name) {
    var screens = Quickshell.screens
    for (var index = 0; index < screens.length; index++) if (screens[index].name === name) return screens[index]
    return screens.length > 0 ? screens[0] : null
  }

  // --------------------------------------------------------------- arranging

  readonly property int snapDistance: 24
  readonly property int edgeInset: 16

  // The part of a screen a widget may be dropped on: not under the bar and
  // not under the dock.
  function usableArea(screen) {
    var area = { left: 0, top: 0, right: screen.width, bottom: screen.height }
    var bar = shell ? shell.bar : null
    if (bar && !bar.barHidden) {
      var thickness = typeof bar.barSizeFor === "function" ? bar.barSizeFor(screen.name) : Number(bar.barSize) || 0
      if (bar.position === "top") area.top += thickness
      else if (bar.position === "bottom") area.bottom -= thickness
      else if (bar.position === "left") area.left += thickness
      else if (bar.position === "right") area.right -= thickness
    }
    var strips = keepOut[screen.name] || []
    for (var index = 0; index < strips.length; index++) {
      var strip = strips[index]
      if (strip.width >= strip.height) {
        if (strip.y + strip.height / 2 < screen.height / 2) area.top = Math.max(area.top, strip.y + strip.height)
        else area.bottom = Math.min(area.bottom, strip.y)
      } else {
        if (strip.x + strip.width / 2 < screen.width / 2) area.left = Math.max(area.left, strip.x + strip.width)
        else area.right = Math.min(area.right, strip.x)
      }
    }
    return area
  }

  function settle(value, low, high) {
    if (high - low < 2 * edgeInset) return Math.round(low)
    if (value < low + edgeInset + snapDistance) return Math.round(low + edgeInset)
    if (value > high - edgeInset - snapDistance) return Math.round(high - edgeInset)
    return Math.round(value)
  }

  // The end of a drag: picks the screen under the middle of the widget, snaps
  // near the edges of its usable area, and tells the service.
  function place(id, from, x, y, width, height) {
    var screen = from
    var screens = Quickshell.screens
    var middleX = from.x + x + width / 2, middleY = from.y + y + height / 2
    for (var index = 0; index < screens.length; index++) {
      var other = screens[index]
      if (middleX >= other.x && middleX < other.x + other.width && middleY >= other.y && middleY < other.y + other.height) screen = other
    }
    x += from.x - screen.x
    y += from.y - screen.y
    var area = usableArea(screen)
    var placed = { screen: screen.name, x: settle(x, area.left, area.right - width), y: settle(y, area.top, area.bottom - height) }
    send(["move", id, placed.screen, placed.x, placed.y])
    return placed
  }

  function refreshKeepOut() { if (!layers.running) layers.running = true }

  onArrangeChanged: {
    if (arrange) {
      canvasShown = true
      refreshKeepOut()
    } else {
      arranging = false
    }
    handover.restart()
  }

  function readLayers(text) {
    var found = ({})
    try {
      var monitors = JSON.parse(text)
      for (var name in monitors) {
        var screen = screenFor(name)
        if (!screen || screen.name !== name) continue
        var levels = monitors[name].levels || ({})
        for (var level in levels) {
          for (var index = 0; index < levels[level].length; index++) {
            var layer = levels[level][index]
            if (layer.namespace !== "omarchy-dock" || !(layer.w > 0) || !(layer.h > 0)) continue
            if (!found[name]) found[name] = []
            found[name].push({ x: layer.x - screen.x, y: layer.y - screen.y, width: layer.w, height: layer.h })
          }
        }
      }
    } catch (error) { found = ({}) }
    keepOut = found
  }

  function openMenu(id, screen, x, y) {
    if (!widgets[id]) return
    menuScreen = screen
    menuX = x
    menuY = y
    menuWidget = id
  }

  function closeMenu() { menuWidget = "" }

  function choose(word) {
    var id = menuWidget
    closeMenu()
    if (menuWords.indexOf(word) >= 0 && widgets[id]) send(["menu", id, word])
  }

  // ------------------------------------------------------------------ parts

  function connect() {
    if (watch.running) return
    started = false
    refused = false
    watch.running = true
  }

  Component.onCompleted: connect()

  Process {
    id: watch
    command: [root.program, "watch"]
    stdout: SplitParser { onRead: function (line) { root.handle(line) } }
    onStarted: root.started = true
    onRunningChanged: if (!running) root.watchEnded()
  }

  Timer {
    id: retry
    onTriggered: root.connect()
  }

  Timer {
    id: handover
    interval: 150
    onTriggered: {
      if (root.arrange) root.arranging = true
      else root.canvasShown = false
    }
  }

  Timer {
    id: sweep
    // A widget whose script is still running after a service restart has no
    // picture yet and is named late: wait longer than a script may take.
    interval: 12000
    onTriggered: root.drop(root.ids.filter(function (id) { return !root.announced[id] }))
  }

  // Asks the compositor where the dock is. Read-only, and its answer is only
  // used to keep widgets from being dropped under it.
  Process {
    id: layers
    command: ["hyprctl", "-j", "layers"]
    stdout: StdioCollector { onStreamFinished: root.readLayers(text) }
  }

  // The compositor's own word on each monitor. The shell's screen objects
  // above did not follow a scale change made while the shell was running, and
  // a widget was then drawn at the old scale and looked blurred. Read at
  // start, after every reconnect, when the compositor says a monitor or its
  // configuration changed, and now and then in case it did not say.
  function readMonitors(text) {
    var list
    try { list = JSON.parse(text) } catch (error) { return }
    if (!Array.isArray(list)) return
    for (var index = 0; index < list.length && index < 16; index++) {
      var monitor = list[index]
      if (!monitor || typeof monitor.name !== "string" || monitor.disabled === true || !(monitor.scale > 0)) continue
      var turned = monitor.transform % 2 === 1
      var width = Math.round((turned ? monitor.height : monitor.width) / monitor.scale)
      var height = Math.round((turned ? monitor.width : monitor.height) / monitor.scale)
      reportScreen(monitor.name, monitor.scale, width, height)
    }
  }
  function askMonitors() { if (status === "running" && !monitors.running) monitors.running = true }
  Process {
    id: monitors
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector { onStreamFinished: root.readMonitors(text) }
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) { if (/monitor|configreloaded/.test(event.name)) monitorsSoon.restart() }
  }
  Timer { id: monitorsSoon; interval: 500; onTriggered: root.askMonitors() }
  Timer { interval: 30000; repeat: true; running: root.status === "running"; onTriggered: root.askMonitors() }

  Variants {
    id: screenReports
    model: Quickshell.screens

    QtObject {
      required property var modelData
      readonly property var monitor: Hyprland.monitorFor(modelData)
      readonly property real scale: monitor && monitor.scale > 0 ? monitor.scale : modelData.devicePixelRatio
      readonly property string figures: modelData.name + " " + scale + " " + modelData.width + " " + modelData.height
      // These figures only say that something changed; they can be the ones
      // from before the change. What is reported is what the compositor says.
      function send() { monitorsSoon.restart() }
      onFiguresChanged: send()
    }
  }

  Variants {
    id: windows
    model: root.ids

    WidgetWindow { service: root }
  }

  Variants {
    model: Quickshell.screens

    ArrangeWindow { service: root }
  }

  // `omarchy-shell com.atomsprout.scriptwidget status`: what the display end
  // is doing, for `scriptwidget doctor` and the tests. Read-only.
  IpcHandler {
    target: "com.atomsprout.scriptwidget"

    function status(): string {
      var animating = 0
      for (var index = 0; index < windows.instances.length; index++) if (windows.instances[index].animating) animating += 1
      return JSON.stringify({
        protocol: root.protocol, status: root.status, arrange: root.arrange, peek: root.peek, dark: root.dark,
        widgets: root.ids.length, animating: animating, menu: root.menuWidget !== ""
      })
    }
  }

  // The menu of a widget, opened by a right click on it (in arrange mode or
  // not): one window over the whole screen, so a click anywhere else closes it.
  PanelWindow {
    id: menu

    visible: root.menuWidget !== ""
    screen: root.menuScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "scriptwidget-menu"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.layer: WlrLayer.Overlay

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onPressed: root.closeMenu()
    }

    Rectangle {
      id: card
      x: Math.max(0, Math.min(root.menuX, menu.width - width))
      y: Math.max(0, Math.min(root.menuY, menu.height - height))
      width: Commons.Style.space(180)
      height: rows.implicitHeight + 2 * Commons.Style.spacing.sm
      radius: Commons.Style.cornerRadius
      color: Commons.Color.popups.background
      border.color: Commons.Color.popups.border
      border.width: 1

      MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

      Column {
        id: rows
        x: Commons.Style.spacing.sm
        y: Commons.Style.spacing.sm
        width: parent.width - 2 * x

        Repeater {
          model: root.menuWords

          Rectangle {
            id: row
            required property string modelData
            width: rows.width
            height: Commons.Style.spacing.popupRowHeight
            radius: Math.max(0, card.radius - Commons.Style.spacing.sm)
            color: hover.containsMouse ? Commons.Style.hoverFill : "transparent"

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: Commons.Style.spacing.controlPaddingX
              width: parent.width - 2 * x
              textFormat: Text.PlainText
              text: strings.t("menu." + row.modelData)
              color: row.modelData === "remove" ? Commons.Color.urgent : Commons.Color.popups.text
              font.family: Commons.Style.font.family
              font.pixelSize: Commons.Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.choose(row.modelData)
            }
          }
        }

        // Not a word for the service: switches arrange mode, where widgets are dragged.
        Rectangle {
          id: arrangeRow
          width: rows.width
          height: Commons.Style.spacing.popupRowHeight
          radius: Math.max(0, card.radius - Commons.Style.spacing.sm)
          color: arrangeHover.containsMouse ? Commons.Style.hoverFill : "transparent"

          Text {
            anchors.verticalCenter: parent.verticalCenter
            x: Commons.Style.spacing.controlPaddingX
            width: parent.width - 2 * x
            textFormat: Text.PlainText
            text: strings.t(root.arrange ? "menu.arrange.done" : "menu.arrange")
            color: Commons.Color.popups.text
            font.family: Commons.Style.font.family
            font.pixelSize: Commons.Style.font.body
            elide: Text.ElideRight
          }

          MouseArea {
            id: arrangeHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.closeMenu(); root.toggleArrange() }
          }
        }
      }
    }
  }
}
