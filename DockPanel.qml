import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property var pluginRegistry: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var service: null

  // Keep the mature interaction/launch/pinning implementation intact while
  // giving it a tighter macOS-like visual shell.
  DockPanelBase {
    id: dock
    shell: root.shell
    pluginRegistry: root.pluginRegistry
    manifest: root.manifest
    dockHeight: 78
    bottomMargin: 4
    iconSize: 54
    slotWidth: 60
    slotSpacing: 6
    sidePadding: 12
    separatorWidth: 12
  }

  // A lightweight material layer sits above the legacy surface. It is
  // intentionally almost transparent: its job is to add the soft edge and
  // glass highlight that makes the dock read as a floating material surface,
  // not as a generic black panel. The actual icons remain fully interactive.
  PanelWindow {
    id: material
    visible: dock.enabled && !dock.conflictDetected
    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "macos-dock-material"
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region {}

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: dock.autoHide && dock.autoHidden ? -dock.dockHeight + dock.peekPx : dock.bottomMargin
      width: dock.layoutWidth
      height: dock.dockHeight
      radius: 18
      color: "transparent"
      border.color: "transparent"
      border.width: 0
      opacity: dock.menuOpen || dock.pickerOpen || dock.dockHovered ? 1 : 0.92

      Behavior on anchors.bottomMargin { NumberAnimation { duration: dock.autoHidden ? dock.hideDuration : dock.showDuration; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 160 } }
    }
  }
}
