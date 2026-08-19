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
  property string pendingFocusTarget: ""
  property string pendingCursorPosition: ""
  property var customIcons: ({})
  property int customIconRevision: 0
  property var nativeIconCache: ({})
  property var nativeIconPending: ({})
  property var nativeIconQueue: []
  property var currentNativeIconJob: null
  property int nativeIconRevision: 0

  // Layout & drag state. The Repeater model (dockItems) is reassigned only
  // when the item set changes; reorders go through applyLayout(), which only
  // mutates existing delegates, so no delegate is ever torn down by dragging.
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
    // Reassign the Repeater model only when the set of items actually changed
    // (apps opened/closed, pinned toggled, pin file reloaded). A pure reorder
    // must never touch the model: reassigning a JS array model destroys and
    // recreates every delegate, which flashes the whole dock. Delegate
    // positions are driven by placements[id] in applyLayout(), so the model's
    // order is irrelevant to rendering.
    if (!root.floatingId) {
      var newItems = DockModel.buildOrderedItems(root.dockOrder, root.pinnedIds, root.appEntries, root.runningIds)
      if (!root.sameItemSet(newItems, root.dockItems))
        root.dockItems = newItems
    }
    root.applyLayout()
  }

  function sameItemSet(a, b) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      var found = false
      for (var j = 0; j < b.length; j++) {
        if (a[i].id === b[j].id && a[i].pinned === b[j].pinned && a[i].running === b[j].running) { found = true; break }
      }
      if (!found) return false
    }
    return true
  }

  function cursorXInRow() {
    if (root.hoveredMouseX < 0) return -1
    return dockRow.mapFromItem(null, root.hoveredMouseX, 0).x
  }

  function registerItem(id, item) { root.delegateById[id] = item }
  function unregisterItem(id) { delete root.delegateById[id] }

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
    var content = DockModel.serializePinned(root.pinnedIds, root.dockOrder)
    root.ownWriteUntil = Date.now() + 2000
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
    root.dragInsideDock =
      surfacePosition.x >= 0 && surfacePosition.x <= dockSurface.width &&
      surfacePosition.y >= 0 && surfacePosition.y <= dockSurface.height
    root.ghostX = position.x - root.iconSize * root.ghostScale / 2
    root.ghostY = position.y - root.iconSize * root.ghostScale / 2 - 30
    root.applyLayout()
  }

  function ghostSettleTo() {
    root.ghostSettling = true
    root.ghostScale = 0.4
    root.ghostOpacity = 0
    ghostHideTimer.restart()
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
      var newPinned = wasPinned ? DockModel.orderPinned(newOrder, root.pinnedIds) : null
      console.log("macos.dock reorder", JSON.stringify({ id: id, idx: idx, wasPinned: wasPinned, dockOrderBefore: root.dockOrder, newOrder: newOrder, pinnedBefore: root.pinnedIds, newPinned: newPinned, runningIds: root.runningIds }))
      if (newOrder.join("|") !== root.dockOrder.join("|")) {
        root.dockOrder = newOrder
        // Snap the dropped delegate straight to its new slot. Without this the
        // settle spring carries it the whole way from its old slot and swings
        // back past the drop point before settling. The delegate is invisible
        // (opacity 0) while floating, so the snap is seamless: it fades in
        // exactly where the ghost is.
        var dropFlow = DockModel.buildFlow(newOrder, [], "", -1)
        var dropResult = DockModel.computeLayout(dropFlow, root.cursorXInRow(), DockModel.LAYOUT_OPTS)
        var dropP = dropResult.placements[id]
        var dropDelegate = root.delegateById[id]
        if (dropP && dropDelegate) {
          dropDelegate.animating = false
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

    root.floatingId = ""
    root.tempDrag = { id: "", index: -1 }
    // Always rebuild so any window/app changes deferred while dragging apply.
    root.refreshItems()
    if (persist) persistTimer.restart()
    root.ghostSettleTo()
    } catch (error) {
      console.warn("macos.dock finishDrag error", error)
      root.floatingId = ""
      root.tempDrag = { id: "", index: -1 }
      root.refreshItems()
      root.ghostSettleTo()
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
    // Touch the revision so the DockItem override binding re-evaluates once a
    // native icon finishes normalization below.
    var nativeRevision = root.nativeIconRevision
    var customSource = root.customIconSourceFor(item)
    if (customSource) return customSource
    var entry = DockModel.entryFor(item && item.id, root.appEntries)
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
  Timer { id: tooltipDelay; interval: 400; onTriggered: tooltipVisible = true }
  property bool tooltipVisible: false

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
            required property var modelData
            width: modelData.separator ? root.separatorWidth : root.slotWidth
            height: 70
            x: 0
            property bool animating: false

            property alias targetScale: dockItem.targetScale
            property alias targetLift: dockItem.targetLift
            property alias targetOpacity: dockItem.targetOpacity

            Behavior on x {
              enabled: wrapper.animating
              SpringAnimation { spring: 3.2; damping: 0.29; mass: 1 }
            }

            Component.onCompleted: {
              root.registerItem(modelData.id, wrapper)
              var seed = root.seedFor(modelData.id)
              x = seed.x
              targetScale = seed.scale
              targetLift = seed.lift
              targetOpacity = (modelData.id === root.floatingId) ? 0 : 1
              animating = true
            }
            Component.onDestruction: {
              root.visualCache[modelData.id] = { x: x, scale: targetScale, lift: targetLift }
              root.unregisterItem(modelData.id)
            }

            Rectangle {
              visible: !!modelData.separator
              anchors.centerIn: parent
              width: 1
              height: 34
              color: Util.alpha(Color.foreground, 0.22)
            }

            DockItem {
              id: dockItem
              visible: !modelData.separator
              anchors.centerIn: parent
              itemData: modelData
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
                root.showTooltip(hoveredItem, isVisible)
              }
              onHoverPointerChanged: function(hoveredItem, isInside, pointerX) {
                if (isInside) {
                  root.hoveredItemId = hoveredItem.id
                  root.hoveredMouseX = pointerX
                  root.tooltipCenterX = pointerX
                } else if (!root.floatingId && root.hoveredItemId === hoveredItem.id) {
                  // During a drag the drag controller owns hoveredMouseX.
                  root.hoveredItemId = ""
                  root.hoveredMouseX = -1
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
