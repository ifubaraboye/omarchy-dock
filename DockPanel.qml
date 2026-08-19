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
  property var dockOrder: []
  property bool pinFileLoaded: false
  // Our temp+rename writes make the pin-file watcher fire before FileView's
  // async re-read finishes, so onFileChanged can observe stale text(). The
  // reload() path re-reads fresh, and this window skips watcher events that
  // belong to our own save cycles entirely.
  property double ownWriteUntil: 0
  property var appEntries: []
  property var runningIds: []
  // Most-recently-used app ids, front = most recent. Maintained from focus
  // changes; powers the Alt+Tab switcher ordering (an app switcher cycles by
  // recency, not by the dock's pinned-first visual order).
  property var mruIds: []
  // Repeater model: stable id strings. Replaced only when the id set changes
  // (apps opened/closed); reorders and pin/running toggles never touch it, so
  // no delegate is torn down by dragging or state changes.
  property var dockItems: []
  property bool appLibraryReady: false
  property bool conflictDetected: false
  property bool dockHovered: false
  property bool menuOpen: false
  property bool enabled: true
  onEnabledChanged: if (!root.enabled) root.hidePreview()
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
  property string pendingFocusTarget: ""
  property string pendingCursorPosition: ""
  property var customIcons: ({})
  property int customIconRevision: 0
  property var nativeIconCache: ({})
  property var nativeIconPending: ({})
  property var nativeIconQueue: []
  property var currentNativeIconJob: null
  property int nativeIconRevision: 0

  // Layout & drag state. The Repeater model (dockItems) is the stable identity
  // list of ids, replaced only when the id set changes; reorders go through
  // applyLayout(), which only mutates existing delegates, so no delegate is
  // ever torn down by dragging. Mutable pinned/running state lives in each
  // delegate's liveData binding so state changes never rebuild the Repeater.
  property int slotWidth: 58
  property int slotSpacing: 8
  property int sidePadding: 18
  property int separatorWidth: 14
  property string floatingId: ""
  property var tempDrag: ({ id: "", index: -1 })
  property var placements: ({})
  property real layoutWidth: 0
  property var visualCache: ({})
  property var delegateById: ({})
  property string ghostSource: ""
  property real ghostX: 0
  property real ghostY: 0
  property real ghostScale: 1.18
  property real ghostOpacity: 1
  property bool ghostSettling: false
  // Drop-inside state, tracked per-frame in onDragMoved from the cursor's
  // dockSurface-local position. Mapping item-to-item inside the same window
  // avoids the PanelWindow's output-anchored scene space entirely, so the
  // check is a plain AABB against the surface the input mask hit-tests.
  property bool dragInsideDock: true

  IpcHandler {
    target: "macos.dock"
    function toggle() { root.enabled = !root.enabled }
    function show() { root.enabled = true }
    function hide() { root.enabled = false }
    function altTabNext() { root.altTabNext() }
    function altTabPrev() { root.altTabPrev() }
    function altTabCancel() { root.altTabCancel() }
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

  function focusWindowAddress(address) {
    if (!address) return false
    // This Omarchy build uses Hyprland's Lua dispatcher syntax. The older
    // `workspace ...` / `focuswindow ...` strings are parsed as Lua and fail.
    // Focusing by address also switches to the window's workspace without
    // going through Toplevel.activate(), which can warp the pointer.
    var normalized = String(address)
    if (normalized.indexOf("0x") !== 0) normalized = "0x" + normalized
    root.pendingFocusTarget = "address:" + normalized
    restoreCursorWarps.stop()
    if (!cursorCaptureProcess.running) cursorCaptureProcess.running = true
    return true
  }

  function focusExistingWindow(hyprWindow) {
    if (!hyprWindow || !hyprWindow.address) return false
    return root.focusWindowAddress(hyprWindow.address)
  }

  onShellChanged: if (root.shell) root.refreshApps()

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
    // The session order is authoritative: it preserves drag rearrangements of
    // any app (pinned or running) while dropping apps that closed and
    // appending newly opened ones. Pinned apps stay pinned; running apps are
    // never promoted into the pinned list by dragging.
    var prevOrder = root.dockOrder.join("|")
    root.dockOrder = DockModel.reconcileDockOrder(root.dockOrder, root.pinnedIds, root.runningIds)
    // The layout file mirrors the session order; persist it (debounced) when
    // the order changes so a restart restores the exact interleaving. Wait
    // until the pin file has been read so a slow boot never clobbers it.
    if (root.pinFileLoaded && root.dockOrder.join("|") !== prevOrder)
      persistTimer.restart()
    // Reassign the Repeater model only when the set of ids changed (apps
    // opened/closed, pin file reloaded). A reorder or a pin/running toggle
    // must never touch the model: replacing a JS array model destroys and
    // recreates every delegate. Delegate positions are driven by
    // placements[id] in applyLayout(), so the model's order is irrelevant.
    if (!root.floatingId) {
      if (!root.sameIdSet(root.dockOrder, root.dockItems))
        root.dockItems = root.dockOrder.slice()
    }
    root.applyLayout()
  }

  // Order-insensitive id-set equality: the model must survive reorders and
  // state changes, and only grow/shrink on actual membership changes.
  function sameIdSet(a, b) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      if (b.indexOf(a[i]) === -1) return false
    }
    return true
  }

  function cursorXInRow() {
    if (root.hoveredMouseX < 0) return -1
    return dockRow.mapFromItem(null, root.hoveredMouseX, 0).x
  }

  // Leaving the dock over a gap or the surface padding never triggers a
  // DockItem exit, so reset the hover state here or icons stay magnified.
  function clearHover() {
    if (root.floatingId) return // the drag controller owns hoveredMouseX
    root.hoveredItemId = ""
    root.hoveredMouseX = -1
    root.applyLayout()
  }

  function registerItem(id, item) { root.delegateById[id] = item }
  function unregisterItem(id) { delete root.delegateById[id] }

  // Live metadata for a dock id, mirrored from the observable root state so a
  // delegate's itemData updates in place instead of the Repeater rebuilding.
  function appNameFor(id) {
    var entry = DockModel.entryFor(id, root.appEntries)
    return entry.name || entry.displayName || id
  }

  function appIconNameFor(id) {
    var entry = DockModel.entryFor(id, root.appEntries)
    return entry.icon || entry.iconName || ""
  }

  // New delegates seed their animated properties from the item's last visual
  // state so a structural rebuild never pops.
  function seedFor(id) {
    var cached = root.visualCache[id]
    if (cached) return cached
    var p = root.placements[id]
    return { x: p ? p.x : 0, scale: p ? p.scale : 1, lift: p ? p.lift : 0 }
  }

  function applyLayout() {
    var cursorX = root.cursorXInRow()
    var baseFlow = DockModel.buildFlow(root.dockOrder, [], root.floatingId, -1)
    if (root.floatingId && cursorX >= 0)
      root.tempDrag.index = DockModel.insertionIndexFor(cursorX, baseFlow, DockModel.LAYOUT_OPTS)
    var flow = DockModel.buildFlow(
      root.dockOrder,
      [],
      root.floatingId,
      root.floatingId ? root.tempDrag.index : -1
    )
    var result = DockModel.computeLayout(flow, cursorX, DockModel.LAYOUT_OPTS)
    root.placements = result.placements
    root.layoutWidth = result.totalWidth
    for (var id in result.placements) {
      var p = result.placements[id]
      var d = root.delegateById[id]
      if (!d) continue
      d.x = p.x
      d.targetScale = p.scale
      d.targetLift = p.lift
      d.targetOpacity = (id === root.floatingId) ? 0 : (p.phantom ? 0.45 : 1)
    }
    // The dragged item is excluded from the flow so it has no placement; hide
    // its dock copy while the ghost follows the cursor.
    if (root.floatingId && root.delegateById[root.floatingId])
      root.delegateById[root.floatingId].targetOpacity = 0
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
    if (!item) return
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

  // ---- Alt+Tab app switcher -------------------------------------------------
  // The switcher is an app switcher, so recency is tracked per application
  // (not per window). The dock's visual order (pinned first) is irrelevant
  // here: focus history drives the cycle order.

  function dockIdForHyprlandWindow(window) {
    try {
      var ids = []
      if (window.wayland && window.wayland.appId) ids.push(String(window.wayland.appId).toLowerCase())
      var ipc = window.lastIpcObject || {}
      if (ipc.appId) ids.push(String(ipc.appId).toLowerCase())
      if (ipc["class"]) ids.push(String(ipc["class"]).toLowerCase())
      if (ipc.initialClass) ids.push(String(ipc.initialClass).toLowerCase())
      for (var i = 0; i < ids.length; i++) {
        var resolved = root.desktopIdForWindow({ appId: ids[i] })
        if (resolved) return resolved
      }
    } catch (error) {}
    return ""
  }

  function touchMru(id) {
    if (!id) return
    var list = root.mruIds.slice(0)
    var i = list.indexOf(id)
    if (i >= 0) list.splice(i, 1)
    list.unshift(id)
    root.mruIds = list
  }

  function altTabAppData(id) {
    var entry = DockModel.entryFor(id, root.appEntries)
    var name = entry && entry.name ? entry.name : IconResolver.sanitizeName(id)
    return { id: id, name: name }
  }

  // MRU order first, then any running app never focused since shell start.
  function buildAltTabApps() {
    var apps = []
    var seen = {}
    for (var i = 0; i < root.mruIds.length; i++) {
      var id = root.mruIds[i]
      if (root.runningIds.indexOf(id) === -1 || seen[id]) continue
      seen[id] = true
      apps.push(root.altTabAppData(id))
    }
    for (var j = 0; j < root.runningIds.length; j++) {
      var rid = root.runningIds[j]
      if (seen[rid]) continue
      seen[rid] = true
      apps.push(root.altTabAppData(rid))
    }
    return apps
  }

  function altTabFocusedIndex(apps) {
    try {
      var win = Hyprland.activeToplevel
      if (!win) return -1
      var id = root.dockIdForHyprlandWindow(win)
      if (!id) return -1
      for (var i = 0; i < apps.length; i++)
        if (apps[i].id === id) return i
    } catch (error) {}
    return -1
  }

  function altTabNext() {
    if (altTab.active) {
      altTab.next()
      return
    }
    var apps = root.buildAltTabApps()
    if (apps.length === 0) return
    var index = root.altTabFocusedIndex(apps)
    // First Tab after opening: land on the app AFTER the focused one, like
    // macOS. With nothing focused, start at the front.
    altTab.open(apps, index < 0 ? 0 : (index + 1) % apps.length)
  }

  function altTabPrev() {
    if (altTab.active) {
      altTab.prev()
      return
    }
    var apps = root.buildAltTabApps()
    if (apps.length === 0) return
    var index = root.altTabFocusedIndex(apps)
    altTab.open(apps, index < 0 ? apps.length - 1 : (index - 1 + apps.length) % apps.length)
  }

  function altTabCancel() {
    altTab.cancel()
  }

  function activateApp(id, name) {
    try {
      // Same no-warp focus path as clicking the dock: never Toplevel.activate().
      var hyprWindow = root.hyprlandWindowForItem({ id: id })
      if (hyprWindow && root.focusExistingWindow(hyprWindow)) return
    } catch (error) {
    }
    var entry = DockModel.entryFor(id, root.appEntries)
    var label = name || (entry && entry.name) || id
    if (root.shell && root.shell.appLibrary && typeof root.shell.appLibrary.launch === "function")
      root.shell.appLibrary.launch(id, label)
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
    var content = DockModel.serializePinned(root.pinnedIds, root.dockOrder)
    root.ownWriteUntil = Date.now() + 2000
    DockModel.markWritten(content)
    tempWriter.path = root.tempPinPath
    tempWriter.setText(content)
    Qt.callLater(function() { renameProcess.running = true })
  }

  function openMenu(item, position) {
    root.tooltipItem = null
    root.hidePreview()
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

  // Drag controller ---------------------------------------------------------
  function onDragMoved(item, position, surfacePosition) {
    if (!root.floatingId) {
      root.floatingId = item.id
      root.tempDrag = { id: item.id, index: -1 }
      root.ghostSource = root.iconSourceFor(item)
      root.ghostScale = 1.18
      root.ghostOpacity = 1
      root.tooltipVisible = false
      root.tooltipItem = null
    }
    root.hoveredMouseX = position.x
    root.hidePreview()
    root.dragInsideDock =
      surfacePosition.x >= 0 && surfacePosition.x <= dockSurface.width &&
      surfacePosition.y >= 0 && surfacePosition.y <= dockSurface.height
    root.ghostX = position.x - root.iconSize * root.ghostScale / 2
    root.ghostY = position.y - root.iconSize * root.ghostScale / 2 - 30
    root.applyLayout()
  }

  function finishDrag(item, surfacePosition) {
    var id = item.id
    if (!root.floatingId) return
    // `dragInsideDock` is tracked per-frame in onDragMoved from the cursor's
    // dockSurface-local position — the same surface the input mask
    // (Region { item: dockSurface }) hit-tests — so a drop is judged against
    // exactly what received the drag instead of a coordinate mapping
    // re-derived at release time.
    var inside = root.dragInsideDock
    console.log("macos.dock finishDrag", JSON.stringify({ id: id, inside: inside, localX: surfacePosition.x, localY: surfacePosition.y, surfaceW: dockSurface.width, surfaceH: dockSurface.height, cursorX: root.cursorXInRow() }))
    var wasPinned = root.pinnedIds.indexOf(id) !== -1
    var persist = false

    try {
    if (inside) {
      var baseFlow = DockModel.buildFlow(root.dockOrder, [], id, -1)
      var idx = root.tempDrag.index
      if (idx < 0) idx = baseFlow.length
      // Reorder the session dock — never the pinned list. Dragging never
      // promotes a running app into a persistent pin.
      var newOrder = DockModel.moveInOrder(root.dockOrder, id, idx)
      console.log("macos.dock reorder", JSON.stringify({ id: id, idx: idx, wasPinned: wasPinned, dockOrderBefore: root.dockOrder, newOrder: newOrder, pinnedBefore: root.pinnedIds, runningIds: root.runningIds }))
      if (newOrder.join("|") !== root.dockOrder.join("|")) {
        root.dockOrder = newOrder
        // Snap the dropped delegate straight to its new slot. Without this the
        // settle spring carries it the whole way from its old slot and swings
        // back past the drop point before settling. The delegate is invisible
        // (opacity 0) while floating, so the snap is seamless: it appears
        // instantly at full opacity exactly where the ghost was, and applyLayout
        // then assigns the identical x, so no spring runs.
        var dropFlow = DockModel.buildFlow(newOrder, [], "", -1)
        var dropResult = DockModel.computeLayout(dropFlow, root.cursorXInRow(), DockModel.LAYOUT_OPTS)
        var dropP = dropResult.placements[id]
        var dropDelegate = root.delegateById[id]
        if (dropP && dropDelegate) {
          dropDelegate.animating = false
          dropDelegate.targetOpacity = 1
          dropDelegate.x = dropP.x
          dropDelegate.animating = true
        }
      }
      if (wasPinned) {
        // A pinned app moved: persist its new relative order among the other
        // pinned apps only (running apps are never written to the pin file).
        var newPinned = DockModel.orderPinned(newOrder, root.pinnedIds)
        if (newPinned.join("|") !== root.pinnedIds.join("|")) {
          root.pinnedIds = newPinned
          persist = true
        }
      }
    } else if (wasPinned) {
      // Dragged out of the dock: the app loses its persistent slot but stays
      // in the session order while it keeps running.
      root.pinnedIds = DockModel.removePinned(root.pinnedIds, id)
      persist = true
    }

    // Restore the dragged delegate at full opacity without the 150ms fade so
    // a drop never reads as a blink, regardless of inside/outside.
    var restoredDelegate = root.delegateById[id]
    if (restoredDelegate) {
      restoredDelegate.animating = false
      restoredDelegate.targetOpacity = 1
      restoredDelegate.animating = true
    }

    root.floatingId = ""
    root.tempDrag = { id: "", index: -1 }
    // Always rebuild so any window/app changes deferred while dragging apply.
    root.refreshItems()
    if (persist) persistTimer.restart()
    // Hide the ghost immediately so it never overlaps the restored icon.
    ghostHideTimer.stop()
    root.ghostSettling = false
    root.ghostOpacity = 1
    root.ghostScale = 1.18
    root.ghostSource = ""
    } catch (error) {
      console.warn("macos.dock finishDrag error", error)
      root.floatingId = ""
      root.tempDrag = { id: "", index: -1 }
      root.refreshItems()
      ghostHideTimer.stop()
      root.ghostSettling = false
      root.ghostOpacity = 1
      root.ghostScale = 1.18
      root.ghostSource = ""
    }
  }

  function showTooltip(item, show) {
    if (root.floatingId) return
    if (show) {
      tooltipItem = item
      tooltipVisible = true
    } else if (tooltipItem && tooltipItem.id === item.id) {
      tooltipVisible = false
      tooltipItem = null
    }
  }

  // Preview controller ------------------------------------------------------
  function onItemHoverChanged(item, isVisible, centerX) {
    if (!item || item.separator) return
    if (isVisible) {
      root.previewCenterX = centerX
      if (root.floatingId || root.menuOpen || !root.enabled) return
      if (!item.running) { root.hidePreview(); return }
      if (root.previewAppId !== item.id) root.hidePreview()
      root.previewAppId = item.id
      previewDelay.restart()
    } else {
      if (root.previewAppId === item.id) previewGrace.restart()
    }
  }

  function hidePreview() {
    var was = root.previewAppId
    previewDelay.stop()
    previewGrace.stop()
    root.previewAppId = ""
    root.previewWindows = []
    root.previewVisible = false
    root.pendingPreviewShow = false
    if (root.deferredTooltipItem && root.hoveredItemId === was) {
      root.tooltipItem = root.deferredTooltipItem
      root.tooltipVisible = true
    }
    root.deferredTooltipItem = null
  }

  function array2(v) {
    if (v === null || v === undefined) return [0, 0]
    try {
      var a = Number(v[0])
      var b = Number(v[1])
      if (!isNaN(a) && !isNaN(b)) return [a, b]
    } catch (error) {}
    return [0, 0]
  }

  function gatherWindowsForApp(id) {
    var output = []
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
        var match = false
        for (var j = 0; j < ids.length; j++) {
          if (ids[j] === String(id).toLowerCase()) { match = true; break }
          if (root.desktopIdForWindow({ appId: ids[j], title: candidate.title }) === id) { match = true; break }
        }
        if (!match) continue
        var pos = root.array2(ipc.at)
        var size = root.array2(ipc.size)
        output.push({
          address: String(candidate.address || ""),
          title: String(candidate.title || ""),
          active: !!(ipc.focused || candidate.focused),
          mapped: !!ipc.mapped,
          minimized: !!ipc.minimized,
          workspaceId: ipc.workspace ? ipc.workspace.id : -1,
          x: pos[0] || 0,
          y: pos[1] || 0,
          w: size[0] || 0,
          h: size[1] || 0
        })
      }
    } catch (error) {}
    return output
  }

  // Live window thumbnails --------------------------------------------------
  // grim captures the composited output, so a window that is buried under
  // another window cannot be captured correctly (the thumbnail would show
  // whatever is on top). Instead, a thumbnail is captured when a window
  // becomes active (it is on top then) and cached by address. Previews reuse
  // the cache; windows without a cached thumbnail are captured on hover as a
  // best-effort fallback. Windows on other workspaces or minimized windows
  // that were never active fall back to the icon card.
  function snapshotWindows() {
    root.currentThumbBatch++
    root.snapshotPending = 0
    var focused = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    for (var i = 0; i < root.previewWindows.length; i++) {
      var w = root.previewWindows[i]
      if (!w.address) continue
      if (root.thumbCache[w.address] || root.inFlightAddrs[w.address]) continue
      // Skip only when we positively know the window cannot be captured.
      if (w.minimized === true) continue
      if (w.mapped === false) continue
      if (w.workspaceId !== undefined && w.workspaceId >= 0 && w.workspaceId !== focused) continue
      if (!w.w || !w.h) continue
      root.captureForSnapshot({ address: w.address, x: w.x, y: w.y, w: w.w, h: w.h })
    }
    if (root.snapshotPending === 0) root.applyThumbnails()
  }

  function captureForSnapshot(job) {
    root.snapshotPending++
    root.inFlightAddrs[job.address] = true
    var proc = captureProcess.createObject(root, {
      jobAddress: job.address,
      jobBatch: root.currentThumbBatch,
      command: ["bash", "-c", root.thumbnailCommand(job)]
    })
    proc.running = true
  }

  function captureActive(info) {
    if (!info || !info.address) return
    if (root.inFlightAddrs[info.address]) return
    root.inFlightAddrs[info.address] = true
    var proc = captureProcess.createObject(root, {
      jobAddress: info.address,
      jobBatch: "",
      command: ["bash", "-c", root.thumbnailCommand(info)]
    })
    proc.running = true
  }

  function thumbnailCommand(job) {
    var dir = Util.shellQuote(root.thumbnailDir)
    var target = Util.shellQuote(root.thumbnailDir + "/" + job.address + ".png")
    var tmp = Util.shellQuote(root.thumbnailDir + "/" + job.address + ".png.tmp")
    var geometry = job.x + "," + job.y + " " + job.w + "x" + job.h
    return "mkdir -p " + dir
      + "; grim -g \"" + geometry + "\" - | magick - -resize 304x184^ -gravity center -extent 304x184 png:" + tmp
      + " && mv " + tmp + " " + target
  }

  function applyThumbnails() {
    if (!root.previewAppId) return
    var next = []
    for (var i = 0; i < root.previewWindows.length; i++) {
      var w = root.previewWindows[i]
      var copy = {}
      for (var k in w) copy[k] = w[k]
      if (root.thumbCache[w.address]) copy.thumbPath = root.thumbnailDir + "/" + w.address + ".png"
      next.push(copy)
    }
    root.previewWindows = next
    if (root.pendingPreviewShow) {
      root.pendingPreviewShow = false
      root.previewBottomY = dockSurface.y
      root.previewVisible = true
      root.deferredTooltipItem = root.tooltipItem
      root.tooltipItem = null
      root.tooltipVisible = false
    }
  }

  function thumbnailFor(w) {
    if (!w || !w.thumbPath) return ""
    return Util.fileUrl(w.thumbPath)
  }

  function activatePreviewWindow(data) {
    if (!data || !data.address) return
    root.hidePreview()
    root.focusWindowAddress(data.address)
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

  function customIconSourceFor(id) {
    var file = IconResolver.customIconFile(root.customIcons, id)
    if (!file) return ""
    // The revision prevents QML from retaining an older image after a file
    // is replaced with the same filename.
    return Util.fileUrl(root.iconDir + "/" + file) + "?v=" + root.customIconRevision
  }

  function iconSourceFor(item) {
    // Accept either a live item object or a plain id string (delegates pass
    // their model id after the identity/state split).
    var id = typeof item === "string" ? item : item && item.id
    // Touch the revision so the DockItem override binding re-evaluates once a
    // native icon finishes normalization below.
    var nativeRevision = root.nativeIconRevision
    var customSource = root.customIconSourceFor(id)
    if (customSource) return customSource
    var entry = DockModel.entryFor(id, root.appEntries)
    var iconName = entry.icon || entry.iconName || entry.appIcon || ""
    if (root.shell && root.shell.appLibrary && iconName && typeof root.shell.appLibrary.iconSource === "function") {
      var resolved = root.shell.appLibrary.iconSource(iconName)
      if (resolved && String(resolved).indexOf("application-x-executable") === -1)
        return root.nativeIconSourceFor(resolved)
      var fallbackName = IconResolver.resolveIcon(entry)
      if (fallbackName && fallbackName !== iconName) {
        resolved = root.shell.appLibrary.iconSource(fallbackName)
        if (resolved && String(resolved).indexOf("application-x-executable") === -1)
          return root.nativeIconSourceFor(resolved)
      }
    }
    return ""
  }

  // Theme icons carry their own transparent margin (often only 70-95% painted
  // area), so they render visibly smaller than the full-bleed macOS custom
  // icons. Normalize native file-backed icons through the same trim + rounded
  // corner pipeline as the custom icons, cached in the icon directory.
  function nativeIconSourceFor(resolved) {
    var url = String(resolved || "")
    if (url.indexOf("file://") !== 0) return url
    var srcPath = url.slice(7)
    var hash = (DockModel.hashContent(srcPath) >>> 0).toString(36)
    var target = root.iconDir + "/.native-" + hash + ".png"
    if (root.nativeIconCache[hash] === target) return Util.fileUrl(target)
    if (!root.nativeIconPending[hash]) {
      root.nativeIconPending[hash] = true
      root.nativeIconQueue.push({ hash: hash, src: srcPath, target: target })
      if (!nativeIconProcess.running) root.pumpNativeIconQueue()
    }
    return url
  }

  function nativeIconCommand(srcPath, targetPath) {
    var src = Util.shellQuote(srcPath)
    var target = Util.shellQuote(targetPath)
    var dir = Util.shellQuote(root.iconDir)
    return "mkdir -p " + dir
      + "; tool=magick; command -v magick >/dev/null 2>&1 || tool=convert"
      + "; if [ -f " + target + " ]; then exit 0; fi"
      + "; tmp=$(mktemp --suffix=.png); trap 'rm -f \"$tmp\"' EXIT"
      + "; \"$tool\" " + src + " -resize 512x512 -trim +repage \"$tmp\""
      + "; w=$(identify -format '%w' \"$tmp\"); h=$(identify -format '%h' \"$tmp\")"
      + "; r=$(( (w < h ? w : h) * 22 / 100 ))"
      + "; \"$tool\" \"$tmp\" -alpha on"
      + " \\( -size \"${w}x${h}\" xc:none -fill white"
      + " -draw \"roundrectangle 0,0 $((w-1)),$((h-1)) $r,$r\" \\)"
      + " -compose DstIn -composite " + target
  }

  function pumpNativeIconQueue() {
    if (!root.nativeIconQueue.length || nativeIconProcess.running) return
    var job = root.nativeIconQueue.shift()
    root.currentNativeIconJob = job
    nativeIconProcess.command = ["bash", "-c", root.nativeIconCommand(job.src, job.target)]
    nativeIconProcess.running = true
  }

  Timer { id: conflictNotice; interval: 30000 }
  property bool tooltipVisible: false
  property var deferredTooltipItem: null

  // Hover-to-preview state. Lives entirely outside the dock model: it never
  // touches dockItems/dockOrder/pinnedIds, so showing a preview can never
  // rebuild the Repeater or flash the dock.
  property string previewAppId: ""
  property var previewWindows: []
  property bool previewVisible: false
  property real previewCenterX: 0
  property real previewBottomY: 0
  property string thumbnailDir: home + "/.cache/omarchy-dock/thumbs"
  property var thumbCache: ({})
  property int currentThumbBatch: 1
  property int snapshotPending: 0
  property var inFlightAddrs: ({})
  property bool pendingPreviewShow: false

  Timer {
    id: previewDelay
    interval: 180
    onTriggered: {
      if (!root.previewAppId || root.floatingId || root.menuOpen || !root.enabled) return
      var wins = root.gatherWindowsForApp(root.previewAppId)
      if (!wins.length) return
      root.previewWindows = wins
      // Snapshots run before the preview is shown so the panel never appears
      // inside its own thumbnails; the preview pops in once they are ready.
      root.pendingPreviewShow = true
      root.snapshotWindows()
    }
  }

  // Grace period: when the cursor leaves a dock item, the preview stays up
  // long enough for the user to glide into it. Entering the preview panel
  // cancels this; leaving both hides the preview.
  Timer {
    id: previewGrace
    interval: 300
    onTriggered: root.hidePreview()
  }

  FileView {
    id: customIconsFile
    path: root.iconMapPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadCustomIcons(text())
    onFileChanged: customIconsFile.reload()
    onLoadFailed: root.loadCustomIcons("{}")
  }

  FileView {
    id: pinFile
    path: root.pinPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      if (!root.pinFileLoaded) {
        root.pinFileLoaded = true
        root.pinnedIds = DockModel.parsePinned(text(), DockModel.DEFAULT_PINNED)
      } else {
        // Reloaded after a change: apply only content we did not write.
        if (!DockModel.shouldReprocess(text())) return
        console.log("macos.dock pinFileApplied", JSON.stringify({ pinned: root.pinnedIds }))
        root.pinnedIds = DockModel.parsePinned(text(), root.pinnedIds)
      }
      root.dockOrder = DockModel.parseOrder(text(), root.dockOrder)
      root.refreshItems()
    }
    onFileChanged: {
      // Watcher events for our own save cycles are stale-text races; skip
      // them and let the reload()/onLoaded path handle real external edits.
      if (Date.now() < root.ownWriteUntil) return
      pinFile.reload()
    }
    onLoadFailed: {
      root.pinFileLoaded = true
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

  Component {
    id: captureProcess
    Process {
      id: self
      required property string jobAddress
      required property string jobBatch
      onExited: function(exitCode) {
        if (exitCode === 0) root.thumbCache[self.jobAddress] = true
        if (self.jobBatch === root.currentThumbBatch) {
          root.snapshotPending--
          if (root.snapshotPending === 0) root.applyThumbnails()
        }
        delete root.inFlightAddrs[self.jobAddress]
        self.destroy()
      }
    }
  }

  property string activeThumbAddress: ""

  function activeToplevelInfo() {
    try {
      var t = Hyprland.activeToplevel
      if (!t) return null
      var ipc = t.lastIpcObject || {}
      var pos = root.array2(ipc.at)
      var size = root.array2(ipc.size)
      return { address: String(t.address || ""), x: pos[0], y: pos[1], w: size[0], h: size[1] }
    } catch (error) {}
    return null
  }

  Process {
    id: nativeIconProcess
    onExited: function(exitCode) {
      var job = root.currentNativeIconJob
      root.currentNativeIconJob = null
      if (job) {
        delete root.nativeIconPending[job.hash]
        if (exitCode === 0) {
          root.nativeIconCache[job.hash] = job.target
          root.nativeIconRevision++
        }
      }
      root.pumpNativeIconQueue()
    }
  }

  Connections {
    target: root.shell ? root.shell.appLibrary : null
    function onAppsChanged() { root.refreshApps() }
  }
  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      // Keep the Alt+Tab MRU list in sync with focus changes. The switcher
      // only tracks apps the dock knows about.
      var mruId = root.dockIdForHyprlandWindow(Hyprland.activeToplevel)
      if (mruId && root.runningIds.indexOf(mruId) !== -1) root.touchMru(mruId)
      // Capture a thumbnail whenever the active window changes: it is on top
      // at that moment, so the grim capture is not occluded by other windows.
      var info = root.activeToplevelInfo()
      if (info && info.address && info.address !== root.activeThumbAddress) {
        root.activeThumbAddress = info.address
        root.captureActive(info)
      }
    }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      root.refreshItems()
      // The preview mirrors the live window set without touching the dock
      // model: cards appear/disappear as windows open/close.
      if (root.previewVisible && root.previewAppId) {
        var wins = root.gatherWindowsForApp(root.previewAppId)
        if (!wins.length) root.hidePreview()
        else {
          var thumbs = {}
          var existing = root.previewWindows
          for (var i = 0; i < existing.length; i++)
            if (existing[i].thumbPath) thumbs[existing[i].address] = existing[i].thumbPath
          for (var j = 0; j < wins.length; j++)
            if (thumbs[wins[j].address]) wins[j].thumbPath = thumbs[wins[j].address]
          root.previewWindows = wins
        }
      }
    }
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
      width: root.layoutWidth
      height: root.dockHeight
      radius: 22
      color: Util.alpha(Color.background, 0.88)
      border.color: Util.alpha(Color.foreground, 0.20)
      border.width: 1
      opacity: root.autoHide && !root.enabled ? 0.55 : (root.menuOpen || root.dockHovered ? 1 : 0.96)

      Behavior on width {
        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
      }
      Behavior on anchors.bottomMargin {
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
      }
      Behavior on opacity { NumberAnimation { duration: 180 } }

      Item {
        id: dockRow
        anchors.centerIn: parent
        anchors.verticalCenterOffset: 6
        width: root.layoutWidth - 2 * root.sidePadding
        height: 70

        Behavior on width {
          NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
        }

        Repeater {
          model: root.dockItems
          delegate: Item {
            id: wrapper
            required property string modelData
            width: root.slotWidth
            height: 70
            x: 0
            property bool animating: false

            // Live metadata mirrored from observable root state so a pin or
            // running toggle updates the delegate in place instead of the
            // Repeater rebuilding every DockItem.
            property var liveData: ({
              id: modelData,
              name: root.appNameFor(modelData),
              icon: root.appIconNameFor(modelData),
              pinned: root.pinnedIds.indexOf(modelData) !== -1,
              running: root.runningIds.indexOf(modelData) !== -1
            })

            property alias targetScale: dockItem.targetScale
            property alias targetLift: dockItem.targetLift
            property alias targetOpacity: dockItem.targetOpacity

            Behavior on x {
              enabled: wrapper.animating
              SpringAnimation { spring: 3.2; damping: 0.29; mass: 1 }
            }

            Component.onCompleted: {
              root.registerItem(modelData, wrapper)
              var seed = root.seedFor(modelData)
              x = seed.x
              targetScale = seed.scale
              targetLift = seed.lift
              targetOpacity = (modelData === root.floatingId) ? 0 : 1
              animating = true
            }
            Component.onDestruction: {
              root.visualCache[modelData] = { x: x, scale: targetScale, lift: targetLift }
              root.unregisterItem(modelData)
            }

            DockItem {
              id: dockItem
              anchors.centerIn: parent
              itemData: wrapper.liveData
              iconSize: root.iconSize
              animationEnabled: wrapper.animating
              iconSourceOverride: root.iconSourceFor(modelData)
              onItemLeftClicked: function(clickedItem) { root.handleClick(clickedItem) }
              onItemRightClicked: function(clickedItem, position) { root.openMenu(clickedItem, position) }
              onDragMoved: function(draggedItem, position) {
                root.onDragMoved(draggedItem,
                  dockItem.mapToItem(null, position.x, position.y),
                  dockItem.mapToItem(dockSurface, position.x, position.y))
              }
              onDragFinished: function(draggedItem, position) {
                root.finishDrag(draggedItem, dockItem.mapToItem(dockSurface, position.x, position.y))
              }
              onTooltipRequested: function(hoveredItem, isVisible, centerX) {
                root.tooltipCenterX = centerX
                root.onItemHoverChanged(hoveredItem, isVisible, centerX)
                root.showTooltip(hoveredItem, isVisible)
              }
              onHoverPointerChanged: function(hoveredItem, isInside, pointerX) {
                if (isInside) {
                  root.hoveredItemId = hoveredItem.id
                  root.hoveredMouseX = pointerX
                  root.tooltipCenterX = pointerX
                } else if (!root.floatingId && root.hoveredItemId === hoveredItem.id) {
                  // The cursor left this item's hit area but is still on the
                  // dock (or already inside a neighbor's). Keep hoveredMouseX
                  // continuous so magnification glides across gaps instead of
                  // snap-shrinking between items; clearHover() resets it when
                  // the cursor actually leaves the dock surface.
                  root.hoveredItemId = ""
                }
                root.applyLayout()
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
          root.clearHover()
          if (root.autoHide && root.dockReady) hideTimer.restart()
        }
        onPositionChanged: {
          root.hoveredMouseX = mouseArea.mapToItem(null, mouseX, mouseY).x
          root.applyLayout()
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
      onExited: {
        root.dockHovered = false
        root.clearHover()
        hideTimer.restart()
      }
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

  // Persistence is written only after the settle animation finishes, matching
  // the "visual state -> animation completes -> persist pin" ordering.
  Timer {
    id: persistTimer
    interval: 300
    onTriggered: root.savePinned()
  }

  Timer {
    id: ghostHideTimer
    interval: 260
    onTriggered: {
      root.ghostSource = ""
      root.ghostSettling = false
      root.ghostOpacity = 1
      root.ghostScale = 1.18
    }
  }

  // Hover-to-preview lives in its own overlay layer window so it can extend
  // far above the dock surface without touching the dock's layout or model.
  WindowPreviewPanel {
    id: previewPanel
    previewVisible: root.previewVisible && !root.floatingId && !root.menuOpen
    windowList: root.previewWindows
    centerX: root.previewCenterX
    bottomY: root.previewBottomY
    iconSourceFor: function(data) { return root.iconSourceFor({ id: root.previewAppId }) }
    thumbnailFor: function(data) { return root.thumbnailFor(data) }
    onActivated: function(data) { root.activatePreviewWindow(data) }
    onPreviewHoverEntered: previewGrace.stop()
    onPreviewHoverExited: previewGrace.restart()
  }

  AltTabPanel {
    id: altTab
    iconSourceFor: function(app) { return root.iconSourceFor(app.id) }
    onActivated: function(appId, appName) { root.activateApp(appId, appName) }
  }

  // The dragged icon lives in its own overlay window so it can follow the
  // cursor anywhere on screen without clipping against the dock's mask. Its
  // input region is only the anchor, so it never blocks clicks. Position is
  // driven externally by the drag controller from the phantom's mouse events.
  PanelWindow {
    id: dragGhostWindow
    visible: root.ghostSource !== ""
    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "macos-dock-drag"
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: ghostAnchor }

    Item {
      id: ghostAnchor
      x: root.ghostX
      y: root.ghostY
      width: root.iconSize * root.ghostScale + 16
      height: root.iconSize * root.ghostScale + 16
      opacity: root.ghostOpacity
      Behavior on x { SpringAnimation { spring: 3.2; damping: 0.29; mass: 1 } }
      Behavior on y { SpringAnimation { spring: 3.2; damping: 0.29; mass: 1 } }
      Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      Rectangle {
        anchors.centerIn: parent
        width: parent.width - 4
        height: parent.height - 4
        radius: root.iconSize * 0.26
        color: Util.alpha(Color.background, 0.55)
        border.color: Util.alpha(Color.foreground, 0.18)
        border.width: 1
      }

      Image {
        anchors.centerIn: parent
        width: root.iconSize * root.ghostScale
        height: root.iconSize * root.ghostScale
        source: root.ghostSource
        sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
        asynchronous: true
      }
    }
  }
}
