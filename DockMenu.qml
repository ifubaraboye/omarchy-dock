import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// macOS-style context menu: window titles first (click to focus, checkmark on
// the focused window, minimized titles dimmed), then New Window, an Options ▸
// flyout submenu (Keep in Dock with its checkmark, icon tools), and Quit.
// requestedPosition arrives in the host dock window's scene space — the dock
// content window is edge-anchored fullscreen, so that space is this window's
// space too, and placement is a plain clamp.
PanelWindow {
  id: root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var itemData: null
  property string iconSource: ""
  property bool opened: false
  property point requestedPosition: Qt.point(0, 0)
  property var windows: []
  // "app" = icon right-click; "dock" = empty-space right-click, which macOS
  // fills with dock-level controls (hiding, position) instead of app actions.
  property string mode: "app"
  property bool dockHiding: true
  property string dockSideCurrent: "bottom"
  property bool positionOpen: false

  readonly property bool isSpecial: itemData !== null && (itemData.id === "downloads" || itemData.id === "trash")
  readonly property bool isRunning: itemData !== null && itemData.running === true
  readonly property bool isPinned: itemData !== null && itemData.pinned === true
  // The bottom dock keeps its icons in a strip at the screen's foot, so the
  // menu belongs above the click. Anywhere else is a side dock: center the
  // menu on the icon and let the clamps keep it on screen.
  readonly property bool fromBottomDock: requestedPosition.y > root.height - 300
  // The Options flyout stays up while the pointer is on its row or itself.
  property bool optionsOpen: false

  signal actionTriggered(string action, var itemData)

  visible: opened && (mode === "dock" || itemData !== null)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "macos-dock-menu"
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: dismissSurface }

  Rectangle {
    id: card

    x: Math.max(8, Math.min(root.requestedPosition.x - 16, root.width - width - 8))
    y: root.fromBottomDock
      ? Math.max(8, root.requestedPosition.y - height - 12)
      : Math.max(8, Math.min(root.requestedPosition.y - height / 2, root.height - height - 8))

    width: 236
    height: menuColumn.implicitHeight + 12
    radius: 10
    color: Util.alpha(Color.background, 0.94)
    border.color: Util.alpha(Color.foreground, 0.14)
    border.width: 1

    Column {
      id: menuColumn
      x: 6
      y: 6
      width: 224
      spacing: 0

      // The app's open windows, the way macOS lists them. Focus on click;
      // checkmark on the focused one, dimmed when minimized.
      Repeater {
        model: root.mode === "app" && !root.isSpecial ? root.windows.slice(0, 8) : []

        MenuRow {
          required property var modelData
          label: modelData.title && modelData.title !== "" ? modelData.title : (root.itemData ? root.itemData.name : "")
          checked: modelData.active === true
          dimmed: modelData.minimized === true
          action: "focusWindow:" + modelData.address
        }
      }

      MenuRow {
        visible: root.mode === "app" && root.isRunning && !root.isSpecial
        label: strings.t("menu.newWindow")
        action: "newWindow"
      }
      MenuRow {
        visible: root.mode === "app" && !root.isRunning && !root.isSpecial && root.isPinned
        label: strings.t("menu.open")
        action: "newWindow"
      }

      MenuDivider { visible: root.mode === "app" && !root.isSpecial }

      // Options ▸ — the flyout opens on hover and stays while the pointer is
      // on the row or inside it, exactly like a macOS submenu.
      Rectangle {
        id: optionsRow
        visible: root.mode === "app" && !root.isSpecial
        width: parent.width
        height: 26
        radius: 6
        color: optionsRowMouse.containsMouse || root.optionsOpen ? Color.accent : "transparent"

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: 30
          anchors.verticalCenter: parent.verticalCenter
          text: strings.t("menu.options")
          color: optionsRowMouse.containsMouse || root.optionsOpen ? Color.background : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.rightMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          text: "▸"
          color: optionsRowMouse.containsMouse || root.optionsOpen ? Color.background : Util.alpha(Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: optionsRowMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onContainsMouseChanged: if (containsMouse) root.optionsOpen = true
        }
      }

      MenuDivider { visible: root.mode === "app" && root.isRunning && !root.isSpecial }

      MenuRow {
        visible: root.mode === "app" && root.isRunning && !root.isSpecial
        label: strings.t("menu.quit")
        action: "close"
      }

      // Downloads / Trash are folders, not apps: open is all they offer.
      MenuRow {
        visible: root.mode === "app" && root.isSpecial
        label: strings.t("menu.open")
        action: "newWindow"
      }

      // Empty-space right-click: dock-level controls, the way macOS fills the
      // divider menu — hiding, position, and the dock's own preferences slot.
      MenuRow {
        visible: root.mode === "dock"
        label: root.dockHiding ? strings.t("menu.turnHidingOff") : strings.t("menu.turnHidingOn")
        action: "toggleAutoHide"
      }
      MenuDivider { visible: root.mode === "dock" }

      Rectangle {
        id: positionRow
        visible: root.mode === "dock"
        width: parent.width
        height: 26
        radius: 6
        color: positionRowMouse.containsMouse || root.positionOpen ? Color.accent : "transparent"

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: 30
          anchors.verticalCenter: parent.verticalCenter
          text: strings.t("menu.positionOnScreen")
          color: positionRowMouse.containsMouse || root.positionOpen ? Color.background : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.rightMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          text: "▸"
          color: positionRowMouse.containsMouse || root.positionOpen ? Color.background : Util.alpha(Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: positionRowMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onContainsMouseChanged: if (containsMouse) root.positionOpen = true
        }
      }

      MenuDivider { visible: root.mode === "dock" }

      MenuRow {
        visible: root.mode === "dock"
        label: strings.t("menu.manageIconsEllipsis")
        action: "manageIcons"
      }
    }
  }

  // The Options flyout: macOS opens it on hover, to the side of the row, and
  // it holds exactly one entry — Keep in Dock, with its checkmark.
  Rectangle {
    id: optionsFlyout

    visible: root.optionsOpen && root.mode === "app" && !root.isSpecial
    x: card.x + card.width + 6 + width <= root.width - 8
      ? card.x + card.width + 6
      : card.x - width - 6
    y: Math.max(8, Math.min(card.y + optionsRow.y, root.height - height - 8))

    width: 200
    height: flyColumn.implicitHeight + 12
    radius: 10
    color: Util.alpha(Color.background, 0.94)
    border.color: Util.alpha(Color.foreground, 0.14)
    border.width: 1

    Column {
      id: flyColumn
      x: 6
      y: 6
      width: 188
      spacing: 0

      MenuRow {
        label: strings.t("menu.keepInDock")
        checked: root.isPinned
        action: "togglePin"
      }
      MenuDivider {}
      MenuRow {
        label: strings.t("menu.changeIconEllipsis")
        action: "setIcon"
      }
    }

    // Hover-only: keeps the flyout up without eating its rows' clicks.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (!containsMouse && !optionsRowMouse.containsMouse) root.optionsOpen = false
    }
  }

  // The Position flyout: Left / Bottom / Right with a checkmark on the
  // current side, matching macOS's "Position on Screen" submenu.
  Rectangle {
    id: positionFlyout

    visible: root.positionOpen && root.mode === "dock"
    x: card.x + card.width + 6 + width <= root.width - 8
      ? card.x + card.width + 6
      : card.x - width - 6
    y: Math.max(8, Math.min(card.y + positionRow.y, root.height - height - 8))

    width: 160
    height: positionColumn.implicitHeight + 12
    radius: 10
    color: Util.alpha(Color.background, 0.94)
    border.color: Util.alpha(Color.foreground, 0.14)
    border.width: 1

    Column {
      id: positionColumn
      x: 6
      y: 6
      width: 148
      spacing: 0

      MenuRow {
        label: strings.t("menu.left")
        checked: root.dockSideCurrent === "left"
        action: "setSideLeft"
      }
      MenuRow {
        label: strings.t("menu.bottom")
        checked: root.dockSideCurrent === "bottom"
        action: "setSideBottom"
      }
      MenuRow {
        label: strings.t("menu.right")
        checked: root.dockSideCurrent === "right"
        action: "setSideRight"
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (!containsMouse && !positionRowMouse.containsMouse) root.positionOpen = false
    }
  }

  component MenuRow: Rectangle {
    id: row

    property string label: ""
    property string action: ""
    property bool checked: false
    property bool dimmed: false
    property bool closeOnTrigger: true

    width: parent.width
    height: 26
    radius: 6
    color: rowMouse.containsMouse ? Color.accent : "transparent"

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      text: "✓"
      visible: row.checked
      color: rowMouse.containsMouse ? Color.background : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Text {
      id: rowLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: 30
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - 40
      elide: Text.ElideRight
      text: row.label
      color: rowMouse.containsMouse
        ? Color.background
        : (row.dimmed ? Util.alpha(Color.foreground, 0.55) : Color.foreground)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        if (row.closeOnTrigger) root.opened = false
        root.actionTriggered(row.action, root.itemData)
      }
    }
  }

  component MenuDivider: Item {
    width: parent.width
    height: 9

    Rectangle {
      anchors.centerIn: parent
      width: parent.width - 20
      height: 1
      color: Util.alpha(Color.foreground, 0.12)
    }
  }

  Item {
    id: dismissSurface
    anchors.fill: parent
    z: -1
    MouseArea { anchors.fill: parent; onClicked: root.opened = false }
  }
}
