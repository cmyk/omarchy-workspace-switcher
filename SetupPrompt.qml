import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

Item {
  id: root
  property bool needed: false
  property string status: ""
  readonly property string pluginDirectory: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")

  function check() {
    if (probe.running) return
    status = "Checking existing shortcut setup…"
    probe.running = true
  }

  function startSetup() {
    if (probe.running || launcher.running) return
    // Do not cover the terminal's confirmation prompt with our overlay.
    needed = false
    launcher.running = true
  }

  Component.onCompleted: check()

  Process {
    id: probe
    command: ["/usr/bin/timeout", "15s", "/usr/bin/python3", "-I",
      root.pluginDirectory + "binding_transaction.py", "probe", root.configHome + "/hypr"]
    onExited: function(code) {
      if (code !== 0) {
        root.needed = true
        root.status = "Could not verify shortcut setup. Guided setup will explain what needs attention."
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = text.trim()
        root.needed = state !== "installed" && state !== "manual"
        root.status = state === "absent"
          ? "Enable Command/Super-Tab switching?"
          : "Shortcut setup needs attention. Open guided setup to inspect it."
      }
    }
  }

  Process {
    id: launcher
    command: ["/usr/bin/python3", "-I", root.pluginDirectory + "launch-setup.py"]
    onExited: function(code) {
      if (code !== 0) {
        root.needed = true
        root.status = "Setup did not complete, or the terminal could not start. Retry guided setup, or run install.sh from the plugin directory."
      }
    }
  }

  PanelWindow {
    visible: root.needed
    implicitWidth: Style.space(520)
    implicitHeight: content.implicitHeight + Style.space(48)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "reomarchy-workspace-switcher-setup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    Rectangle {
      anchors.fill: parent
      color: Color.menu.background
      radius: Style.cornerRadius
      border.color: Color.menu.border
      border.width: 1

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(24)
        spacing: Style.space(14)
        Text {
          text: "Workspace Switcher"
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          width: parent.width
          text: root.status
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.menu.text
          font.pixelSize: Style.font.body
        }
        Text {
          width: parent.width
          text: "Guided setup opens in a terminal and asks before replacing your shortcuts. It keeps a backup and validates the change. Nothing changes until you approve."
          wrapMode: Text.WordWrap
          color: Color.menu.text
          font.pixelSize: Style.font.caption
        }
        Row {
          spacing: Style.space(12)
          Rectangle {
            activeFocusOnTab: true
            focus: true
            Keys.onReturnPressed: root.startSetup()
            Keys.onSpacePressed: root.startSetup()
            Keys.onEscapePressed: root.needed = false
            width: Style.space(220)
            height: Style.space(38)
            radius: Style.cornerRadius
            color: Color.menu.selectedBackground
            border.width: activeFocus ? 2 : 0
            border.color: Color.menu.selectedText
            Text {
              anchors.centerIn: parent
              text: "Open guided setup"
              color: Color.menu.selectedText
              font.pixelSize: Style.font.body
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              enabled: !probe.running && !launcher.running
              onClicked: root.startSetup()
            }
          }
          Rectangle {
            activeFocusOnTab: true
            Keys.onReturnPressed: root.needed = false
            Keys.onSpacePressed: root.needed = false
            Keys.onEscapePressed: root.needed = false
            width: Style.space(120)
            height: Style.space(38)
            radius: Style.cornerRadius
            color: Color.menu.background
            border.color: Color.menu.border
            border.width: activeFocus ? 2 : 1
            Text {
              anchors.centerIn: parent
              text: "Later"
              color: Color.menu.text
              font.pixelSize: Style.font.body
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.needed = false
            }
          }
        }
      }
    }
  }
}
