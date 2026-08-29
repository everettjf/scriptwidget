import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

// Large desktop clock rendered on the bottom layer, behind every app window
// but above the wallpaper. All settings live in config.json, which the
// shell's "OmaClock" bar widget reads and writes through the API below.
// Hot-reloads when config.json is edited.
Item {
  id: root

  // Bundled fonts (OFL) so no system install is needed. Inter is the default;
  // Plus Jakarta Sans is an opt-in family via `fontFamily`.
  FontLoader {
    id: bundledFont
    source: Qt.resolvedUrl("fonts/InterVariable.ttf")
  }
  FontLoader {
    id: appleFont
    source: Qt.resolvedUrl("fonts/PlusJakartaSans-Variable.ttf")
  }

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omaclock/config.json"

  readonly property var defaults: ({
    format: "h:mm",
    showSeconds: false,
    fontFamily: "",
    fontWeight: 200,
    fontScale: 0.15,
    letterSpacing: -3,
    colorMode: "auto",
    colorRole: "bar.text",
    color: "",
    opacity: 0.92,
    position: "top",
    xRatio: null,
    yRatio: null,
    namespace: "ubeyidah.omaclock"
  })

  property var settings: root.defaults
  property string _lastRaw: ""
  property string _lastWritten: ""
  property bool _configApplied: false

  // Font resolution: "system" uses the platform default font (empty family),
  // an explicit name is used as-is, and empty falls back to bundled Inter
  // ("Inter Variable" is the family name the bundled file registers).
  readonly property string activeFont: root.settings.fontFamily === "system"
    ? ""
    : (root.settings.fontFamily ? root.settings.fontFamily : "Inter Variable")

  // `colorMode`:
  //   "auto"    follow the top bar's text color (theme- and wallpaper-aware)
  //   "theme"   pick one of the theme palette roles via `colorRole`
  //   "custom"  use the explicit CSS color in `color`
  // A legacy config with a non-empty `color` but no `colorMode` acts as custom.
  readonly property string colorRole: String(root.settings.colorRole || "bar.text")
  readonly property color activeColor: {
    var mode = String(root.settings.colorMode || "")
    var explicit = String(root.settings.color || "")
    if (mode === "custom" && explicit) return Qt.color(explicit)
    if (mode === "theme") return root.roleColor(root.colorRole)
    if (explicit) return Qt.color(explicit)
    return Color.bar.text
  }

  // Accept both JSON numbers and numeric strings ("0.3"), falling back when
  // the value is null/missing/garbage.
  function num(v, fallback) {
    if (v === null || v === undefined || v === "") return fallback
    var n = Number(v)
    return isNaN(n) ? fallback : n
  }

  readonly property real xRatio: root.num(root.settings.xRatio, 0.5)
  readonly property real yRatio: !isNaN(Number(root.settings.yRatio)) && root.settings.yRatio !== null && root.settings.yRatio !== ""
    ? Number(root.settings.yRatio)
    : (root.settings.position === "top" ? 0.20
      : root.settings.position === "bottom" ? 0.86 : 0.5)
  readonly property real clockScale: root.num(root.settings.fontScale, 0.15)
  readonly property real clockOpacity: root.num(root.settings.opacity, 0.92)

  function applyRaw(raw) {
    if (!raw || String(raw).trim().length === 0) {
      root._configApplied = true
      return
    }
    if (raw === root._lastRaw || raw === root._lastWritten) {
      root._configApplied = true
      return
    }
    root._lastRaw = raw
    try {
      var parsed = JSON.parse(raw)
      var merged = {}
      for (var k in root.defaults) merged[k] = root.defaults[k]
      for (var p in parsed) if (parsed.hasOwnProperty(p)) merged[p] = parsed[p]
      root.settings = merged
      root._configApplied = true
    } catch (e) {
      root._configApplied = true
    }
  }

  // This Qt build only emits 12-hour (1-12) when an AP token is present,
  // otherwise `h` falls back to 24-hour. So for a 12-hour format without
  // AM/PM we render with AP and strip the suffix. A single-digit hour is
  // zero-padded so the prefix stays stable across minute ticks.
  function clockString(date, fmt) {
    if (/h/i.test(fmt) && !/AP/i.test(fmt)) {
      var s = Qt.formatDateTime(date, fmt + " AP").replace(/\s*(AM|PM)$/i, "").trim()
      return s.replace(/^(\d)(?=:)/, "0$1")
    }
    return Qt.formatDateTime(date, fmt)
  }

  function roleColor(role) {
    switch (String(role || "")) {
    case "bar.text": return Color.bar.text
    case "popups.text": return Color.popups.text
    case "foreground": return Color.foreground
    case "background": return Color.background
    case "accent": return Color.accent
    case "urgent": return Color.urgent
    case "muted": return Color.muted
    default: return Color.bar.text
    }
  }

  // Every mutation reassigns `settings` wholesale so the clock's bindings —
  // which read through `root.settings.*` — re-evaluate immediately.
  function setField(key, value) {
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = value
    root.settings = next
  }

  function setColor(mode, role, custom) {
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next.colorMode = mode
    if (role !== undefined && role !== null) next.colorRole = role
    if (custom !== undefined && custom !== null) next.color = custom
    root.settings = next
  }

  function resetLayout() {
    root.setField("xRatio", root.num(root.defaults.xRatio, 0.5))
    root.setField("yRatio", root.num(root.defaults.yRatio, 0.5))
    root.setField("fontScale", root.num(root.defaults.fontScale, 0.15))
    root.setField("opacity", root.num(root.defaults.opacity, 0.92))
    root.saveConfig()
  }

  function saveConfig() {
    if (saveProc.running) {
      saveProc.pending = true
      return
    }
    var s = root.settings
    var json = JSON.stringify({
      "format": s.format,
      "showSeconds": s.showSeconds,
      "fontFamily": s.fontFamily,
      "fontWeight": s.fontWeight,
      "fontScale": Number(root.num(s.fontScale, 0.15).toFixed(4)),
      "letterSpacing": s.letterSpacing,
      "colorMode": String(s.colorMode || "auto"),
      "colorRole": String(s.colorRole || "bar.text"),
      "color": String(s.color || ""),
      "opacity": Number(root.num(s.opacity, 0.92).toFixed(2)),
      "position": s.position,
      "xRatio": Number(root.xRatio.toFixed(4)),
      "yRatio": Number(root.yRatio.toFixed(4)),
      "namespace": s.namespace
    }, null, 2)
    root._lastWritten = json
    // Write through a heredoc (delimiter quoted so nothing is expanded) and
    // NOT via stdin: stdin is never closed by Quickshell, so `cat` would
    // block forever and `saveProc.running` would stay true, silently
    // dropping every later save.
    saveProc.command = ["sh", "-c", "mkdir -p '" + Quickshell.env("HOME") + "/.config/omaclock' && cat > '" + root.configPath + "' <<'OMACLOCK_SAVE_EOF'\n" + json + "\nOMACLOCK_SAVE_EOF"]
    saveProc.running = true
  }

  Process {
    id: cfgProc
    command: ["cat", root.configPath]
    stdout: StdioCollector { onStreamFinished: root.applyRaw(text) }
    Component.onCompleted: running = true
  }

  // Fast startup retry so the clock's position is known quickly even if the
  // initial read races shell boot; the 2s poll below keeps external edits
  // (via the symlink) applied while running.
  Timer {
    interval: 150
    repeat: true
    running: !root._configApplied
    onTriggered: if (!cfgProc.running && !saveProc.running) cfgProc.running = true
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: if (!cfgProc.running && !saveProc.running) cfgProc.running = true
  }

  Process {
    id: saveProc
    property bool pending: false
    onExited: if (saveProc.pending) {
      saveProc.pending = false
      Qt.callLater(function() { root.saveConfig() })
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: true
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      updatesEnabled: true
      // Empty input region: without this, some Quickshell versions (0.3.x)
      // let the fullscreen surface capture mouse input, breaking desktop
      // interactions like Omarchy's double-click wallpaper switcher.
      mask: Region {}

      WlrLayershell.namespace: root.settings.namespace
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Item {
        id: surface
        anchors.fill: parent

        // Binding tracks clock.date directly, so format changes from
        // config hot-reload re-evaluate immediately (an imperative
        // onDateChanged assignment here would break this binding).
        Text {
          id: clockText
          visible: root._configApplied
          color: root.activeColor
          opacity: Math.min(1, Math.max(0, root.clockOpacity))
          font.family: root.activeFont
          font.weight: root.settings.fontWeight
          font.pixelSize: Math.max(8, Math.round(surface.height * root.clockScale))
          font.letterSpacing: root.settings.letterSpacing
          text: root.clockString(clock.date, root.settings.format)

          x: surface.width * root.xRatio - width / 2
          y: surface.height * root.yRatio - height / 2
        }

        SystemClock {
          id: clock
          precision: root.settings.showSeconds ? SystemClock.Seconds : SystemClock.Minutes
        }
      }
    }
  }
}
