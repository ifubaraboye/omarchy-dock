import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// A single window card inside the hover preview. Prefer a live compositor
// capture at the window's native source resolution. The preview card is much
// smaller than the source window, so the compositor/GPU can downsample it
// instead of displaying a pre-scaled 304x184 screenshot. Cached thumbnails
// remain the fallback when direct toplevel capture is unavailable.
Item {
  id: root

  required property var windowData
  property string iconSource: ""
  property string thumbnail: ""
  property bool active: false
  property bool animationEnabled: true
  property var captureToplevel: null

  signal activated(var windowData)

  width: 168
  height: 144

  function resolveToplevel() {
    var wanted = String(root.windowData && root.windowData.address ? root.windowData.address : "")
    if (!wanted) return null
    try {
      var values = Hyprland.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var candidate = values[i]
        if (String(candidate && candidate.address ? candidate.address : "") === wanted)
          return candidate
      }
    } catch (error) {}
    return null
  }

  Component.onCompleted: root.captureToplevel = root.resolveToplevel()

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      root.captureToplevel = root.resolveToplevel()
    }
  }

  Rectangle {
    id: card
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 118
    radius: 14
    color: Util.alpha(Color.background, 0.96)
    border.color: root.active ? Util.alpha(Color.accent, 0.85) : Util.alpha(Color.foreground, 0.15)
    border.width: root.active ? 2 : 1

    Behavior on border.color { ColorAnimation { duration: 150 } }
    Behavior on scale {
      enabled: root.animationEnabled
      SpringAnimation { spring: 3.2; damping: 0.29; mass: 1 }
    }

    // Direct compositor capture is the primary source. ScreencopyView keeps
    // the source at the window's native resolution, then the scene renders it
    // into this small card. Quickshell 0.3.0 also fixed the scaled
    // ScreencopyView pixelation issue, so this avoids the old low-resolution
    // cached-frame path on current Omarchy/Quickshell builds.
    ScreencopyView {
      id: livePreview
      anchors.fill: parent
      anchors.margins: 8
      captureSource: root.captureToplevel ? root.captureToplevel.wayland : null
      live: true
      paintCursor: false
      visible: root.captureToplevel !== null
      clip: true
    }

    // Cached screenshots remain useful as a fallback if the compositor cannot
    // expose a Wayland toplevel for this window.
    Image {
      id: cachedThumbnail
      anchors.fill: parent
      anchors.margins: 8
      visible: !livePreview.visible && root.thumbnail !== ""
      source: root.thumbnail
      sourceSize: Qt.size(304, 184)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      clip: true
    }

    Item {
      visible: !livePreview.visible && !cachedThumbnail.visible
      anchors.fill: parent
      anchors.margins: 8

      Rectangle {
        id: iconBackdrop
        anchors.fill: parent
        radius: 9
        color: Util.alpha(Color.foreground, 0.06)
      }

      Image {
        id: iconImage
        anchors.centerIn: parent
        width: 64
        height: 64
        source: root.iconSource
        sourceSize: Qt.size(128, 128)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true

        Text {
          anchors.centerIn: parent
          visible: parent.status !== Image.Ready
          text: "◆"
          color: Color.foreground
          font.pixelSize: 26
        }
      }
    }

    Rectangle {
      anchors.fill: parent
      anchors.margins: 8
      radius: 9
      color: "transparent"
      border.width: 1
      border.color: Util.alpha(Color.foreground, 0.10)
    }
  }

  Text {
    id: titleText
    anchors { top: card.bottom; left: parent.left; right: parent.right }
    height: 22
    topPadding: 4
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignHCenter
    text: root.windowData && root.windowData.title ? root.windowData.title : ""
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: {
      card.scale = 1.05
      card.z = 1
    }
    onExited: {
      card.scale = 1
      card.z = 0
    }
    onClicked: root.activated(root.windowData)
  }
}
