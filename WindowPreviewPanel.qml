import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Overlay panel that renders the hover-to-preview popup above the dock. It is
// independent from the dock model and can appear as soon as the live window
// list is known. Cards prefer a direct compositor capture and can fall back
// to a cached thumbnail or application icon.
PanelWindow {
  id: root

  property bool previewVisible: false
  property var windowList: []
  property real centerX: 0
  property real bottomY: 0
  property var iconSourceFor: function(item) { return "" }
  property var thumbnailFor: function(item) { return "" }
  property Component cardComponent: Qt.createComponent("WindowPreview.qml")
  property var cards: []
  readonly property bool panelActive: root.previewVisible || root.windowList.length > 0

  signal activated(var windowData)
  signal previewHoverEntered()
  signal previewHoverExited()

  function rebuild() {
    if (!root.windowList) return
    for (var i = 0; i < root.cards.length; i++)
      root.cards[i].destroy()
    root.cards = []

    var windows = root.windowList
    for (var j = 0; j < windows.length; j++) {
      var w = windows[j]
      var card = root.cardComponent.createObject(row, {
        windowData: w,
        iconSource: root.iconSourceFor(w),
        thumbnail: root.thumbnailFor(w),
        active: !!w.active
      })
      if (!card) {
        console.warn("macos.dock preview card failed:", root.cardComponent.errorString())
        continue
      }
      card.activated.connect(function(data) { root.activated(data) })
      root.cards.push(card)
    }
  }

  onWindowListChanged: Qt.callLater(root.rebuild)

  // Do not wait for a screenshot process to finish before showing the panel.
  // The live ScreencopyView in each card can render independently.
  visible: root.panelActive
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "macos-dock-preview"
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: previewRow }

  Item {
    id: previewRow
    x: Math.max(8, Math.min(root.centerX - width / 2, parent.width - width - 8))
    // DockPanel supplies the exact dock surface Y once its preview state is
    // committed. While the first frame is arriving, use the known bottom
    // dock geometry so the panel is already in the correct place.
    y: Math.max(8, (root.bottomY > 0 ? root.bottomY : parent.height - 123) - height - 6)
    width: row.implicitWidth
    height: row.implicitHeight
    opacity: root.panelActive ? 1 : 0
    scale: root.panelActive ? 1 : 0.92

    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    Row {
      id: row
      spacing: 10
    }

    MouseArea {
      id: hoverArea
      anchors.fill: parent
      anchors.margins: -12
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      cursorShape: Qt.PointingHandCursor
      onEntered: root.previewHoverEntered()
      onExited: root.previewHoverExited()
    }
  }
}
