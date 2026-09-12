import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

PanelWindow {
  id: root

  property var itemData: null
  property string iconSource: ""
  property bool opened: false
  property point requestedPosition: Qt.point(0, 0)
  property bool autoHideEnabled: true
  property string dockSide: "bottom"

  signal actionTriggered(string action, var itemData)

  visible: opened && itemData !== null
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "macos-dock-menu"
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: dismissSurface }

  Rectangle {
    id: card
    x: Math.round((root.width - width) / 2)
    y: Math.round((root.height - height) / 2)
    width: 650
    height: 370
    radius: 22
    color: Util.alpha(Color.background, 0.97)
    border.color: Util.alpha(Color.foreground, 0.14)
    border.width: 1

    Column {
      anchors.fill: parent
      anchors.margins: 22
      spacing: 16

      Item {
        width: parent.width
        height: 58

        Rectangle {
          width: 58
          height: 58
          radius: 16
          anchors.left: parent.left
          color: Util.alpha(Color.foreground, 0.08)

          Image {
            id: appIcon
            anchors.centerIn: parent
            width: 48
            height: 48
            source: root.iconSource
            sourceSize: Qt.size(96, 96)
            fillMode: Image.PreserveAspectFit
            visible: status === Image.Ready
          }
          Text {
            anchors.centerIn: parent
            text: root.itemData && root.itemData.name ? String(root.itemData.name).charAt(0).toUpperCase() : "•"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: 24
            font.bold: true
            visible: !appIcon.visible
          }
        }

        Column {
          anchors.left: parent.left
          anchors.leftMargin: 72
          anchors.verticalCenter: parent.verticalCenter
          spacing: 3
          Text {
            text: root.itemData && root.itemData.name ? root.itemData.name : "Application"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            text: root.itemData && root.itemData.running ? "Running application" : "Pinned application"
            color: Util.alpha(Color.foreground, 0.52)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Rectangle {
          width: 32
          height: 32
          anchors.right: parent.right
          radius: 16
          anchors.verticalCenter: parent.verticalCenter
          color: closeMouse.containsMouse ? Util.alpha(Color.foreground, 0.12) : "transparent"
          Text { anchors.centerIn: parent; text: "×"; color: Util.alpha(Color.foreground, 0.65); font.pixelSize: 22 }
          MouseArea { id: closeMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.opened = false }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.foreground, 0.10) }

      Text {
        text: "Application actions"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Row {
        width: parent.width
        height: 112
        spacing: 10

        Repeater {
          model: [
            { action: "setIcon", label: "Get Info", glyph: "✦", detail: "Change icon" },
            { action: "togglePin", label: root.itemData && root.itemData.pinned ? "Unpin" : "Pin", glyph: "⌖", detail: "Dock placement" },
            { action: "newWindow", label: "New Window", glyph: "＋", detail: "Open another" },
            { action: "manageIcons", label: "Manage Icons", glyph: "▦", detail: "Browse apps" }
          ]
          delegate: Rectangle {
            required property var modelData
            width: (parent.width - 30) / 4
            height: parent.height
            radius: 14
            color: actionMouse.containsMouse ? Util.alpha(Color.accent, 0.16) : Util.alpha(Color.foreground, 0.065)
            border.color: actionMouse.containsMouse ? Util.alpha(Color.accent, 0.55) : "transparent"
            border.width: 1

            Column {
              anchors.centerIn: parent
              spacing: 8
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.glyph
                color: actionMouse.containsMouse ? Color.accent : Color.foreground
                font.pixelSize: 24
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.label
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.detail
                color: Util.alpha(Color.foreground, 0.45)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: actionMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                root.actionTriggered(modelData.action, root.itemData)
              }
            }
          }
        }
      }

      Row {
        width: parent.width
        height: 38
        spacing: 8

        Text {
          text: "Dock"
          anchors.verticalCenter: parent.verticalCenter
          color: Util.alpha(Color.foreground, 0.52)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        UtilityButton {
          label: root.autoHideEnabled ? "Hiding on" : "Hiding off"
          action: "toggleAutoHide"
          width: 104
        }
        UtilityButton { label: "Bottom"; action: "setSideBottom"; selected: root.dockSide === "bottom"; width: 78 }
        UtilityButton { label: "Left"; action: "setSideLeft"; selected: root.dockSide === "left"; width: 64 }
        UtilityButton { label: "Right"; action: "setSideRight"; selected: root.dockSide === "right"; width: 68 }

        Item { width: 1; height: 1 }

      }
    }
  }

  component UtilityButton: Rectangle {
    property string label: ""
    property string action: ""
    property bool selected: false
    property bool danger: false
    height: 34
    radius: 9
    color: utilityMouse.containsMouse
      ? (danger ? Util.alpha(Color.urgent, 0.18) : Util.alpha(Color.foreground, 0.13))
      : (selected ? Util.alpha(Color.accent, 0.14) : Util.alpha(Color.foreground, 0.055))
    border.color: selected ? Util.alpha(Color.accent, 0.60) : "transparent"
    border.width: 1
    Text {
      anchors.centerIn: parent
      text: label
      color: danger ? Color.urgent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    MouseArea {
      id: utilityMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        root.actionTriggered(action, root.itemData)
      }
    }
  }

  Item {
    id: dismissSurface
    anchors.fill: parent
    z: -1
    MouseArea { anchors.fill: parent; onClicked: root.opened = false }
  }
}
