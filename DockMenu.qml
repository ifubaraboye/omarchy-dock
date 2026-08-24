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
    width: 180
    height: 5 * 38 + 2 * 10 + 16
    radius: 14
    color: Util.alpha(Color.background, 0.92)
    border.color: Util.alpha(Color.foreground, 0.08)
    border.width: 1

    Column {
      anchors.fill: parent
      anchors.margins: 8
      spacing: 2

      Repeater {
        model: [
          { action: "setIcon", label: "Get Info", separator: false },
          { action: "", label: "", separator: true },
          { action: "togglePin", label: root.itemData && root.itemData.pinned ? "Unpin" : "Pin", separator: false },
          { action: "newWindow", label: "New Window", separator: false },
          { action: "close", label: "Close", separator: false },
          { action: "", label: "", separator: true },
          { action: "manageIcons", label: "Manage Icons", separator: false }
        ]
        delegate: Rectangle {
          required property var modelData
          width: parent.width
          height: modelData.separator ? 10 : 36
          radius: 8
          color: !modelData.separator && buttonMouse.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent"

          Text {
            visible: !modelData.separator
            anchors.fill: parent
            anchors.leftMargin: 10
            verticalAlignment: Text.AlignVCenter
            text: modelData.label
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Rectangle {
            visible: modelData.separator
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: Util.alpha(Color.foreground, 0.12)
          }

          MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !modelData.separator
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