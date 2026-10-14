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
  property string settingsPath: home + "/.config/omarchy/dock-settings.json"
  property var pinnedIds: []
  property var dockOrder: []
  property bool pinFileLoaded: false
  // Our temp+rename writes make the pin-file watcher fire before FileView's
  // async re-read finishes, so onFileChanged can observe stale text(). The
  // reload() path re-reads fresh, and this window skips watcher events that
  // belong to our own save cycles entirely.
  property double ownWriteUntil: 0
  property bool settingsLoaded: false
  property double settingsWriteUntil: 0
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
  // dockHovered is true while cursor is over any icon (hoveredItemId) or over the dock background gaps.
  // Using a binding avoids the fragile manual hover tracking where a MouseArea behind delegates
  // didn't receive hover when an icon was on top, causing hide to arm while still over dock.
  // surfaceHovered is published by each screen's dock delegate (mouseArea no
  // longer lives in this component's scope once one delegate exists per output).
  property bool dockHovered: hoveredItemId !== "" || root.surfaceHovered
  property bool menuOpen: false
  property bool pickerOpen: false
  property bool enabled: true
  property bool dockReady: false
  // Layer-shell remap pulse. When Hyprland destroys our outputs (suspend,
  // DPMS off, cable disconnect) the compositor closes our layer surfaces, but
  // static PanelWindows with unchanged `visible == true` are never re-mapped
  // onto the new wl_output. Pulsing `remapping` false->true->false forces a
  // visible transition so Quickshell re-creates the surfaces (see #13).
  property bool remapping: false

  Timer {
    id: remapSettleTimer
    interval: 250
    onTriggered: {
      root.remapping = true
      remapUnmapTimer.restart()
    }
  }

  Timer {
    id: remapUnmapTimer
    interval: 100
    onTriggered: {
      root.remapping = false
    }
  }

  function triggerRemap(manual) {
    // Skip automatic pulses during startup (screensChanged fires before the
    // dock is ready and would only cause a boot flicker). Manual IPC remaps
    // always run.
    if (!manual && !root.dockReady) return
    remapSettleTimer.restart()
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      // The live screen list changed (output added/removed/resized): re-resolve
      // which outputs carry a dock, then re-map the layer surfaces.
      root.screenRevision++
      root.triggerRemap(false)
    }
  }
  // macOS-style auto-hide. Enabled by default; persisted in dock-settings.json.
  property bool autoHide: true
  // Dock placement: "bottom" | "left" | "right". Persisted in dock-settings.json.
  property string dockSide: "bottom"
  property bool vertical: root.dockSide !== "bottom"
  // Which outputs the dock occupies: "all" (every connected output, the
  // default), "primary" (the first screen only) or an output name from
  // `hyprctl monitors` such as "DP-1". Persisted in dock-settings.json.
  property string screenMode: "all"
  // Tuning for the macOS glide — not too fast, not sluggish.
  property int hideDelay: 1000
  property int showDelay: 100
  property int hideDuration: 380
  property int showDuration: 280
  property int edgeHeight: 3
  property int peekPx: 0
  // Hide is suppressed while any transient UI is active so the dock does not
  // vanish under a menu, preview, picker or drag.
  property bool hideSuppressed: root.menuOpen || root.pickerOpen || root.previewVisible || root.floatingId !== "" || !!(root.altTab && root.altTab.active)
  property bool edgeHovered: false
  // Combined engagement — dockHovered OR edgeHovered. While true, hide is
  // suppressed and must not be scheduled. Extracted to avoid the fragile 5px
  // gap between dockSurface bottom (H-8) and edge strip (H-3).
  property bool dockEngaged: root.dockHovered || root.edgeHovered
  // ---- Outputs (multi-monitor) -------------------------------------------
  // One dock surface per connected output is the default; see dockScreens.
  // Bumped from Quickshell.onScreensChanged so dockScreens re-resolves (the
  // screen list is a live QML property, not a bindable JS value).
  property int screenRevision: 0
  // Output whose dock surface last took pointer input. Tooltips, the window
  // preview and the drag ghost follow it, and cursorXInRow() maps a hover
  // through the row of the screen it came from.
  property string activeScreenName: ""
  // True while the cursor is inside a screen's dock surface (any output).
  property bool surfaceHovered: false
  // Dock row per output name, registered by each screen's delegate.
  property var rowByScreenName: ({})
  // Slide state for auto-hide. The PanelWindow stays mapped when enabled;
  // this flag drives the bottomMargin translation so the glide is animated.
  property bool autoHidden: false
  property int dockHeight: 101
  property int bottomMargin: 8
  // Dock geometry is computed in screen coordinates (dockWindow fills the
  // screen) instead of conditional anchors. Switching sides cannot leave a
  // stale anchor competing with a new one, which otherwise pinned the dock to
  // top-center and inflated the edge hot-zone to full screen.
  property real hideShift: (root.autoHide && root.autoHidden) ? root.bottomMargin + root.dockHeight - root.peekPx : 0
  property real surfaceWidth: root.vertical ? root.dockHeight : root.layoutWidth
  property real surfaceHeight: root.vertical ? root.layoutWidth : root.dockHeight
  // Dock surfaces for the outputs we occupy. Every surface is sized and placed
  // from its own output's dimensions, so a 1920x1200 laptop panel and a
  // 2560x1440 monitor each get a correctly centred dock.
  function dockScreensFor(mode) {
    var all = Quickshell.screens || []
    var names = DockModel.resolveScreenNames(all, mode)
    var out = []
    for (var i = 0; i < names.length; i++) {
      for (var j = 0; j < all.length; j++) {
        if (all[j].name === names[i]) { out.push(all[j]); break }
      }
    }
    return out
  }
  readonly property var dockScreens: {
    root.screenRevision
    return root.dockScreensFor(root.screenMode)
  }
  function screenByName(name) {
    var all = Quickshell.screens || []
    for (var i = 0; i < all.length; i++) if (all[i].name === name) return all[i]
    return all.length > 0 ? all[0] : null
  }
  readonly property var activeScreen: root.screenByName(root.activeScreenName)
  // The App Switcher opens on the monitor Hyprland has focused, not on a fixed
  // output: that is where the user is looking when they hit ALT+TAB.
  function focusedScreen() {
    var name = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
    return root.screenByName(name)
  }
  // Dock surface position on one output, in that output's own coordinates.
  function surfaceForScreen(screen) {
    if (!screen) return { x: 0, y: 0 }
    return DockModel.surfaceFor(root.dockSide, screen.width, screen.height,
      root.surfaceWidth, root.surfaceHeight, root.bottomMargin, root.hideShift)
  }
  // Kept for the parts that are not per-output windows (window preview, the
  // glass layer's fallback): they describe the dock on the active output.
  readonly property real surfaceX: root.surfaceForScreen(root.activeScreen).x
  readonly property real surfaceY: root.surfaceForScreen(root.activeScreen).y
  // A rotated dock row's window axis cannot be reproduced by arithmetic here,
  // so each delegate registers its row and hover coordinates are mapped
  // through the row of the output they came from.
  function registerRow(screenName, item) {
    if (!screenName) return
    var next = {}
    for (var key in root.rowByScreenName) next[key] = root.rowByScreenName[key]
    next[screenName] = item
    root.rowByScreenName = next
  }
  function unregisterRow(screenName) {
    var next = {}
    for (var key in root.rowByScreenName) if (key !== screenName) next[key] = root.rowByScreenName[key]
    root.rowByScreenName = next
  }
  readonly property var activeRow: {
    if (root.activeScreenName && root.rowByScreenName[root.activeScreenName])
      return root.rowByScreenName[root.activeScreenName]
    var screens = root.dockScreens
    for (var i = 0; i < screens.length; i++)
      if (root.rowByScreenName[screens[i].name]) return root.rowByScreenName[screens[i].name]
    return null
  }
  function markActiveScreen(name) {
    if (!name || root.activeScreenName === name) return
    root.activeScreenName = name
  }
  property int iconSize: 50
  property real hoveredMouseX: -1
  property string hoveredItemId: ""
  property var tooltipItem: null
  property real tooltipCenterX: 0
  property string pendingFocusTarget: ""
  property string pendingCursorPosition: ""
  property var pickerReturnItem: null
  property var customIcons: ({})
  property int customIconRevision: 0
  property var nativeIconCache: ({})
  property var nativeIconPending: ({})
  property var nativeIconQueue: []
  property var currentNativeIconJob: null
  property int nativeIconRevision: 0
  // The icon picker helper (~/.local/bin/omarchy-dock-icon) resolved at shell
  // start; falls back to PATH lookup so the GUI works however it was installed.
  // Prefer the helper shipped with this plugin. The ~/.local/bin symlink is
  // optional, so relying on it leaves the picker stuck in "Searching" on a
  // fresh install where the bundled script is present but the link is not.
  property string helperPath: root.home + "/.config/omarchy/plugins/macos.dock/scripts/omarchy-dock-icon"
  // Downloads / Trash — fixed special items at the right end, after the separator.
  property string downloadsPath: home + "/Downloads"
  property string trashFilesPath: home + "/.local/share/Trash/files"
  property bool trashFull: false

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
  // Delegate registry: one wrapper per item PER OUTPUT, so layout, drag and
  // bounce state reach every screen's copy of the dock, not just whichever
  // delegate happened to register last.
  property var delegatesById: ({})
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
  // macOS-style launch bounce (one-shot, vertical only). Triggered purely by
  // the NOT RUNNING -> RUNNING transition in refreshItems(), so the bounce
  // coincides with the app actually opening — never with the click itself.
  // Transitions are edge-triggered, giving exactly one bounce per launch.
  // bouncingIds tracks animations currently playing (prevents overlap and
  // carries the intent for delegates that do not exist yet).
  property var bouncingIds: []

  IpcHandler {
    target: "macos.dock"
    function toggle() { root.enabled = !root.enabled }
    function show() { root.enabled = true }
    function hide() { root.enabled = false }
    function altTabNext() { root.altTabNext() }
    function altTabPrev() { root.altTabPrev() }
    function altTabCancel() { root.altTabCancel() }
    function toggleAutoHide(): void { root.autoHide = !root.autoHide; root.saveSettings() }
    function setAutoHide(value: string): void {
      var v = String(value).toLowerCase()
      root.autoHide = (v === "true" || v === "1" || v === "on")
      root.saveSettings()
    }
    function getAutoHide(): bool { return root.autoHide }
    function remap(): string {
      root.triggerRemap(true)
      return "ok"
    }
    function setDockSide(value: string): void {
      var side = DockModel.normalizeSide(value)
      if (side === root.dockSide) return
      root.dockSide = side
    }
    function getDockSide(): string { return root.dockSide }
    function setScreenMode(value: string): string {
      var mode = DockModel.normalizeScreenMode(value)
      if (mode !== root.screenMode) root.screenMode = mode
      return root.screenMode
    }
    function getScreenMode(): string { return root.screenMode }
    function cycleDockSide(): string {
      var order = ["bottom", "left", "right"]
      var idx = order.indexOf(root.dockSide)
      root.dockSide = order[(idx + 1) % order.length]
      return root.dockSide
    }
    // DEBUG (temporary): trigger a bounce on demand without launching.
    function bounceDebug(id: string): void {
      root.triggerLaunchBounce(id)
    }
    // Multi-output state, in one line: which outputs carry a dock, how many
    // delegate copies each item has registered, and which one last took input.
    function screenState(): string {
      var counts = {}
      for (var id in root.delegatesById) counts[id] = root.delegatesById[id].length
      return JSON.stringify({
        mode: root.screenMode,
        screens: root.dockScreens.map(function(s) { return s.name }),
        rows: Object.keys(root.rowByScreenName),
        activeScreen: root.activeScreenName,
        hover: {
          item: root.hoveredItemId,
          x: root.hoveredMouseX,
          surface: root.surfaceHovered,
          tooltip: root.tooltipVisible
        },
        delegates: counts
      })
    }
    function bounceState(): string {
      return JSON.stringify({ bouncing: root.bouncingIds })
    }
  }

  function saveSettings() {
    var content = DockModel.serializeSettings({ autoHide: root.autoHide, dockSide: root.dockSide, screenMode: root.screenMode })
    root.settingsWriteUntil = Date.now() + 2000
    DockModel.markSettingsWritten(content)
    // settingsFile uses atomicWrites: setText writes to a sibling temp and
    // renames it into place itself, so no separate mv Process is needed (the
    // old manual .tmp + Process dance never completed the rename, leaving the
    // on-disk file stale and snapping the dock back to bottom/center on reload).
    settingsFile.setText(content)
  }

  onDockSideChanged: {
    // Re-layout for the new axis, drop any hover preview (its anchor is
    // side-dependent) and persist the choice.
    root.hidePreview()
    root.clearHover()
    root.applyLayout()
    root.saveSettings()
  }

  onScreenModeChanged: root.saveSettings()

  // Central helper: build the state snapshot consumed by the pure helpers.
  function hideState() {
    return {
      autoHide: root.autoHide,
      enabled: root.enabled,
      dockReady: root.dockReady,
      autoHidden: root.autoHidden,
      dockEngaged: root.dockEngaged,
      hideSuppressed: root.hideSuppressed,
      dockHovered: root.dockHovered,
      edgeHovered: root.edgeHovered
    }
  }

  function maybeScheduleHide() {
    var ok = DockModel.shouldScheduleHide(hideState())
    if (ok) hideTimer.restart()
  }

  onAutoHideChanged: {
    if (!root.autoHide) {
      hideTimer.stop()
      showTimer.stop()
      root.autoHidden = false
    } else {
      maybeScheduleHide()
    }
  }

  onHideSuppressedChanged: {
    if (root.hideSuppressed) {
      hideTimer.stop()
    } else {
      maybeScheduleHide()
    }
  }

  onEnabledChanged: {
    if (!root.enabled) root.hidePreview()
    if (!root.enabled) {
      // Manual hide (Super+H) always stops auto-hide timers.
      hideTimer.stop()
      showTimer.stop()
    } else {
      maybeScheduleHide()
    }
  }

  onDockReadyChanged: {
    maybeScheduleHide()
  }

  onDockHoveredChanged: {
    if (root.dockHovered) {
      hideTimer.stop()
      showTimer.stop()
      if (root.autoHide && root.autoHidden) root.autoHidden = false
    } else {
      root.clearHover()
      maybeScheduleHide()
    }
  }

  onDockEngagedChanged: {
    // The fragile 5px gap between dock bottom and edge is now covered by
    // dockEngaged. A single handler here would suffice, but we keep the
    // explicit dock/edge handlers for the reveal path.
    if (!root.dockEngaged) maybeScheduleHide()
    else hideTimer.stop()
  }

  onEdgeHoveredChanged: {
    if (root.edgeHovered) {
      hideTimer.stop()
      if (DockModel.shouldRevealDock(hideState())) showTimer.restart()
    } else {
      showTimer.stop()
      maybeScheduleHide()
      if (root.autoHide && root.autoHidden) {
        // Edge left while still hidden — cancel pending show, stay hidden.
        showTimer.stop()
      }
    }
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
    try {
      var resolved = DockModel.desktopIdForWindow(raw, root.appEntries)
      if (resolved) return resolved
    } catch (error) {}
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
    var libraryEntries = []
    if (root.shell && root.shell.appLibrary) {
      try {
        var rows = root.shell.appLibrary.sortedEntries("") || []
        // AppLibrary returns sorted rows shaped as { entry, score, key, name }.
        // Keep only the underlying desktop entries for dock lookup. The
        // desktop-entry index is merged below because this facade can omit
        // installed apps that have no open window yet.
        libraryEntries = rows.map(function(row) { return row && row.entry ? row.entry : row })
      } catch (error) {
        console.warn("macos.dock: app library refresh failed", error)
      }
    }

    // Omarchy 4.0.3 hands panels a scoped shell facade with appLibrary null.
    // DesktopEntries is also the source that lets Manage Icons show apps
    // before their first window opens, so always merge it when available.
    try {
      var values = DesktopEntries.applications.values || []
      root.appEntries = DockModel.mergeAppEntries(libraryEntries, values)
      root.appLibraryReady = root.appEntries.length > 0
    } catch (error) {
      console.warn("macos.dock: desktop-entry fallback failed", error)
      root.appEntries = DockModel.mergeAppEntries(libraryEntries, [])
      root.appLibraryReady = root.appEntries.length > 0
    }
    refreshItems()
  }

  function refreshItems() {
    var prevRunning = root.runningIds ? root.runningIds.slice() : []
    var nextRunning = normalizeRunning()
    root.runningIds = nextRunning
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
    // Launch bounce: any NOT RUNNING -> RUNNING transition bounces once,
    // exactly when the app opens. Dock clicks, external launches and
    // newly appearing apps all funnel through here.
    for (var i = 0; i < nextRunning.length; i++) {
      var rid = nextRunning[i]
      if (prevRunning.indexOf(rid) !== -1) continue
      root.triggerLaunchBounce(rid)
    }
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
    // The row belongs to the output the hover came from: with one dock per
    // screen, mapping through another screen's row would land on the wrong
    // slot. A rotated (-90°) row cannot be inverted arithmetically, so use the
    // registered row of the active screen.
    var row = root.activeRow
    if (!row) return -1
    if (root.vertical) return row.mapFromItem(null, 0, root.hoveredMouseX).x
    return row.mapFromItem(null, root.hoveredMouseX, 0).x
  }

  // Leaving the dock over a gap or the surface padding never triggers a
  // DockItem exit, so reset the hover state here or icons stay magnified.
  function clearHover() {
    if (root.floatingId) return // the drag controller owns hoveredMouseX
    root.hoveredItemId = ""
    root.hoveredMouseX = -1
    root.applyLayout()
  }

  function registerItem(id, item) {
    var list = root.delegatesById[id] || []
    if (list.indexOf(item) !== -1) return
    root.delegatesById[id] = list.concat([item])
  }
  function unregisterItem(id, item) {
    var list = root.delegatesById[id]
    if (list) {
      var index = list.indexOf(item)
      if (index !== -1) {
        var next = list.slice()
        next.splice(index, 1)
        if (next.length === 0) delete root.delegatesById[id]
        else root.delegatesById[id] = next
      }
    }
    var i = root.bouncingIds.indexOf(id)
    if (i !== -1) {
      var nextBouncing = root.bouncingIds.slice()
      nextBouncing.splice(i, 1)
      root.bouncingIds = nextBouncing
    }
  }
  function delegatesFor(id) { return root.delegatesById[id] || [] }
  function eachDelegate(id, fn) {
    var list = root.delegatesFor(id)
    for (var i = 0; i < list.length; i++) fn(list[i])
  }

  // ---- Launch bounce (macOS "animate opening applications") ----------------
  // One launch = one fixed one-shot bounce, starting when the app actually
  // opens (NOT RUNNING -> RUNNING). The animation always runs to completion;
  // `running` is only the launch detector, never a stop signal.
  function triggerLaunchBounce(id) {
    if (!id || id === "__phantom__") return
    if (id === root.floatingId) return
    // No visible surface, no bounce: when auto-hide has slid the dock
    // off-screen (or the dock is toggled off) the upward bounce would peek
    // out at the screen edge while the app opens. Skip it outright instead
    // of animating where nobody can see it properly.
    if (!root.enabled || (root.autoHide && root.autoHidden)) return
    if (root.bouncingIds.indexOf(id) !== -1) return
    var list = root.delegatesFor(id)
    if (list.length > 0) {
      root.bouncingIds = root.bouncingIds.concat([id])
      // playBounce returns false when gated (animation disabled / dragging);
      // drop the guard immediately so it cannot leak without a finish signal.
      // Every output shows the same dock, so every copy bounces.
      var started = false
      for (var i = 0; i < list.length; i++) {
        if (typeof list[i].playBounce === "function" && list[i].playBounce()) started = true
      }
      if (!started) root.finishLaunchBounce(id)
    } else {
      // Delegate does not exist yet (newly appearing app): record the intent
      // and Component.onCompleted auto-plays on creation.
      root.bouncingIds = root.bouncingIds.concat([id])
    }
  }
  function finishLaunchBounce(id) {
    var i = root.bouncingIds.indexOf(id)
    if (i !== -1) {
      var next = root.bouncingIds.slice()
      next.splice(i, 1)
      root.bouncingIds = next
    }
    root.eachDelegate(id, function(d) { d.bounceOffset = 0 })
  }
  function cancelLaunchBounce(id) {
    if (!id) return
    var list = root.delegatesFor(id)
    for (var i = 0; i < list.length; i++) {
      if (typeof list[i].cancelBounce === "function") list[i].cancelBounce()
      else list[i].bounceOffset = 0
    }
    var j = root.bouncingIds.indexOf(id)
    if (j !== -1) {
      var next = root.bouncingIds.slice()
      next.splice(j, 1)
      root.bouncingIds = next
    }
  }

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
    var mainFlow = DockModel.buildFlow(
      root.dockOrder,
      [],
      root.floatingId,
      root.floatingId ? root.tempDrag.index : -1
    )
    var fullFlow = mainFlow.slice()
    var result = DockModel.computeLayout(fullFlow, cursorX, DockModel.LAYOUT_OPTS)
    root.placements = result.placements
    root.layoutWidth = result.totalWidth
    for (var id in result.placements) {
      var p = result.placements[id]
      var list = root.delegatesFor(id)
      for (var i = 0; i < list.length; i++) {
        var d = list[i]
        d.x = p.x
        d.targetScale = p.scale
        // Side docks grow inward through the transform origin; a vertical
        // translation here would make the icon drift along the edge instead.
        d.targetLift = root.vertical ? 0 : p.lift
        d.targetOpacity = (id === root.floatingId) ? 0 : (p.phantom ? 0.45 : 1)
      }
    }
    // The dragged item is excluded from the flow so it has no placement; hide
    // its dock copy while the ghost follows the cursor.
    root.eachDelegate(root.floatingId, function(d) { d.targetOpacity = 0 })
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

  // Omarchy 4.0.3 scopes appLibrary away from panel plugins. Keep using the
  // shell service when available, with the UWSM desktop-entry path as fallback.
  function launchApp(id, name) {
    var appId = String(id || "").replace(/\.desktop$/, "")
    if (!appId) return false
    if (root.shell && root.shell.appLibrary && typeof root.shell.appLibrary.launch === "function") {
      root.shell.appLibrary.launch(appId, String(name || appId))
      return true
    }
    Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", appId + ".desktop"])
    return true
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
    // The launch bounce fires when the app actually opens (NOT RUNNING ->
    // RUNNING in refreshItems), not here — so the motion coincides with the
    // app appearing, like the native Dock.
    root.launchApp(item.id, (entry && entry.name) || item.name)
  }

  function openDownloads() {
    hideTimer.stop()
    Quickshell.execDetached(["xdg-open", root.downloadsPath])
  }

  function openTrash() {
    hideTimer.stop()
    // gio trash:// works on GNOME, fallback to the Trash/files path
    Quickshell.execDetached(["bash", "-c", "xdg-open trash:/// 2>/dev/null || xdg-open \"" + root.trashFilesPath + "\" 2>/dev/null || xdg-open ~/.local/share/Trash 2>/dev/null &"])
  }

  function emptyTrash() {
    Quickshell.execDetached(["bash", "-c", "gio trash --empty 2>/dev/null || rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/* 2>/dev/null &"])
    // Refresh status after a short delay
    trashRefreshTimer.restart()
  }

  function updateTrashStatus() {
    if (!trashCheckProcess.running) trashCheckProcess.running = true
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
    root.launchApp(id, label)
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
    // pinFile uses atomicWrites, so setText renames a sibling temp into place
    // itself; the previous manual .tmp + mv Process never completed.
    pinFile.setText(content)
    root.refreshItems()
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
    if (action === "toggleAutoHide") {
      root.autoHide = !root.autoHide
      root.saveSettings()
      return
    }
    if (action === "setSideBottom" || action === "setSideLeft" || action === "setSideRight") {
      var newSide = action.slice(7).toLowerCase()
      root.dockSide = newSide
      return
    }
    // Special items: Downloads / Trash — treat menu actions as folder actions
    if (item && (item.id === "downloads" || item.id === "trash")) {
      if (action === "togglePin" || action === "newWindow") {
        if (item.id === "downloads") root.openDownloads()
        else root.openTrash()
        return
      }
      if (action === "close") {
        if (item.id === "trash") {
          if (root.trashFull) root.emptyTrash()
          else root.openTrash()
        } else {
          root.openDownloads()
        }
        return
      }
    }
    if (!item) return
    if (action === "togglePin") root.pinnedIds = DockModel.togglePinned(root.pinnedIds, item.id)
    else if (action === "newWindow") handleClick({ id: item.id, name: item.name, running: false })
    else if (action === "close") closeWindow(item.id)
    else if (action === "setIcon") root.openIconPicker(item.id, item.name, false, true)
    else if (action === "manageIcons") root.openIconManager(item)
    if (action === "togglePin") { refreshItems(); savePinned() }
  }

  function openIconPicker(appId, appName, fromManage, fromDockMenu) {
    root.menuOpen = false
    dockMenu.opened = false
    root.pickerReturnItem = dockMenu.itemData
    root.pickerOpen = true
    root.hidePreview()
    iconPicker.openForApp(appId, appName, fromManage, fromDockMenu)
  }

  function openIconManager(item) {
    root.menuOpen = false
    dockMenu.opened = false
    root.pickerReturnItem = item || dockMenu.itemData
    root.pickerOpen = true
    root.hidePreview()
    iconPicker.openManage(true)
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
      // Dragging takes priority over the launch bounce: cancel any active
      // bounce so no stale vertical offset survives the drag.
      root.cancelLaunchBounce(item.id)
    }
    root.hoveredMouseX = root.vertical ? position.y : position.x
    root.hidePreview()
    // The dock surface's own size, not a delegate's: this runs for whichever
    // output received the drag.
    root.dragInsideDock =
      surfacePosition.x >= 0 && surfacePosition.x <= root.surfaceWidth &&
      surfacePosition.y >= 0 && surfacePosition.y <= root.surfaceHeight
    var half = root.iconSize * root.ghostScale / 2
    root.ghostX = position.x - half + (root.vertical ? (root.dockSide === "left" ? 30 : -30) : 0)
    root.ghostY = position.y - half - (root.vertical ? 0 : 30)
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
    console.log("macos.dock finishDrag", JSON.stringify({ id: id, inside: inside, localX: surfacePosition.x, localY: surfacePosition.y, surfaceW: root.surfaceWidth, surfaceH: root.surfaceHeight, cursorX: root.cursorXInRow() }))
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
        var dropDelegate = root.delegatesFor(id)[0]
        if (dropP && dropDelegate) {
          // Snap the dropped copy straight to its new slot. Without this the
          // settle spring carries it the whole way from its old slot and swings
          // back past the drop point before settling. The delegate is invisible
          // (opacity 0) while floating, so the snap is seamless: it appears
          // instantly at full opacity exactly where the ghost was, and
          // applyLayout then assigns the identical x, so no spring runs.
          var dropList = root.delegatesFor(id)
          for (var k = 0; k < dropList.length; k++) {
            dropList[k].animating = false
            dropList[k].x = dropP.x
            if (k === 0) dropList[k].targetOpacity = 1
            dropList[k].animating = true
          }
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
    var restoredDelegates = root.delegatesFor(id)
    for (var r = 0; r < restoredDelegates.length; r++) {
      restoredDelegates[r].animating = false
      restoredDelegates[r].targetOpacity = 1
      restoredDelegates[r].animating = true
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
      if (root.floatingId || root.menuOpen || root.pickerOpen || !root.enabled) return
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
      root.previewBottomY = root.surfaceY
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
    // Do not hand the theme's generic placeholder to appLibrary.iconSource:
    // some shell versions resolve it to a concrete purple/black image before
    // we can recognize that it was only a placeholder. Known ID fallbacks
    // still get their mapped icon; unknown apps use OmaDock's neutral mark.
    if (iconName === "application-x-executable") {
      var mappedName = IconResolver.resolveIcon(entry)
      if (mappedName === "application-x-executable") return root.defaultIconSource()
    }
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
      return root.defaultIconSource()
    }
    // appLibrary unavailable (Omarchy 4.0.3, see refreshApps()) -- every
    // caller of this function used to dead-end here and fall back to
    // whatever placeholder it draws on an empty string (a broken-image
    // glyph in AltTabPanel, nothing at all in the ghost-drag preview and the
    // icon picker's override). DockItem's OWN icon rendering never had this
    // problem because it never went through iconSourceFor for its fallback
    // path -- it resolves via Quickshell.iconPath() directly, which needs no
    // shell facade at all. Do the same here instead of giving up.
    var themeName = IconResolver.resolveIcon(entry)
    if (themeName === "application-x-executable") return root.defaultIconSource()
    return themeName ? Quickshell.iconPath(themeName, true) : ""
  }

  function defaultIconSource() {
    return Util.fileUrl(root.home + "/.config/omarchy/plugins/macos.dock/assets/" + IconResolver.DEFAULT_ICON_ASSET)
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
      if (!root.previewAppId || root.floatingId || root.menuOpen || root.pickerOpen || !root.enabled) return
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
    atomicWrites: true
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
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = DockModel.parseSettings(text(), { autoHide: true, dockSide: "bottom", screenMode: "all" })
      if (!root.settingsLoaded) {
        root.settingsLoaded = true
        root.autoHide = parsed.autoHide
      } else {
        if (!DockModel.shouldReprocessSettings(text())) return
        root.autoHide = parsed.autoHide
      }
      if (root.dockSide !== parsed.dockSide) root.dockSide = parsed.dockSide
      if (root.screenMode !== parsed.screenMode) root.screenMode = parsed.screenMode
      // If auto-hide is turned off, ensure the dock is fully revealed.
      if (!root.autoHide) root.autoHidden = false
    }
    onFileChanged: {
      if (Date.now() < root.settingsWriteUntil) return
      settingsFile.reload()
    }
    onLoadFailed: {
      root.settingsLoaded = true
      root.autoHide = true
      root.dockSide = "bottom"
      root.screenMode = "all"
    }
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
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshApps() }
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // Hyprland emits monitoradded(v2)/monitorremoved(v2) when outputs
      // appear or disappear (replug, DPMS, suspend/resume). Re-map our
      // layer surfaces onto the new output (see #13).
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "monitoradded" || name === "monitoraddedv2"
          || name === "monitorremoved" || name === "monitorremovedv2") {
        root.triggerRemap(false)
      }
    }
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
    if (!helperResolveProcess.running) helperResolveProcess.running = true
    if (!trashCheckProcess.running) trashCheckProcess.running = true
    // The alt-tab HUD opens/closes on keypresses; Hyprland's default layer
    // fade would add a visible fade-in. Disable compositor animation for
    // both layer namespaces so the HUD pops in instantly.
    if (!layerRuleProcess.running) layerRuleProcess.running = true
    // Register the app-switcher keybinds so the HUD works out of the box.
    // Config-file binds load before this runtime eval, so a user's own bind
    // for the same combo takes precedence.
    if (!altTabBindProcess.running) altTabBindProcess.running = true
    // The shell applies the config-file binds (tiling.lua etc.) AFTER this
    // Component.onCompleted eval, clobbering our ALT+TAB takeover. Re-apply
    // the eval on a short retry window until the config binds have landed;
    // the eval is idempotent (unbind then bind).
    altTabBindRetry.start()
    Qt.callLater(function() { root.dockReady = true })
  }

  Process {
    id: layerRuleProcess
    command: ["hyprctl", "eval", "hl.layer_rule({ match = { namespace = \"macos-dock-alt-tab\" }, no_anim = true, animation = \"none\" })"]
  }

  Timer {
    id: altTabBindRetry
    interval: 1500
    repeat: true
    property int attempts: 0
    onTriggered: {
      altTabBindRetry.attempts++
      if (altTabBindRetry.attempts > 8) altTabBindRetry.stop()
      else if (!altTabBindProcess.running) altTabBindProcess.running = true
    }
  }

  Process {
    id: altTabBindProcess
    // Take over the default Omarchy ALT+TAB window cycling so the macOS-style
    // app switcher HUD is the primary alt-tab. The defaults bind ALT+TAB twice
    // (cycle + bring-to-top), so both must be unbound first. ALT+GRAVE stays
    // as the dedicated fallback combo.
    command: ["hyprctl", "eval", "hl.unbind(\"ALT + TAB\") hl.unbind(\"ALT + SHIFT + TAB\") hl.unbind(\"ALT + GRAVE\") hl.unbind(\"ALT + SHIFT + GRAVE\") o.bind(\"ALT + TAB\", \"App switcher next\", \"omarchy-shell -q macos.dock altTabNext\") o.bind(\"ALT + SHIFT + TAB\", \"App switcher prev\", \"omarchy-shell -q macos.dock altTabPrev\") o.bind(\"ALT + GRAVE\", \"App switcher next\", \"omarchy-shell -q macos.dock altTabNext\") o.bind(\"ALT + SHIFT + GRAVE\", \"App switcher prev\", \"omarchy-shell -q macos.dock altTabPrev\")"]
  }

  Variants {
    model: root.dockScreens

    delegate: Component {
      PanelWindow {
        id: dockWindow
        required property var modelData
        // The Repeater below shadows `modelData` with the dock item id, so the
        // output name is captured once here for the handlers nested inside it.
        readonly property string outputName: modelData.name
        visible: !root.conflictDetected && root.enabled && !root.remapping
        screen: modelData
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "macos-dock"
        anchors { top: true; bottom: true; left: true; right: true }
        // Anchored to all four edges on purpose: drag-to-reorder and the hover
        // magnify effect both need pointer coordinates across the whole screen,
        // not just the dock's own footprint. `mask` narrows hit-testing to
        // `dockSurface`, but Hyprland's `layer_rule blur` operates on the full
        // layer geometry regardless of the mask — a `blur = true` rule on this
        // namespace was measured blurring the ENTIRE monitor behind it, not just
        // the small visible pill, on any host with Hyprland blur enabled. The
        // 0.50 alpha tint below is deliberately the only "glass" effect; no
        // compositor backdrop blur is requested for this namespace or for
        // "macos-dock-material" in DockPanel.qml, which shares this geometry.
        mask: Region { item: dockSurface }
    
        // Publish this output's dock row: cursorXInRow() needs the row belonging to
        // the screen the hover came from, and only the delegate can reach its own.
        Component.onCompleted: root.registerRow(modelData.name, dockRow)
        Component.onDestruction: root.unregisterRow(modelData.name)
    
        Rectangle {
          id: dockSurface
          x: root.surfaceForScreen(modelData).x
          y: root.surfaceForScreen(modelData).y
          width: root.surfaceWidth
          height: root.surfaceHeight
          radius: 18
          color: Util.alpha(Color.background, 0.50)
          border.color: Util.alpha(Color.foreground, 0.04)
          border.width: 1
          opacity: !root.enabled ? 0 : (root.menuOpen || root.pickerOpen || root.dockHovered ? 1 : 0.96)
    
          // Top edge now matches the other three sides via the 1px border
          // (0.04) alone — no extra highlight, so the dock reads as a uniform
          // glass pill instead of a brighter top. Removed the previous 0.10 bar
          // that made the top brighter than left/right/bottom.
    
          Behavior on x {
            NumberAnimation { duration: root.autoHidden ? root.hideDuration : root.showDuration; easing.type: Easing.OutCubic }
          }
          Behavior on y {
            NumberAnimation { duration: root.autoHidden ? root.hideDuration : root.showDuration; easing.type: Easing.OutCubic }
          }
          Behavior on width {
            NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
          }
          Behavior on height {
            NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
          }
          Behavior on opacity { NumberAnimation { duration: 180 } }
    
          Item {
            id: dockRow
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 6
            width: root.layoutWidth - 2 * root.sidePadding
            height: 70
            // Left/right docks reuse the horizontal layout engine: the row is
            // rotated -90° so the x-axis becomes screen-y (first item on top) and
            // each wrapper counter-rotates +90° to keep icons upright.
            rotation: root.vertical ? -90 : 0
    
            Behavior on width {
              NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
            }
            Behavior on rotation {
              NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
            }
    
            Repeater {
              model: root.dockItems
              delegate: Item {
                id: wrapper
                required property string modelData
                // The wrapper spans the scaled slot so the centered icon sits at
                // the slot's visual center — a single magnified icon stays
                // centered in the dock instead of drifting left.
                width: root.slotWidth * targetScale
                height: 70
                x: 0
                rotation: root.vertical ? 90 : 0
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
                property alias bounceOffset: dockItem.bounceOffset
                function playBounce() { return dockItem.playLaunchBounce() }
                function cancelBounce() { dockItem.cancelLaunchBounce() }
    
                Behavior on x {
                  enabled: wrapper.animating
                  SpringAnimation { spring: 4.5; damping: 0.95; mass: 1 }
                }
    
                Component.onCompleted: {
                  root.registerItem(modelData, wrapper)
                  var seed = root.seedFor(modelData)
                  x = seed.x
                  targetScale = seed.scale
                  targetLift = seed.lift
                  targetOpacity = (modelData === root.floatingId) ? 0 : 1
                  animating = true
                  // Newly appearing launched app: the bounce intent was recorded
                  // before this delegate existed; play it now that animation is on.
                  if (root.bouncingIds.indexOf(modelData) !== -1 && !dockItem.playLaunchBounce())
                    root.finishLaunchBounce(modelData)
                }
                Component.onDestruction: {
                  root.visualCache[modelData] = { x: x, scale: targetScale, lift: targetLift }
                  root.unregisterItem(modelData, wrapper)
                }
    
                DockItem {
                  id: dockItem
                  anchors.centerIn: parent
                  itemData: wrapper.liveData
                  iconSize: root.iconSize
                  dockSide: root.dockSide
                  animationEnabled: wrapper.animating
                  iconSourceOverride: root.iconSourceFor(modelData)
                  onItemLeftClicked: function(clickedItem) { root.handleClick(clickedItem) }
                  onItemRightClicked: function(clickedItem, position) { root.openMenu(clickedItem, position) }
                  onLaunchBounceFinished: root.finishLaunchBounce(modelData)
                  onDragMoved: function(draggedItem, position) {
                    root.onDragMoved(draggedItem,
                      dockItem.mapToItem(null, position.x, position.y),
                      dockItem.mapToItem(dockSurface, position.x, position.y))
                  }
                  onDragFinished: function(draggedItem, position) {
                    root.finishDrag(draggedItem, dockItem.mapToItem(dockSurface, position.x, position.y))
                  }
                  onTooltipRequested: function(hoveredItem, isVisible, center) {
                    root.markActiveScreen(dockWindow.outputName)
                    root.tooltipCenterX = root.vertical ? center.y : center.x
                    root.onItemHoverChanged(hoveredItem, isVisible, root.tooltipCenterX)
                    root.showTooltip(hoveredItem, isVisible)
                  }
                  onHoverPointerChanged: function(hoveredItem, isInside, position) {
                    root.markActiveScreen(dockWindow.outputName)
                    if (isInside) {
                      root.hoveredItemId = hoveredItem.id
                      root.hoveredMouseX = root.vertical ? position.y : position.x
                      root.tooltipCenterX = root.vertical ? position.y : position.x
                    } else if (!root.floatingId && root.hoveredItemId === hoveredItem.id) {
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
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            // This delegate publishes hover for root.dockHovered: only the screen
            // under the cursor can be hovering, so a plain boolean is enough.
            onContainsMouseChanged: root.surfaceHovered = containsMouse
            onEntered: root.markActiveScreen(modelData.name)
            onExited: {
              root.maybeScheduleHide()
            }
            onPositionChanged: {
              var hoverPoint = mouseArea.mapToItem(null, mouseX, mouseY)
              root.hoveredMouseX = root.vertical ? hoverPoint.y : hoverPoint.x
              root.applyLayout()
            }
            onClicked: function(mouse) {
              if (mouse.button === Qt.RightButton) root.openIconManager()
            }
          }
        }
    
        Rectangle {
          visible: root.tooltipVisible && root.tooltipItem !== null && root.activeScreenName === modelData.name
          z: 20
          x: {
            if (root.vertical && root.dockSide === "left") return dockSurface.x + dockSurface.width + 8
            if (root.vertical) return dockSurface.x - width - 8
            return Math.max(12, Math.min(root.tooltipCenterX - width / 2, parent.width - width - 12))
          }
          y: {
            if (!root.vertical) return dockSurface.y - height - 8
            return Math.max(12, Math.min(root.tooltipCenterX - height / 2, parent.height - height - 12))
          }
          width: tooltipText.implicitWidth + 20
          height: 24
          radius: 8
          color: Util.alpha(Color.background, 0.88)
          border.color: Util.alpha(Color.foreground, 0.08)
          border.width: 1
          Text {
            textFormat: Text.PlainText
            id: tooltipText
            anchors.centerIn: parent
            text: root.tooltipItem ? (root.tooltipItem.name || root.tooltipItem.id) : ""
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          // Subtle stem pointing toward the dock icon.
          Rectangle {
            x: {
              if (root.vertical && root.dockSide === "left") return -4
              if (root.vertical && root.dockSide === "right") return parent.width - 4
              return (parent.width - 8) / 2
            }
            y: root.vertical ? (parent.height - 8) / 2 : parent.height - 5
            width: 8
            height: 8
            radius: 1
            color: parent.color
            border.color: parent.border.color
            border.width: 1
            rotation: 45
          }
        }
    
        MouseArea {
          x: root.vertical ? (root.dockSide === "left" ? 0 : parent.width - 18) : 0
          y: root.vertical ? 0 : parent.height - 18
          width: root.vertical ? 18 : parent.width
          height: root.vertical ? parent.height : 18
          hoverEnabled: true
          // Hover here is already covered by the full dockSurface mouseArea
          // (containsMouse) and by icon hover (hoveredItemId). No manual
          // dockHovered needed — the binding handles it.
          onExited: root.clearHover()
        }
      }
    }
  }

  Timer {
    id: hideTimer
    interval: root.hideDelay
    onTriggered: {
      if (!DockModel.shouldHideDock(hideState())) return
      root.autoHidden = true
    }
  }

  Timer {
    id: showTimer
    interval: root.showDelay
    onTriggered: {
      if (!DockModel.shouldRevealDock(hideState())) return
      root.autoHidden = false
      hideTimer.stop()
    }
  }

  DockMenu {
    id: dockMenu
    autoHideEnabled: root.autoHide
    dockSide: root.dockSide
    iconSource: root.iconSourceFor(dockMenu.itemData ? dockMenu.itemData.id : "")
    onActionTriggered: function(actionName, selectedItem) { root.menuAction(actionName, selectedItem) }
    onOpenedChanged: if (!opened) root.menuOpen = false
  }

  IconPickerPanel {
    id: iconPicker
    shell: root.shell
    customIcons: root.customIcons
    iconSourceFor: function(id) { return root.iconSourceFor(id) }
    helperPath: root.helperPath
    onBackRequested: {
      var previousItem = root.pickerReturnItem
      iconPicker.close()
      root.pickerOpen = false
      // Let the picker surface finish unmapping before restoring the dock
      // menu. Without the deferred handoff, its back button can remain as a
      // small orphaned input surface above the newly opened menu.
      Qt.callLater(function() {
        if (previousItem) root.openMenu(previousItem, Qt.point(root.width / 2, root.height / 2))
      })
    }
    onOpenChanged: {
      if (!open) root.pickerOpen = false
    }
  }

  // Resolve the icon helper: prefer the documented install location, fall
  // back to PATH. The picker surface shows a clear error if neither exists.
  Process {
    id: helperResolveProcess
    command: ["bash", "-c", "if [ -x \"$HOME/.config/omarchy/plugins/macos.dock/scripts/omarchy-dock-icon\" ]; then printf '%s' \"$HOME/.config/omarchy/plugins/macos.dock/scripts/omarchy-dock-icon\"; elif [ -x \"$HOME/.local/bin/omarchy-dock-icon\" ]; then printf '%s' \"$HOME/.local/bin/omarchy-dock-icon\"; else command -v omarchy-dock-icon || true; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var resolved = String(text || "").trim()
        if (resolved) root.helperPath = resolved
      }
    }
  }

  // Trash full/empty detection — poll the Trash files directory.
  Process {
    id: trashCheckProcess
    command: ["bash", "-c", "ls -A \"" + root.trashFilesPath + "\" 2>/dev/null | head -1 | grep -q . && echo full || echo empty"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var s = String(text || "").trim()
        root.trashFull = (s === "full")
      }
    }
  }

  Timer {
    id: trashPollTimer
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.updateTrashStatus()
  }

  Timer {
    id: trashRefreshTimer
    interval: 600
    onTriggered: root.updateTrashStatus()
  }

  FileView {
    id: trashWatcher
    path: root.trashFilesPath
    watchChanges: true
    printErrors: false
    onFileChanged: trashRefreshTimer.restart()
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
    // Above the dock that was actually hovered, not screens[0]: the geometry
    // it is given (dockX/dockY/centerX) is in that output's coordinates.
    screen: root.activeScreen
    previewVisible: root.previewVisible && !root.floatingId && !root.menuOpen
    windowList: root.previewWindows
    centerX: root.previewCenterX
    bottomY: root.previewBottomY
    dockSide: root.dockSide
    dockX: root.surfaceX
    dockY: root.surfaceY
    dockW: root.surfaceWidth
    dockH: root.surfaceHeight
    iconSourceFor: function(data) { return root.iconSourceFor({ id: root.previewAppId }) }
    thumbnailFor: function(data) { return root.thumbnailFor(data) }
    onActivated: function(data) { root.activatePreviewWindow(data) }
    onPreviewHoverEntered: previewGrace.stop()
    onPreviewHoverExited: previewGrace.restart()
  }

  AltTabPanel {
    id: altTab
    screen: root.focusedScreen()
    iconSourceFor: function(app) { return root.iconSourceFor(app.id) }
    onActivated: function(appId, appName) { root.activateApp(appId, appName) }
  }

  // Tiling window adaptation: a transparent, input-less layer that reserves
  // the dock's footprint as a Wayland exclusive zone, so tiled windows never
  // overlap the dock. In auto-hide (overlay) mode the zone is always 0 so
  // tiled windows can use the full screen and the dock overlays them like
  // macOS. A separate surface keeps the full-screen dockWindow (whose
  // coordinate space drag ghosts and tooltips rely on) untouched; the zone is
  // simply ignored on surfaces anchored to all four edges. When the dock is
  // hidden the spacer unmaps and tiled windows reclaim the space.
  Variants {
    model: root.dockScreens

    delegate: Component {
      PanelWindow {
        id: dockSpacerWindow
        required property var modelData
        visible: !root.conflictDetected && root.enabled && !root.autoHide && !root.remapping
        screen: modelData
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "macos-dock-spacer"
        WlrLayershell.exclusiveZone: root.autoHide ? 0 : (root.enabled ? root.dockHeight + root.bottomMargin : 0)
        // The exclusive zone is edge-anchored so tiled windows avoid the dock
        // footprint on whichever side the dock currently lives. Anchors are
        // assigned plain booleans (never undefined), so each side commits a
        // complete, non-conflicting anchor set that reliably detaches the
        // previous one. PanelWindow has no state machine, so no states here.
        anchors.top: root.dockSide !== "bottom"
        anchors.bottom: true
        anchors.left: root.dockSide !== "right"
        anchors.right: root.dockSide === "right"
        implicitWidth: root.dockSide === "bottom" ? 0 : root.dockHeight + root.bottomMargin
        implicitHeight: root.dockSide === "bottom" ? root.dockHeight + root.bottomMargin : 0
        mask: Region {}
      }
    }
  }

  // Edge hot-zone: a 3px invisible strip at the screen bottom that reveals
  // the dock even when it is fully slid off-screen and keeps it visible while
  // the cursor lingers at the edge. Using its own PanelWindow keeps
  // hit-testing alive while dockWindow's mask is off-screen or gapped (8px).
  // The timer adds a subtle 100ms debounce so accidental brushes don't pop
  // the dock, and edgeHovered participates in hide suppression like dockHovered.
  Variants {
    model: root.dockScreens

    delegate: Component {
      PanelWindow {
        id: edgeHotZone
        required property var modelData
        visible: !root.conflictDetected && root.enabled && root.autoHide && root.dockReady && !root.remapping
        screen: modelData
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "macos-dock-edge"
        // Full-screen surface on every side; input is limited to the mask below,
        // exactly like dockWindow, so the hot-zone can never balloon into a
        // full-screen input grab (the previous conditional-undefined anchors did).
        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true
        mask: Region { item: edgeMouse }
    
        Item {
          id: edgeMouse
          x: root.dockSide === "bottom" ? 0 : (root.dockSide === "left" ? 0 : parent.width - root.edgeHeight)
          y: root.dockSide === "bottom" ? parent.height - root.edgeHeight : 0
          width: root.dockSide === "bottom" ? parent.width : root.edgeHeight
          height: root.dockSide === "bottom" ? root.edgeHeight : parent.height
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: {
              root.markActiveScreen(modelData.name)
              root.edgeHovered = true
              if (!root.autoHide) return
              if (root.autoHidden) showTimer.restart()
              else hideTimer.stop()
            }
            onExited: {
              root.edgeHovered = false
              showTimer.stop()
              // Leaving the edge while dock is still hidden cancels pending show.
              // Leaving while visible will arm hide via onEdgeHoveredChanged.
            }
          }
        }
      }
    }
  }

  // The dragged icon lives in its own overlay window so it can follow the
  // cursor anywhere on screen without clipping against the dock's mask. Its
  // input region is only the anchor, so it never blocks clicks. Position is
  // driven externally by the drag controller from the phantom's mouse events.
  PanelWindow {
    id: dragGhostWindow
    visible: root.ghostSource !== ""
    // The ghost follows the cursor on the output the drag started on (set by
    // the dock surface that received it), never on a fixed screen.
    screen: root.activeScreen
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
      Behavior on x { SpringAnimation { spring: 4.5; damping: 0.95; mass: 1 } }
      Behavior on y { SpringAnimation { spring: 4.5; damping: 0.95; mass: 1 } }
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
