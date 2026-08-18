import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "DockModel.js" as DockModel
import "IconResolver.js" as IconResolver

Item {
  id: root

  property var shell: null
  property var pluginRegistry: null
  property var manifest: null
  property string home: Quickshell.env("HOME")
  property string iconDir: home + "/.config/omarchy/icons"
  property string iconMapPath: home + "/.config/omarchy/dock-icons.json"
  property string pinPath: home + "/.config/omarchy/dock-pinned-macos.json"
  property string tempPinPath: pinPath + ".tmp"
  property var pinnedIds: []
  property var appEntries: []
  property var runningIds: []
  property var dockItems: []
  property bool appLibraryReady: false
  property bool conflictDetected: false
  property bool dockHovered: false
  property bool menuOpen: false
  property bool enabled: true
  property bool dockReady: false
  // Keep the prototype visible while validating layout and interaction. The
  // slide-away behavior remains available for a later settings toggle.
  property bool autoHide: false
  property int dockHeight: 101
  property int bottomMargin: 22
  property int iconSize: 50
  property real hoveredMouseX: -1
  property string hoveredItemId: ""
  property var tooltipItem: null
  property real tooltipCenterX: 0
  property string draggingItemId: ""
  property int draggingFromIndex: -1
  property int draggingTargetIndex: -1
  property string pendingFocusTarget: ""
  property string pendingCursorPosition: ""
  property var customIcons: ({})
  property int customIconRevision: 0

  IpcHandler {
    target: "macos.dock"
    function toggle() { root.enabled = !root.enabled }
    function show() { root.enabled = true }
    function hide() { root.enabled = false }
  }

  function normalizeRunning() {
    var output = []
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var item = values[i]
        var id = root.desktopIdForWindow(item)
        if (id && output.indexOf(id) === -1) output.push(id)
      }
    } catch (error) {}
    return output
  }

  function desktopIdForWindow(window) {
    var raw = String(window.appId || window.desktopId || window.className || window.initialClass || "").replace(/\.desktop$/, "")
    var lower = raw.toLowerCase()
    for (var i = 0; i < root.appEntries.length; i++) {
      var entry = root.appEntries[i] || {}
      var id = String(entry.id || "").replace(/\.desktop$/, "")
      var name = String(entry.name || "").toLowerCase()
      if (id && id.toLowerCase() === lower) return id
      if (name && lower.indexOf(name) !== -1) return id
    }
    return raw
  }

  function hyprlandWindowFor(window) {
    var targetId = String(window.appId || window.desktopId || window.className || window.initialClass || "").toLowerCase()
    var targetTitle = String(window.title || "")
    var fallback = null
    try {
      var values = Hyprland.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var candidate = values[i]
        var ids = []
        if (candidate.wayland && candidate.wayland.appId) ids.push(String(candidate.wayland.appId).toLowerCase())
        var ipc = candidate.lastIpcObject || {}
        if (ipc.appId) ids.push(String(ipc.appId).toLowerCase())
        if (ipc["class"]) ids.push(String(ipc["class"]).toLowerCase())
        if (ipc.initialClass) ids.push(String(ipc.initialClass).toLowerCase())
        if (ids.indexOf(targetId) === -1) continue
        if (targetTitle && candidate.title === targetTitle) return candidate
        if (!fallback) fallback = candidate
      }
    } catch (error) {}
    return fallback
  }

  function hyprlandWindowForItem(item) {
    if (!item) return null
    var fallback = null
    try {
      var values = Hyprland.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var candidate = values[i]
        var ids = []
        if (candidate.wayland && candidate.wayland.appId) ids.push(String(candidate.wayland.appId).toLowerCase())
        var ipc = candidate.lastIpcObject || {}
        if (ipc.appId) ids.push(String(ipc.appId).toLowerCase())
        if (ipc["class"]) ids.push(String(ipc["class"]).toLowerCase())
        if (ipc.initialClass) ids.push(String(ipc.initialClass).toLowerCase())
        for (var j = 0; j < ids.length; j++) {
          if (ids[j] === String(item.id).toLowerCase()) return candidate
          if (root.desktopIdForWindow({ appId: ids[j], title: candidate.title }) === item.id) {
            if (!fallback) fallback = candidate
          }
        }
      }
    } catch (error) {}
    return fallback
  }

  function focusExistingWindow(hyprWindow) {
    if (!hyprWindow || !hyprWindow.address) return false

    // This Omarchy build uses Hyprland's Lua dispatcher syntax. The older
    // `workspace ...` / `focuswindow ...` strings are parsed as Lua and fail.
    // Focusing by address also switches to the window's workspace without
    // going through Toplevel.activate(), which can warp the pointer.
    var address = String(hyprWindow.address)
    if (address.indexOf("0x") !== 0) address = "0x" + address
    root.pendingFocusTarget = "address:" + address
    restoreCursorWarps.stop()
    if (!cursorCaptureProcess.running) cursorCaptureProcess.running = true
    return true
  }

  function refreshApps() {
    if (!root.shell || !root.shell.appLibrary) return
    try {
      var rows = root.shell.appLibrary.sortedEntries("") || []
      // AppLibrary returns sorted rows shaped as { entry, score, key, name }.
      // Keep only the underlying desktop entries for dock lookup.
      root.appEntries = rows.map(function(row) { return row && row.entry ? row.entry : row })
      root.appLibraryReady = true
    } catch (error) {
      console.warn("macos.dock: app library refresh failed", error)
    }
    refreshItems()
  }

  function refreshItems() {
    root.runningIds = normalizeRunning()
    root.dockItems = DockModel.buildDockItems(root.pinnedIds, root.appEntries, root.runningIds)
  }

  function checkDockConflict() {
    var registry = root.pluginRegistry || (root.shell ? root.shell.pluginRegistry : null)
    var conflict = false
    if (registry && typeof registry.isEnabled === "function") {
      try { conflict = registry.isEnabled("rosakodu.dock") } catch (error) {}
    }
    root.conflictDetected = conflict
    if (conflict) root.notifyConflict()
  }

  function notifyConflict() {
    if (conflictNotice.running) return
    conflictNotice.running = true
    Quickshell.execDetached(["omarchy-shell", "notify", "macos.dock is disabled because rosakodu.dock is enabled"])
  }

  function handleClick(item) {
    if (!item || item.separator) return
    if (item.running) {
      try {
        // Never fall back to Toplevel.activate() here: it can warp the cursor.
        // Existing windows must be focused through Hyprland's IPC path.
        var hyprWindow = root.hyprlandWindowForItem(item)
        if (!root.focusExistingWindow(hyprWindow))
          console.warn("macos.dock: could not resolve running window for " + item.id)
        return
      } catch (error) {}
    }
    var entry = DockModel.entryFor(item.id, root.appEntries)
    if (root.shell && root.shell.appLibrary && typeof root.shell.appLibrary.launch === "function")
      root.shell.appLibrary.launch(item.id, entry.name || item.name)
  }

  Timer {
    id: restoreCursorWarps
    interval: 80
    onTriggered: {
      var match = String(root.pendingCursorPosition).match(/(-?\d+)\s*,\s*(-?\d+)/)
      if (match)
        Hyprland.dispatch("hl.dsp.cursor.move({ x = " + match[1] + ", y = " + match[2] + " })")
      root.pendingCursorPosition = ""
      Quickshell.execDetached(["hyprctl", "eval", "hl.config({ cursor = { no_warps = false } })"])
    }
  }

  Process {
    id: cursorCaptureProcess
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pendingCursorPosition = text.trim()
        if (!focusNoWarpProcess.running) focusNoWarpProcess.running = true
      }
    }
  }

  Process {
    id: focusNoWarpProcess
    command: ["hyprctl", "eval", "hl.config({ cursor = { no_warps = true } })"]
    onExited: {
      if (!root.pendingFocusTarget) return
      var target = root.pendingFocusTarget
      root.pendingFocusTarget = ""
      Hyprland.dispatch("hl.dsp.focus({ window = \"" + target + "\" })")
      Qt.callLater(function() { Hyprland.dispatch("hl.dsp.window.bring_to_top()") })
      restoreCursorWarps.restart()
    }
  }

  function savePinned() {
    var content = DockModel.serializePinned(root.pinnedIds)
    DockModel.markWritten(content)
    tempWriter.path = root.tempPinPath
    tempWriter.setText(content)
    Qt.callLater(function() { renameProcess.running = true })
  }

  function openMenu(item, position) {
    root.tooltipItem = null
    root.menuOpen = true
    dockMenu.itemData = item
    dockMenu.requestedPosition = Qt.point(position.x, position.y - dockMenu.height - 12)
    dockMenu.opened = true
  }

  function menuAction(action, item) {
    if (!item) return
    if (action === "togglePin") root.pinnedIds = DockModel.togglePinned(root.pinnedIds, item.id)
    else if (action === "newWindow") handleClick({ id: item.id, name: item.name, running: false })
    else if (action === "close") closeWindow(item.id)
    if (action === "togglePin") { refreshItems(); savePinned() }
  }

  function closeWindow(id) {
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = values.length - 1; i >= 0; i--) {
        var window = values[i]
        var windowId = String(window.appId || window.desktopId || window.className || "").replace(/\.desktop$/, "")
        if (windowId === id && typeof window.close === "function") { window.close(); return }
      }
    } catch (error) {}
  }

  function finishDrag(item, position) {
    if (!item || !item.pinned) return
    var fromIndex = root.pinnedIds.indexOf(item.id)
    if (fromIndex < 0 || root.pinnedIds.length < 2) { root.clearDragState(); return }

    var localX = dockRow.mapFromItem(null, position.x, position.y).x
    var slotWidth = 58 + dockRow.spacing
    var targetIndex = Math.round((localX - 30) / slotWidth)
    targetIndex = Math.max(0, Math.min(root.pinnedIds.length - 1, targetIndex))
    if (targetIndex === fromIndex) { root.clearDragState(); return }

    root.pinnedIds = DockModel.reorderPinned(root.pinnedIds, fromIndex, targetIndex)
    root.refreshItems()
    root.savePinned()
    root.clearDragState()
  }

  function clearDragState() {
    root.draggingItemId = ""
    root.draggingFromIndex = -1
    root.draggingTargetIndex = -1
  }

  function dragTargetFor(position) {
    var localX = dockRow.mapFromItem(null, position.x, position.y).x
    var slotWidth = 58 + dockRow.spacing
    return Math.max(0, Math.min(root.pinnedIds.length - 1, Math.round((localX - 30) / slotWidth)))
  }

  function updateDrag(item, position) {
    if (!item || !item.pinned) return
    if (root.draggingItemId !== item.id) {
      root.draggingItemId = item.id
      root.draggingFromIndex = root.pinnedIds.indexOf(item.id)
    }
    root.draggingTargetIndex = root.dragTargetFor(position)
  }

  function layoutShiftFor(id) {
    var index = root.pinnedIds.indexOf(id)
    if (index < 0 || root.draggingFromIndex < 0 || root.draggingTargetIndex < 0 || id === root.draggingItemId) return 0
    var slot = 58 + dockRow.spacing
    if (root.draggingFromIndex < root.draggingTargetIndex && index > root.draggingFromIndex && index <= root.draggingTargetIndex) return -slot
    if (root.draggingFromIndex > root.draggingTargetIndex && index >= root.draggingTargetIndex && index < root.draggingFromIndex) return slot
    return 0
  }

  function showTooltip(item, show) {
    if (show) {
      tooltipItem = item
      tooltipVisible = true
    } else if (tooltipItem && tooltipItem.id === item.id) {
      tooltipVisible = false
      tooltipItem = null
    }
  }

  function loadCustomIcons(content) {
    var parsed = {}
    try {
      var value = JSON.parse(String(content || "{}"))
      if (value && typeof value === "object" && !Array.isArray(value)) parsed = value
    } catch (error) {
      console.warn("macos.dock: invalid dock-icons.json")
    }
    root.customIcons = parsed
    root.customIconRevision++
  }

  function customIconSourceFor(item) {
    var file = IconResolver.customIconFile(root.customIcons, item && item.id)
    if (!file) return ""
    // The revision prevents QML from retaining an older image after a file
    // is replaced with the same filename.
    return Util.fileUrl(root.iconDir + "/" + file) + "?v=" + root.customIconRevision
  }

  function iconSourceFor(item) {
    var customSource = root.customIconSourceFor(item)
    if (customSource) return customSource
    var entry = DockModel.entryFor(item && item.id, root.appEntries)
    var iconName = entry.icon || entry.iconName || entry.appIcon || ""
    if (root.shell && root.shell.appLibrary && iconName && typeof root.shell.appLibrary.iconSource === "function") {
      var resolved = root.shell.appLibrary.iconSource(iconName)
      if (resolved && String(resolved).indexOf("application-x-executable") === -1) return resolved
      var fallbackName = IconResolver.resolveIcon(entry)
      if (fallbackName && fallbackName !== iconName) {
        resolved = root.shell.appLibrary.iconSource(fallbackName)
        if (resolved && String(resolved).indexOf("application-x-executable") === -1) return resolved
      }
    }
    return ""
  }

  Timer { id: conflictNotice; interval: 30000 }
  Timer { id: tooltipDelay; interval: 400; onTriggered: tooltipVisible = true }
  property bool tooltipVisible: false

  FileView {
    id: customIconsFile
    path: root.iconMapPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadCustomIcons(text())
    onFileChanged: root.loadCustomIcons(text())
    onLoadFailed: root.loadCustomIcons("{}")
  }

  FileView {
    id: pinFile
    path: root.pinPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.pinnedIds = DockModel.parsePinned(text(), DockModel.DEFAULT_PINNED)
      root.refreshItems()
    }
    onFileChanged: {
      if (!DockModel.shouldReprocess(text())) return
      root.pinnedIds = DockModel.parsePinned(text(), root.pinnedIds)
      root.refreshItems()
    }
    onLoadFailed: {
      root.pinnedIds = DockModel.DEFAULT_PINNED.slice()
      root.refreshItems()
    }
  }

  FileView {
    id: tempWriter
    watchChanges: false
    printErrors: false
  }

  Process {
    id: renameProcess
    command: ["mv", root.tempPinPath, root.pinPath]
    onExited: root.refreshItems()
  }

  Connections {
    target: root.shell ? root.shell.appLibrary : null
    function onAppsChanged() { root.refreshApps() }
  }
  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.refreshItems() }
  }
  Connections {
    target: root.pluginRegistry
    function onPluginsChanged() { root.checkDockConflict() }
    function onScanFinished() { root.checkDockConflict() }
  }

  Component.onCompleted: {
    root.checkDockConflict()
    root.refreshApps()
    root.refreshItems()
    Qt.callLater(function() { root.dockReady = true })
  }

  PanelWindow {
    id: dockWindow
    visible: !root.conflictDetected && root.enabled
    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "macos-dock"
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: dockSurface }

      Rectangle {
      id: dockSurface
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: root.autoHide && !root.enabled ? -root.dockHeight + 14 : root.bottomMargin
      width: dockRow.width + 36
      height: root.dockHeight
      radius: 22
      color: Util.alpha(Color.background, 0.88)
      border.color: Util.alpha(Color.foreground, 0.20)
      border.width: 1
      opacity: root.autoHide && !root.enabled ? 0.55 : (root.menuOpen || root.dockHovered ? 1 : 0.96)

      Behavior on anchors.bottomMargin {
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
      }
      Behavior on opacity { NumberAnimation { duration: 180 } }

      Row {
        id: dockRow
        anchors.centerIn: parent
        anchors.verticalCenterOffset: 6
        spacing: 8

        Repeater {
          model: root.dockItems
          delegate: Item {
            required property var modelData
            width: modelData.separator ? 14 : 58
            height: 70

            Rectangle {
              visible: !!modelData.separator
              anchors.centerIn: parent
              width: 1
              height: 34
              color: Util.alpha(Color.foreground, 0.22)
            }

            DockItem {
              visible: !modelData.separator
              anchors.centerIn: parent
              itemData: modelData
              iconSize: root.iconSize
              mouseDistance: root.hoveredMouseX < 0 ? 9999 : root.hoveredMouseX - mapToItem(null, width / 2, 0).x
              iconSourceOverride: root.iconSourceFor(modelData)
              layoutShift: root.layoutShiftFor(modelData.id)
              onItemLeftClicked: function(clickedItem) { root.handleClick(clickedItem) }
              onItemRightClicked: function(clickedItem, position) { root.openMenu(clickedItem, position) }
              onDragMoved: function(draggedItem, position) { root.updateDrag(draggedItem, position) }
              onDragFinished: function(draggedItem, position) { root.finishDrag(draggedItem, position) }
              onTooltipRequested: function(hoveredItem, isVisible, centerX) {
                root.tooltipCenterX = centerX
                root.showTooltip(hoveredItem, isVisible)
              }
              onHoverPointerChanged: function(hoveredItem, isInside, pointerX) {
                if (isInside) {
                  root.hoveredItemId = hoveredItem.id
                  root.hoveredMouseX = pointerX
                  root.tooltipCenterX = pointerX
                } else if (root.hoveredItemId === hoveredItem.id) {
                  root.hoveredItemId = ""
                  root.hoveredMouseX = -1
                }
              }
            }
          }
        }

      }

      MouseArea {
        id: mouseArea
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        onEntered: { root.dockHovered = true; root.enabled = true; hideTimer.stop() }
        onExited: {
          root.dockHovered = false
          if (root.autoHide && root.dockReady) hideTimer.restart()
        }
      }
    }

    Rectangle {
      visible: root.tooltipVisible && root.tooltipItem !== null
      z: 20
      x: Math.max(12, Math.min(root.tooltipCenterX - width / 2, parent.width - width - 12))
      y: dockSurface.y - height - 8
      width: tooltipText.implicitWidth + 24
      height: 30
      radius: 9
      color: Util.alpha(Color.background, 0.96)
      border.color: Util.alpha(Color.foreground, 0.15)
      Text {
        id: tooltipText
        anchors.centerIn: parent
        text: root.tooltipItem ? (root.tooltipItem.name || root.tooltipItem.id) : ""
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: 18
      hoverEnabled: true
      onEntered: { root.dockHovered = true; hideTimer.stop() }
      onExited: { root.dockHovered = false; hideTimer.restart() }
    }
  }

  Timer {
    id: hideTimer
    interval: 2000
    onTriggered: if (root.autoHide && !root.menuOpen && !root.dockHovered) root.enabled = false
  }

  DockMenu {
    id: dockMenu
    onActionTriggered: function(actionName, selectedItem) { root.menuAction(actionName, selectedItem) }
    onOpenedChanged: if (!opened) root.menuOpen = false
  }
}
