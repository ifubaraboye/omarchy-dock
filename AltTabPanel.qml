import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "DockModel.js" as DockModel

// macOS-style app switcher HUD. The UI is a mirror image of the dock itself
// (same glass surface, same icons) scaled up 30%, with the running dots,
// icon magnification and name labels removed: a flat row of equally sized
// icons. Selection is keyboard-driven while the dock's own mouse semantics
// (hover to select, click to activate) still apply.
//
// Keyboard contract: Hyprland consumes the ALT+GRAVE global binds (exec
// omarchy-shell ... altTabNext/altTabPrev), so the bound key never reaches
// this window. While visible it grabs the keyboard exclusively and receives
// the unbound keys: Alt release activates, Escape cancels, Enter activates,
// arrows move the selection.
PanelWindow {
  id: root

  property bool active: false
  property var apps: []
  property int selectedIndex: -1
  property var placements: ({})
  property real surfaceWidth: 0
  property var iconSourceFor: function(app) { return "" }

  // The dock's layout constants scaled by ~2.1 (15% over the previous 1.82).
  property int iconSize: 105
  property int slotWidth: 121
  property int slotSpacing: 16
  property int sidePadding: 38
  property int surfaceHeight: 210

  signal activated(string appId, string appName)

  function iconSource(app) {
    var src = root.iconSourceFor(app)
    if (!src) return ""
    if (String(src).indexOf("/") === 0) return Util.fileUrl(src)
    if (String(src).indexOf("file:") === 0 || String(src).indexOf("image:") === 0) return src
    return Quickshell.iconPath(src, true)
  }

  // Flat layout: the dock's slot geometry scaled up, no cursor magnification.
  function relayout() {
    if (root.apps.length === 0) {
      root.surfaceWidth = 0
      root.placements = {}
      return
    }
    var flow = []
    for (var i = 0; i < root.apps.length; i++)
      flow.push({ id: root.apps[i].id })
    var opts = {
      slotWidth: root.slotWidth,
      spacing: root.slotSpacing,
      iconSize: root.iconSize,
      hoverScale: 1,
      radius: 1,
      sidePadding: root.sidePadding,
      separatorWidth: 14
    }
    var result = DockModel.computeLayout(flow, -1, opts)
    root.placements = result.placements
    root.surfaceWidth = result.totalWidth
  }

  onAppsChanged: root.relayout()

  function open(list, initialIndex) {
    root.apps = list || []
    root.selectedIndex = initialIndex >= 0 && initialIndex < root.apps.length ? initialIndex : 0
    root.active = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function next() {
    if (root.apps.length === 0) return
    root.selectedIndex = (root.selectedIndex + 1) % root.apps.length
  }

  function prev() {
    if (root.apps.length === 0) return
    root.selectedIndex = (root.selectedIndex - 1 + root.apps.length) % root.apps.length
  }

  function cancel() {
    root.active = false
    root.apps = []
    root.selectedIndex = -1
  }

  function activateSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.apps.length) {
      root.cancel()
      return
    }
    var app = root.apps[root.selectedIndex]
    var id = app.id
    var name = app.name
    root.cancel()
    root.activated(id, name)
  }

  visible: root.active
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "macos-dock-alt-tab"
  WlrLayershell.keyboardFocus: root.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: dockSurface }

  // The dock's own glass surface, centered on screen instead of bottom-anchored.
  Rectangle {
    id: dockSurface
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    width: root.surfaceWidth
    height: root.surfaceHeight
    radius: 22
    color: Util.alpha(Color.background, 0.88)
    border.color: Util.alpha(Color.foreground, 0.20)
    border.width: 1
    opacity: root.active ? 1 : 0.96

    Item {
      id: dockRow
      anchors.centerIn: parent
      width: root.surfaceWidth - 2 * root.sidePadding
      height: root.iconSize + 26

      Repeater {
        model: root.apps

        delegate: Item {
          id: item
          required property var modelData
          required property int index

          // The dock's icon geometry scaled up, minus the running dot, the
          // magnification springs and all interaction beyond hover/click.
          width: root.iconSize + 8
          height: root.iconSize + 18
          x: root.placements[modelData.id] ? root.placements[modelData.id].x : 0

          // Subtle highlight box: a slightly lighter variant of the dock's own
          // background around the app being tabbed to (and hovered).
          Rectangle {
            anchors.centerIn: parent
            width: root.iconSize + 12
            height: root.iconSize + 12
            radius: 20
            color: Util.alpha(Color.foreground, 0.10)
            visible: root.selectedIndex === index
          }

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: root.iconSize
            height: root.iconSize
            source: root.iconSource(modelData)
            sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
            fillMode: Image.PreserveAspectFit
            cache: true

            Text {
              anchors.centerIn: parent
              visible: parent.status !== Image.Ready
              text: "◆"
              color: Color.foreground
              font.pixelSize: root.iconSize * 0.42
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.selectedIndex = index
            onClicked: {
              root.selectedIndex = index
              root.activateSelected()
            }
          }
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.cancel(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          // With the Hyprland binds configured, the bound key never arrives
          // (the compositor consumes it). Without them this keeps the HUD
          // usable.
          if (event.key === Qt.Key_Backtab) root.prev(); else root.next()
          event.accepted = true; return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activateSelected(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Left) {
          root.prev(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Right) {
          root.next(); event.accepted = true; return
        }
      }
      Keys.onReleased: function(event) {
        // Hyprland delivers the Alt release (pressed before this surface
        // gained keyboard focus) with an unmapped keysym: Qt reports key 0,
        // but the native scan code is intact (64 = Alt_L, 108 = Alt_R).
        // Match by scan code so "release Alt to activate" works even for the
        // modifier that was held before the HUD appeared.
        var scan = event.nativeScanCode
        if (event.key === Qt.Key_Alt || scan === 64 || scan === 108) {
          root.activateSelected(); event.accepted = true
        }
      }
    }
  }
}