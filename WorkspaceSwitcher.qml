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
  property bool revealed: false
  property int selectedIndex: 0
  property var workspaceRows: []
  property var recentWorkspaceIds: []

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

  function friendlyAppName(className) {
    var name = String(className || "App")
    var normalized = name.toLowerCase()
    var terminals = [
      "foot", "footclient", "alacritty", "kitty",
      "org.wezfurlong.wezterm", "com.mitchellh.ghostty"
    ]
    return terminals.indexOf(normalized) >= 0 ? "Terminal" : name
  }

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
        className: root.friendlyAppName(ipc.class || "App"),
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
      monitorName: monitor ? monitor.name : "",
      monitorX: monitor ? monitor.x : 0,
      monitorY: monitor ? monitor.y : 0,
      monitorWidth: monitor ? monitor.width : panel.width,
      monitorHeight: monitor ? monitor.height : panel.height,
      windows: windows
    }
  }

  function sameWorkspaceTopology(rows) {
    if (rows.length !== root.workspaceRows.length) return false
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id !== root.workspaceRows[i].id
          || rows[i].monitorName !== root.workspaceRows[i].monitorName)
        return false
    }
    return true
  }

  function screenForMonitorName(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) return screens[i]
    }
    return panel.screen
  }

  function rememberWorkspace(id) {
    if (id === undefined || id === null || id <= 0) return

    var next = [id]
    for (var i = 0; i < root.recentWorkspaceIds.length; i++) {
      var existingId = root.recentWorkspaceIds[i]
      if (existingId !== id) next.push(existingId)
    }
    root.recentWorkspaceIds = next
  }

  function rebuild() {
    var values = Hyprland.workspaces.values
    var rows = []

    if (Hyprland.focusedWorkspace)
      root.rememberWorkspace(Hyprland.focusedWorkspace.id)

    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (workspace.id > 0 && workspace.toplevels.values.length > 0) {
        rows.push(root.rowForWorkspace(workspace))
      }
    }

    // Card positions are spatial and stable: workspace 1 is always before 2,
    // 2 before 3, and so on. Recent history affects selection only.
    rows.sort(function(left, right) { return left.id - right.id })
    // Preserve the delegates (and therefore their captured frames) while the
    // same occupied workspaces remain present. Replacing an array model makes
    // ListView destroy those delegates and would discard every cached image.
    if (!root.sameWorkspaceTopology(rows))
      root.workspaceRows = rows

    if (rows.length === 0) {
      root.selectedIndex = 0
      return
    }

    if (root.selectedIndex >= rows.length) root.selectedIndex = rows.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function rowIndexForWorkspace(id) {
    for (var i = 0; i < root.workspaceRows.length; i++) {
      if (root.workspaceRows[i].id === id) return i
    }
    return -1
  }

  function focusedIndex() {
    var focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    for (var i = 0; i < workspaceRows.length; i++) {
      if (workspaceRows[i].id === focusedId) return i
    }
    return 0
  }

  function captureFocusedWorkspace() {
    if (root.opened || !Hyprland.focusedWorkspace) return

    root.rebuild()
    var index = root.rowIndexForWorkspace(Hyprland.focusedWorkspace.id)
    if (index < 0) return

    var card = workspaceList.itemAtIndex(index)
    if (card && typeof card.capturePreview === "function")
      card.capturePreview()
  }

  function previousWorkspaceIndex(currentId) {
    for (var i = 0; i < root.recentWorkspaceIds.length; i++) {
      var recentId = root.recentWorkspaceIds[i]
      if (recentId !== currentId) {
        var recentIndex = root.rowIndexForWorkspace(recentId)
        if (recentIndex >= 0) return recentIndex
      }
    }

    return root.workspaceRows.length > 1
      ? (root.focusedIndex() + 1) % root.workspaceRows.length
      : root.focusedIndex()
  }

  function select(direction) {
    if (root.workspaceRows.length < 2) return
    root.selectedIndex = (root.selectedIndex + direction + root.workspaceRows.length) % root.workspaceRows.length
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
      if (root.workspaceRows.length === 0) return
      var currentIndex = root.focusedIndex()
      var currentId = root.workspaceRows[currentIndex].id
      root.selectedIndex = direction < 0
        ? (currentIndex - 1 + root.workspaceRows.length) % root.workspaceRows.length
        : root.previousWorkspaceIndex(currentId)
      root.opened = true
      root.revealed = false
      revealTimer.restart()
    } else {
      // After the initial MRU selection, traversal follows the stable card
      // layout: Tab moves right and Shift+Tab left, wrapping at the ends.
      root.select(direction)
    }

    workspaceList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function close() {
    root.opened = false
    root.revealed = false
    revealTimer.stop()
  }

  function dismiss() {
    root.opened = false
    root.revealed = false
    revealTimer.stop()
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

  Component.onCompleted: {
    root.rebuild()
    if (Hyprland.focusedWorkspace)
      root.rememberWorkspace(Hyprland.focusedWorkspace.id)
    initialCaptureTimer.restart()
  }

  Timer {
    id: captureTimer
    interval: 300
    repeat: false
    onTriggered: root.captureFocusedWorkspace()
  }

  Timer {
    id: revealTimer
    // A quick Command-Tab should feel like an instantaneous toggle, not flash
    // a large overlay. Holding Command past this threshold reveals the UI.
    interval: 180
    repeat: false
    onTriggered: {
      if (!root.opened) return
      root.revealed = true
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  Timer {
    id: initialCaptureTimer
    // Screencopy contexts are initialized asynchronously. The later first
    // capture avoids racing that setup when the shell itself has just started.
    interval: 1500
    repeat: false
    onTriggered: root.captureFocusedWorkspace()
  }

  Connections {
    target: Hyprland

    function onFocusedWorkspaceChanged() {
      if (Hyprland.focusedWorkspace) {
        root.rememberWorkspace(Hyprland.focusedWorkspace.id)
        // Let the compositor finish switching before taking the one cached
        // frame. Nothing is captured continuously.
        captureTimer.restart()
      }
    }
  }

  PanelWindow {
    id: panel
    // Keep the surface mapped so ListView does not destroy the delegates that
    // own our cached screencopy buffers. While closed it is transparent,
    // unfocused, and has an empty input region.
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "reomarchy-workspace-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.revealed ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {
      width: root.revealed ? panel.width : 0
      height: root.revealed ? panel.height : 0
    }

    Rectangle {
      anchors.fill: parent
      visible: root.revealed
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.revealed
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      visible: root.revealed
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
      visible: root.revealed
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
          readonly property bool hovered: previewMouse.containsMouse
          width: root.cardWidth
          height: root.previewHeight + root.labelHeight

          function capturePreview() {
            var source = root.screenForMonitorName(modelData.monitorName)
            if (workspaceCapture.captureSource !== source)
              workspaceCapture.captureSource = source

            if (workspaceCapture.hasContent)
              workspaceCapture.captureFrame()
            else
              // Starting live mode requests the first frame once the newly
              // created screencopy context is ready. It is disabled again as
              // soon as that frame arrives.
              workspaceCapture.live = true
          }

          Rectangle {
            id: preview
            width: parent.width
            height: root.previewHeight
            radius: Style.cornerRadius
            scale: workspaceCard.hovered ? 1.015 : 1
            color: index === root.selectedIndex
              ? root.selectedBackground
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                  workspaceCard.hovered ? 0.10 : 0.06)
            border.width: index === root.selectedIndex
              ? Style.space(3)
              : (workspaceCard.hovered ? Style.space(2) : Math.max(1, Style.space(1)))
            border.color: index === root.selectedIndex
              ? root.selectedText
              : (workspaceCard.hovered
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.72)
                  : root.borderColor)
            clip: true

            Behavior on scale {
              NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
            }

            ScreencopyView {
              id: workspaceCapture
              anchors.fill: parent
              anchors.margins: preview.border.width
              captureSource: null
              live: false
              paintCursor: false
              visible: hasContent
              onHasContentChanged: {
                if (hasContent && live) live = false
              }
            }

            // Repeater delegates are siblings rather than visual children of
            // the Repeater itself, so hiding the Repeater does not hide them.
            // This container owns the fallback rectangles and suppresses them
            // once the real cached screenshot is ready.
            Item {
              anchors.fill: parent
              visible: !workspaceCapture.hasContent

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
            }

            Rectangle {
              anchors.fill: parent
              anchors.margins: preview.border.width
              radius: Math.max(0, preview.radius - preview.border.width)
              color: workspaceCard.hovered && index !== root.selectedIndex
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
                : "transparent"
            }

            MouseArea {
              id: previewMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.selectedIndex = index
                root.activate()
              }
            }
          }

          Text {
            anchors.top: preview.bottom
            anchors.topMargin: Style.space(10)
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Workspace " + workspaceCard.modelData.name
            color: index === root.selectedIndex || workspaceCard.hovered
              ? root.foreground
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.62)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            font.bold: index === root.selectedIndex || workspaceCard.hovered
          }
        }
      }
    }
  }
}
