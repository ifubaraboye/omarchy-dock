import QtQuick
import Quickshell
import qs.Commons
import "IconResolver.js" as IconResolver

Item {
  id: root

  required property var itemData
  property int iconSize: 52
  // Targets driven by the panel's layout engine. Every change is animated so
  // nothing ever teleports.
  property real targetScale: 1
  property real targetLift: 0
  property real targetOpacity: 1
  property bool animationEnabled: true
  property bool isDragging: false
  property bool leftPressed: false
  property bool tooltipVisible: false
  property string iconSourceOverride: ""
  property point pressPosition: Qt.point(0, 0)
  // macOS-style launch bounce: isolated vertical offset added on top of the
  // hover lift so magnification/scale are never disturbed. Spring-like damped
  // motion (explicit decaying keyframes, ~950ms total, 3 upward impulses).
  property real launchBounceHeight: 28
  property real bounceOffset: 0
  signal launchBounceFinished()

  signal dragMoved(var itemData, point position)
  signal dragFinished(var itemData, point position)
  signal itemLeftClicked(var itemData)
  signal itemRightClicked(var itemData, point position)
  signal tooltipRequested(var itemData, bool visible, real centerX)
  signal hoverPointerChanged(var itemData, bool inside, real pointerX)

  width: iconSize + 8
  height: iconSize + 18

  function iconSource() {
    if (root.iconSourceOverride) return root.iconSourceOverride
    var name = IconResolver.resolveIcon(itemData)
    if (String(name).indexOf("/") === 0) return Util.fileUrl(name)
    if (String(name).indexOf("file:") === 0 || String(name).indexOf("image:") === 0) return name
    return Quickshell.iconPath(name, true)
  }

  Behavior on scale {
    enabled: root.animationEnabled
    SpringAnimation { spring: 4.5; damping: 0.95; mass: 1 }
  }
  scale: root.targetScale

  Behavior on y {
    enabled: root.animationEnabled
    SpringAnimation { spring: 4.5; damping: 0.95; mass: 1 }
  }
  y: -root.targetLift + root.bounceOffset

  Behavior on opacity {
    enabled: root.animationEnabled
    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
  }
  opacity: root.targetOpacity

  // One-shot launch bounce. Runs to completion once started; never driven by
  // the running state, so a mid-animation state refresh cannot restart it.
  // Always finishes at exactly 0 so hover lift positioning is never corrupted.
  SequentialAnimation {
    id: launchBounceAnim
    NumberAnimation { target: root; property: "bounceOffset"; from: 0; to: -root.launchBounceHeight; duration: 180; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "bounceOffset"; from: -root.launchBounceHeight; to: 0; duration: 170; easing.type: Easing.InCubic }
    NumberAnimation { target: root; property: "bounceOffset"; from: 0; to: -root.launchBounceHeight * 0.55; duration: 150; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "bounceOffset"; from: -root.launchBounceHeight * 0.55; to: 0; duration: 150; easing.type: Easing.InCubic }
    NumberAnimation { target: root; property: "bounceOffset"; from: 0; to: -root.launchBounceHeight * 0.25; duration: 140; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "bounceOffset"; from: -root.launchBounceHeight * 0.25; to: 0; duration: 160; easing.type: Easing.InOutCubic }
    onFinished: {
      root.bounceOffset = 0
      root.launchBounceFinished()
    }
  }

  function playLaunchBounce() {
    if (!root.animationEnabled || root.isDragging) return false
    if (launchBounceAnim.running) return false
    launchBounceAnim.restart()
    return true
  }

  function cancelLaunchBounce() {
    launchBounceAnim.stop()
    root.bounceOffset = 0
  }

  Image {
    id: icon
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    width: root.iconSize
    height: root.iconSize
    source: root.iconSource()
    sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
    fillMode: Image.PreserveAspectFit
    cache: true

    Text {
        textFormat: Text.PlainText
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
    anchors.topMargin: 2
    width: 4
    height: 4
    radius: 2
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
      root.hoverPointerChanged(root.itemData, true, root.mapToItem(null, mouseX, mouseY).x)
    }
    onExited: {
      root.tooltipVisible = false
      root.tooltipRequested(root.itemData, false, root.mapToItem(null, root.width / 2, 0).x)
      root.hoverPointerChanged(root.itemData, false, root.mapToItem(null, mouseX, mouseY).x)
    }
    onPressed: function(mouse) {
      root.leftPressed = mouse.button === Qt.LeftButton
      root.pressPosition = Qt.point(mouseX, mouseY)
    }
    onPositionChanged: {
      if (!pressed) {
        root.hoverPointerChanged(root.itemData, true, root.mapToItem(null, mouseX, mouseY).x)
        return
      }
      if (root.leftPressed && !root.isDragging && Math.hypot(mouseX - root.pressPosition.x, mouseY - root.pressPosition.y) >= 6)
        root.isDragging = true
      if (root.leftPressed && root.isDragging)
        root.dragMoved(root.itemData, Qt.point(mouseX, mouseY))
    }
    onReleased: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        root.itemRightClicked(root.itemData, root.mapToItem(null, mouseX, mouseY))
      } else if (!root.isDragging) {
        root.itemLeftClicked(root.itemData)
      } else {
        root.dragFinished(root.itemData, Qt.point(mouseX, mouseY))
      }
      root.isDragging = false
      root.leftPressed = false
    }
  }
}
