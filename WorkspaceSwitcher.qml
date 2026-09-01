import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property int selectedIndex: 0
  property var workspaceRows: []

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color scrim: Color.menu.scrim

  readonly property int outerMargin: Style.space(40)
  readonly property int cardGap: Style.space(18)
  readonly property int cardWidth: Math.max(Style.space(180), Math.min(Style.space(300),
    (panel.width - outerMargin * 2 - cardGap * Math.max(0, Math.min(4, workspaceRows.length - 1)))
      / Math.max(1, Math.min(5, workspaceRows.length))))
  readonly property int previewHeight: Math.round(cardWidth * 0.625)
  readonly property int labelHeight: Style.space(42)

  function rowForWorkspace(workspace) {
    var monitor = workspace.monitor
    var windows = []
    var toplevels = workspace.toplevels.values

    for (var i = 0; i < toplevels.length; i++) {
      var window = toplevels[i]
      var ipc = window.lastIpcObject || ({})
      var at = ipc.at || [monitor ? monitor.x : 0, monitor ? monitor.y : 0]
      var size = ipc.size || [Style.space(300), Style.space(200)]
      windows.push({
        title: window.title || ipc.title || "Window",
        className: ipc.class || "App",
        x: at[0],
        y: at[1],
        width: size[0],
        height: size[1]
      })
    }

    return {
      id: workspace.id,
      name: workspace.name,
      workspace: workspace,
      focused: workspace.focused,
      monitorX: monitor ? monitor.x : 0,
      monitorY: monitor ? monitor.y : 0,
      monitorWidth: monitor ? monitor.width : panel.width,
      monitorHeight: monitor ? monitor.height : panel.height,
      windows: windows
    }
  }

  function rebuild() {
    var values = Hyprland.workspaces.values
    var rows = []

    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (workspace.id > 0 && workspace.toplevels.values.length > 0)
        rows.push(root.rowForWorkspace(workspace))
    }

    rows.sort(function(left, right) { return left.id - right.id })
    root.workspaceRows = rows

    if (rows.length === 0) {
      root.selectedIndex = 0
      return
    }

    if (root.selectedIndex >= rows.length) root.selectedIndex = rows.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function focusedIndex() {
    for (var i = 0; i < workspaceRows.length; i++) {
      if (workspaceRows[i].focused) return i
    }
    return 0
  }

  function select(direction) {
    if (workspaceRows.length < 2) return
    root.selectedIndex = (root.selectedIndex + direction + workspaceRows.length) % workspaceRows.length
    workspaceList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    // Hyprland owns the global Command/Super binding, so it also reports the
    // modifier release. Ignore unrelated Command releases when the switcher
    // is closed; commit the current selection when it is open.
    if (payload.commit === true) {
      if (root.opened) root.activate()
      return
    }

    var direction = payload.direction === -1 ? -1 : 1

    if (!root.opened) {
      root.rebuild()
      root.selectedIndex = root.focusedIndex()
      root.opened = true
    }

    root.select(direction)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "reomarchy.workspace-switcher")
  }

  function activate() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.workspaceRows.length) {
      root.dismiss()
      return
    }

    var workspaceId = root.workspaceRows[root.selectedIndex].id
    // Omarchy runs Hyprland's Lua configuration, so dispatch the Lua helper
    // instead of the legacy `workspace N` dispatcher.
    Quickshell.execDetached([
      "hyprctl",
      "dispatch",
      "hl.dsp.focus({ workspace = \"" + workspaceId + "\" })"
    ])
    root.dismiss()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "reomarchy-workspace-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.select((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Left) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          root.select(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate()
          event.accepted = true
        }
      }

    }

    Rectangle {
      id: switcher
      width: Math.min(panel.width - root.outerMargin * 2,
        root.workspaceRows.length * (root.cardWidth + root.cardGap) - root.cardGap + Style.space(32))
      height: root.previewHeight + root.labelHeight + Style.space(32)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      border.width: Math.max(1, Style.space(1))
      border.color: root.borderColor

      MouseArea { anchors.fill: parent; onClicked: {} }

      ListView {
        id: workspaceList
        anchors.fill: parent
        anchors.margins: Style.space(16)
        orientation: ListView.Horizontal
        spacing: root.cardGap
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.workspaceRows

        delegate: Item {
          id: workspaceCard
          required property int index
          required property var modelData
          width: root.cardWidth
          height: root.previewHeight + root.labelHeight

          Rectangle {
            id: preview
            width: parent.width
            height: root.previewHeight
            radius: Style.cornerRadius
            color: index === root.selectedIndex ? root.selectedBackground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: index === root.selectedIndex ? Style.space(3) : Math.max(1, Style.space(1))
            border.color: index === root.selectedIndex ? root.selectedText : root.borderColor
            clip: true

            Repeater {
              model: workspaceCard.modelData.windows

              Rectangle {
                required property var modelData
                readonly property real availableWidth: preview.width - Style.space(16)
                readonly property real availableHeight: preview.height - Style.space(16)
                x: Style.space(8) + Math.max(0, (modelData.x - workspaceCard.modelData.monitorX)
                  / Math.max(1, workspaceCard.modelData.monitorWidth) * availableWidth)
                y: Style.space(8) + Math.max(0, (modelData.y - workspaceCard.modelData.monitorY)
                  / Math.max(1, workspaceCard.modelData.monitorHeight) * availableHeight)
                width: Math.max(Style.space(42), Math.min(availableWidth,
                  modelData.width / Math.max(1, workspaceCard.modelData.monitorWidth) * availableWidth))
                height: Math.max(Style.space(30), Math.min(availableHeight,
                  modelData.height / Math.max(1, workspaceCard.modelData.monitorHeight) * availableHeight))
                radius: Math.max(2, Style.cornerRadius / 2)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                  index === root.selectedIndex ? 0.22 : 0.12)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.32)

                Text {
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  text: modelData.className
                  color: index === root.selectedIndex ? root.selectedText : root.foreground
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  verticalAlignment: Text.AlignVCenter
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = index
              onClicked: root.activate()
            }
          }

          Text {
            anchors.top: preview.bottom
            anchors.topMargin: Style.space(10)
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Workspace " + workspaceCard.modelData.name
            color: index === root.selectedIndex ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.62)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            font.bold: index === root.selectedIndex
          }
        }
      }
    }
  }
}
