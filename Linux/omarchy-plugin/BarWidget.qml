import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bar entry. Left click opens ScriptWidget; right click opens a card with
// the two switches. It only reads a few values off the service and calls
// three of its functions, so it also works next to an older or newer service
// (the service survives a plugin reload, this widget does not).
BarWidget {
  id: root

  readonly property string pluginId: "com.atomsprout.scriptwidget"
  property var service: null
  property bool popupOpen: false

  readonly property string status: service && typeof service.status === "string" ? service.status : "unavailable"
  readonly property bool running: status === "running"
  readonly property string statusText: running ? "" : strings.t("status." + status, strings.t("status.unavailable"))

  function findService() {
    service = bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor(pluginId) : null
  }

  function close() { popupOpen = false }

  onBarChanged: findService()
  Component.onCompleted: findService()

  // The service may be loaded after the bar, and is replaced when the plugin
  // is turned off and on.
  Timer {
    interval: 2000
    running: !root.service
    repeat: true
    onTriggered: root.findService()
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F056E}"
    dimmed: !root.running
    active: root.status === "outdated"
    tooltipText: root.running ? "ScriptWidget" : root.statusText

    onPressed: function (pressed) {
      if (pressed === Qt.RightButton) {
        root.popupOpen = !root.popupOpen
        return
      }
      // Without the service there is nothing to open; say why instead.
      if (root.running || root.status === "stopped") {
        if (root.service) root.service.openStudio()
        if (root.running) return
      }
      root.popupOpen = true
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "ScriptWidget"
        color: root.bar ? root.bar.foreground : Commons.Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: !root.running
        textFormat: Text.PlainText
        text: root.statusText
        color: root.status === "outdated" ? Commons.Color.urgent : (root.bar ? root.bar.foreground : Commons.Color.foreground)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Toggle {
        width: parent.width
        visible: root.running
        label: strings.t("bar.peek")
        description: strings.t("bar.peek.description")
        checked: !!root.service && root.service.peek === true
        onClicked: if (root.service) root.service.togglePeek()
      }

      Toggle {
        width: parent.width
        visible: root.running
        label: strings.t("bar.arrange")
        description: strings.t("bar.arrange.description")
        checked: !!root.service && root.service.arrange === true
        onClicked: if (root.service) root.service.toggleArrange()
      }
    }
  }
}
