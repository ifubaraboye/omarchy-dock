import QtQuick
import Quickshell
import qs.Commons
import "IconResolver.js" as IconResolver

Item {
  id: root

  required property var itemData
  property int iconSize: 52
  property real hoverScale: 1.46
  property real magnificationRadius: 104
  property real mouseDistance: 9999
  property bool isDragging: false
  property bool tooltipVisible: false
  property string iconSourceOverride: ""
  property real layoutShift: 0
  property point pressPosition: Qt.point(0, 0)

  signal moveRequested(int fromIndex, int toIndex)
  signal dragMoved(var itemData, point position)
  signal dragFinished(var itemData, point position)
  signal itemLeftClicked(var itemData)
  signal itemRightClicked(var itemData, point position)
  signal tooltipRequested(var itemData, bool visible, real centerX)
  signal hoverPointerChanged(var itemData, bool inside, real pointerX)

  width: iconSize + 8
  height: iconSize + 18

  readonly property real proximityScale: {
    var distance = Math.abs(mouseDistance)
    var influence = Math.max(0, 1 - distance / magnificationRadius)
    return 1 + (hoverScale - 1) * influence * influence
  }

  function iconSource() {
    if (root.iconSourceOverride) return root.iconSourceOverride
    var name = IconResolver.resolveIcon(itemData)
    if (String(name).indexOf("/") === 0) return Util.fileUrl(name)
    if (String(name).indexOf("file:") === 0 || String(name).indexOf("image:") === 0) return name
    return Quickshell.iconPath(name, true)
  }

  Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
  scale: root.isDragging ? 1.16 : proximityScale

  Translate {
    id: dragTranslation
    x: (root.isDragging ? root.dragOffsetX : 0) + root.layoutShift
    y: root.isDragging ? -10 : 0
  }
  property real dragOffsetX: 0
  Behavior on layoutShift { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on dragOffsetX { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

  Image {
    id: icon
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    width: root.iconSize
    height: root.iconSize
    source: root.iconSource()
    sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    cache: false

    Text {
      anchors.centerIn: parent
      visible: parent.status !== Image.Ready
      text: "◆"
      color: Color.foreground
      font.pixelSize: root.iconSize * 0.42
    }
  }

  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: icon.bottom
    anchors.topMargin: 4
    width: 5
    height: 5
    radius: 3
    color: Color.accent
    visible: !!root.itemData.running
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: {
      root.tooltipVisible = true
      root.tooltipRequested(root.itemData, true, root.mapToItem(null, root.width / 2, 0).x)
      root.hoverPointerChanged(root.itemData, true, root.mapToItem(null, mouse.x, mouse.y).x)
    }
    onExited: {
      root.tooltipVisible = false
      root.tooltipRequested(root.itemData, false, root.mapToItem(null, root.width / 2, 0).x)
      root.hoverPointerChanged(root.itemData, false, root.mapToItem(null, mouse.x, mouse.y).x)
    }
    onPressed: root.pressPosition = Qt.point(mouseX, mouseY)
    onPositionChanged: {
      if (!pressed) root.hoverPointerChanged(root.itemData, true, root.mapToItem(null, mouse.x, mouse.y).x)
      if (pressed && !root.isDragging && Math.hypot(mouseX - root.pressPosition.x, mouseY - root.pressPosition.y) >= 6)
        root.isDragging = true
      if (pressed && root.isDragging) {
        root.dragOffsetX = mouseX - root.pressPosition.x
        root.dragMoved(root.itemData, root.mapToItem(null, mouse.x, mouse.y))
      }
    }
    onReleased: function(mouse) {
      var right = mouse.button === Qt.RightButton
      if (right) {
      root.itemRightClicked(root.itemData, root.mapToItem(null, mouse.x, mouse.y))
      } else if (!root.isDragging) {
        root.itemLeftClicked(root.itemData)
      } else {
        root.dragFinished(root.itemData, root.mapToItem(null, mouse.x, mouse.y))
      }
      root.isDragging = false
      root.dragOffsetX = 0
    }
  }
}
