import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

PanelWindow {
  id: root

  property var itemData: null
  property bool opened: false
  property point requestedPosition: Qt.point(0, 0)

  signal actionTriggered(string action, var itemData)

  visible: opened && itemData !== null
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "macos-dock-menu"
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: dismissSurface }

  Rectangle {
    id: menu
    x: Math.max(12, Math.min(root.requestedPosition.x, root.width - width - 12))
    y: Math.max(12, Math.min(root.requestedPosition.y, root.height - height - 12))
    width: 170
    height: 3 * 38 + 16
    radius: 14
    color: Util.alpha(Color.background, 0.96)
    border.color: Util.alpha(Color.foreground, 0.18)
    border.width: 1

    Column {
      anchors.fill: parent
      anchors.margins: 8
      spacing: 2

      Repeater {
        model: [
          { action: "togglePin", label: root.itemData && root.itemData.pinned ? "Unpin" : "Pin" },
          { action: "newWindow", label: "New Window" },
          { action: "close", label: "Close" }
        ]
        delegate: Rectangle {
          required property var modelData
          width: parent.width
          height: 36
          radius: 8
          color: buttonMouse.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent"

          Text {
            anchors.fill: parent
            anchors.leftMargin: 10
            verticalAlignment: Text.AlignVCenter
            text: modelData.label
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
              root.actionTriggered(modelData.action, root.itemData)
              root.opened = false
            }
          }
        }
      }
    }
  }

  Item {
    id: dismissSurface
    anchors.fill: parent
    z: -1

    MouseArea {
      anchors.fill: parent
      onClicked: root.opened = false
    }
  }

  // Keep the menu's input region limited to the card. Outside-click dismissal
  // is intentionally handled by the shell reload-safe menu state rather than
  // relying on HyprlandFocusGrab, which is not available in every plugin host.
}
