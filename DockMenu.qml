import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

PanelWindow {
  id: root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

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
            // Falls back to the window's appId when no desktop entry matched,
            // so this string is client-controlled: force plain text.
            textFormat: Text.PlainText
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
            // The app name can come from an unmatched, client-controlled
            // window appId. AutoText would parse "<img src=...>" and could
            // fetch remote images from the host shell, so keep it literal.
            textFormat: Text.PlainText
            text: root.itemData && root.itemData.name ? root.itemData.name : strings.t("menu.application")
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: root.itemData && root.itemData.running ? strings.t("menu.running") : strings.t("menu.pinned")
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
          Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "×"; color: Util.alpha(Color.foreground, 0.65); font.pixelSize: 22 }
          MouseArea { id: closeMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.opened = false }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.foreground, 0.10) }

      Text {
        textFormat: Text.PlainText
        text: strings.t("menu.actions")
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
            { action: "setIcon", label: strings.t("menu.getInfo"), glyph: "✦", detail: strings.t("menu.changeIcon") },
            { action: "togglePin", label: root.itemData && root.itemData.pinned ? strings.t("menu.unpin") : strings.t("menu.pin"), glyph: "⌖", detail: strings.t("menu.dockPlacement") },
            { action: "newWindow", label: strings.t("menu.newWindow"), glyph: "＋", detail: strings.t("menu.openAnother") },
            { action: "manageIcons", label: strings.t("menu.manageIcons"), glyph: "▦", detail: strings.t("menu.browseApps") }
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
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.glyph
                color: actionMouse.containsMouse ? Color.accent : Color.foreground
                font.pixelSize: 24
              }
              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.label
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
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
          textFormat: Text.PlainText
          text: strings.t("menu.dock")
          anchors.verticalCenter: parent.verticalCenter
          color: Util.alpha(Color.foreground, 0.52)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        UtilityButton {
          label: root.autoHideEnabled ? strings.t("menu.hidingOn") : strings.t("menu.hidingOff")
          action: "toggleAutoHide"
          width: 104
        }
        UtilityButton { label: strings.t("menu.bottom"); action: "setSideBottom"; selected: root.dockSide === "bottom"; width: 78 }
        UtilityButton { label: strings.t("menu.left"); action: "setSideLeft"; selected: root.dockSide === "left"; width: 64 }
        UtilityButton { label: strings.t("menu.right"); action: "setSideRight"; selected: root.dockSide === "right"; width: 68 }

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
      textFormat: Text.PlainText
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
