import QtQuick

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
}
