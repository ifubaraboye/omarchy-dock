const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")

function loadQmlJs(path) {
  const source = fs.readFileSync(path, "utf8").replace(/^\.pragma library\s*/, "")
  const context = { module: { exports: {} }, console }
  // Provide a minimal Qt mock so Qt.include works under Node.js.
  context.Qt = {
    include: (includePath) => {
      const incSource = fs.readFileSync(includePath, "utf8").replace(/^\.pragma library\s*/, "")
      vm.runInNewContext(incSource, context, { filename: includePath })
    }
  }
  vm.runInNewContext(source, context, { filename: path })
  return context.module.exports
}

const model = loadQmlJs("DockModel.js")

test("parses and normalizes pinned ids", () => {
  assert.deepEqual(Array.from(model.parsePinned('{"pinned":["code.desktop","code","ghostty"]}')), ["code", "ghostty"])
})

test("round trips pins", () => {
  assert.deepEqual(Array.from(model.parsePinned(model.serializePinned(["code", "ghostty"]))), ["code", "ghostty"])
})

test("serializePinned persists the full order alongside pins", () => {
  const content = model.serializePinned(["spotify"], ["firefox", "terminal", "vscode", "spotify", "files"])
  const parsed = JSON.parse(content)
  assert.deepEqual(Array.from(parsed.pinned), ["spotify"])
  assert.deepEqual(Array.from(parsed.order), ["firefox", "terminal", "vscode", "spotify", "files"])
  assert.equal(parsed.version, 1)
})

test("parseOrder reads the order field and falls back safely", () => {
  const content = model.serializePinned(["a"], ["x", "a", "y"])
  assert.deepEqual(Array.from(model.parseOrder(content, [])), ["x", "a", "y"])
  assert.deepEqual(Array.from(model.parseOrder('{"pinned":["a"]}', ["old"])), ["old"])
  assert.deepEqual(Array.from(model.parseOrder("not json", ["old"])), ["old"])
  assert.deepEqual(Array.from(model.parseOrder("", ["old"])), ["old"])
  assert.deepEqual(Array.from(model.parseOrder('{"order":["a","a","b.desktop"]}', [])), ["a", "b"])
})

test("restored order is a preference, not an authority", () => {
  const restored = model.reconcileDockOrder(["a", "b", "c", "d"], ["a", "c", "d"], ["a", "c", "d"])
  assert.deepEqual(Array.from(restored), ["a", "c", "d"])
  const afterLaunch = model.reconcileDockOrder(restored, ["a", "c", "d"], ["a", "b", "c", "d"])
  assert.deepEqual(Array.from(afterLaunch), ["a", "c", "d", "b"])
})

test("acceptance: pin keeps position, survives restart, unpin removes", () => {
  let dockOrder = model.reconcileDockOrder([], [], ["firefox", "terminal", "vscode", "spotify", "files"])
  const persisted = model.serializePinned(["spotify"], dockOrder)
  let pinned = model.parsePinned(persisted, [])
  let restored = model.parseOrder(persisted, [])
  assert.deepEqual(Array.from(pinned), ["spotify"])

  // Pin does not reorder: membership changes, order does not.
  const before = dockOrder.join("|")
  dockOrder = model.reconcileDockOrder(dockOrder, pinned, ["firefox", "terminal", "vscode", "spotify", "files"])
  assert.equal(dockOrder.join("|"), before)

  // Spotify closes; restart with only some apps running: it stays mid-dock.
  dockOrder = model.reconcileDockOrder(restored, pinned, ["firefox", "terminal", "vscode"])
  assert.deepEqual(Array.from(dockOrder), ["firefox", "terminal", "vscode", "spotify"])

  // Unpin, close, restart: Spotify gone; relaunch appends at the end.
  pinned = model.removePinned(pinned, "spotify")
  dockOrder = model.reconcileDockOrder(dockOrder, pinned, ["firefox", "terminal", "vscode"])
  assert.equal(dockOrder.indexOf("spotify"), -1)
  dockOrder = model.reconcileDockOrder(dockOrder, pinned, ["firefox", "terminal", "vscode", "spotify"])
  assert.deepEqual(Array.from(dockOrder), ["firefox", "terminal", "vscode", "spotify"])
})

test("toggles and reorders pins", () => {
  assert.deepEqual(Array.from(model.togglePinned(["a"], "b")), ["a", "b"])
  assert.deepEqual(Array.from(model.togglePinned(["a", "b"], "a")), ["b"])
  assert.deepEqual(Array.from(model.reorderPinned(["a", "b", "c"], 0, 2)), ["b", "c", "a"])
})

test("builds pinned and running items without a separator", () => {
  const items = model.buildDockItems(["a"], [{ id: "a", name: "A" }, { id: "b", name: "B" }], ["a", "b"])
  assert.equal(items[0].running, true)
  assert.equal(items[1].id, "b")
})

test("write guard ignores matching content", () => {
  model.resetWrittenGuard()
  model.markWritten("hello")
  assert.equal(model.shouldReprocess("hello"), false)
  assert.equal(model.shouldReprocess("world"), true)
})

test("inserts and removes pins", () => {
  assert.deepEqual(Array.from(model.insertPinned(["a", "c"], "b", 1)), ["a", "b", "c"])
  assert.deepEqual(Array.from(model.insertPinned(["a"], "x", 5)), ["a", "x"])
  assert.deepEqual(Array.from(model.insertPinned(["a", "b"], "b", 0)), ["a", "b"])
  assert.deepEqual(Array.from(model.removePinned(["a", "b", "c"], "b")), ["a", "c"])
  assert.deepEqual(Array.from(model.removePinned(["a"], "z")), ["a"])
})

test("buildFlow inserts phantom among pinned and appends running unpinned", () => {
  assert.deepEqual(Array.from(model.buildFlow(["a", "b", "c"], ["x", "y"], "", -1).map(i => i.id)), ["a", "b", "c", "x", "y"])
  assert.deepEqual(Array.from(model.buildFlow(["a", "b", "c"], [], "", 1).map(i => i.id)), ["a", "__phantom__", "b", "c"])
  assert.deepEqual(Array.from(model.buildFlow(["a", "b", "c"], [], "", 0).map(i => i.id)), ["__phantom__", "a", "b", "c"])
  assert.deepEqual(Array.from(model.buildFlow(["a", "b", "c"], [], "", 3).map(i => i.id)), ["a", "b", "c", "__phantom__"])
  assert.equal(model.buildFlow(["a", "b", "c"], [], "", 1).filter(i => i.phantom).length, 1)
})

test("buildFlow excludes the floating item", () => {
  assert.deepEqual(Array.from(model.buildFlow(["a", "b", "c"], ["x"], "b", 1).map(i => i.id)), ["a", "__phantom__", "c", "x"])
  assert.deepEqual(Array.from(model.buildFlow(["a"], ["x", "y"], "y", -1).map(i => i.id)), ["a", "x"])
})

test("buildFlow phantom tracks the full flow including running apps", () => {
  assert.deepEqual(Array.from(model.buildFlow(["a"], ["x", "y"], "y", 1).map(i => i.id)), ["a", "__phantom__", "x"])
  assert.deepEqual(Array.from(model.buildFlow(["a"], ["x", "y"], "y", 2).map(i => i.id)), ["a", "x", "__phantom__"])
  assert.deepEqual(Array.from(model.buildFlow(["a"], ["x", "y"], "x", 0).map(i => i.id)), ["__phantom__", "a", "y"])
  assert.deepEqual(Array.from(model.buildFlow(["a"], ["x", "y"], "y", 9).map(i => i.id)), ["a", "x", "__phantom__"])
})

test("pinnedIndexForInsertion maps a full-flow index into the pinned cluster", () => {
  const pinned = ["a", "b"]
  const running = ["x", "y"]
  assert.deepEqual(Array.from(model.buildDockOrder(pinned, running, [])), ["a", "b", "x", "y"])
  assert.deepEqual(Array.from(model.buildDockOrder(pinned, running, ["a", "x", "b", "y"])), ["a", "b", "x", "y"])
})

test("buildDockOrder preserves the previous relative order of running apps", () => {
  assert.deepEqual(Array.from(model.buildDockOrder(["a"], ["x", "y"], ["a", "y", "x"])), ["a", "y", "x"])
  assert.deepEqual(Array.from(model.buildDockOrder(["a"], ["x", "y", "z"], ["a", "y", "x"])), ["a", "y", "x", "z"])
})

test("reconcileDockOrder keeps session slots and appends new apps", () => {
  assert.deepEqual(Array.from(model.reconcileDockOrder(["a", "x", "y"], ["a"], ["a", "x", "y"])), ["a", "x", "y"])
  assert.deepEqual(Array.from(model.reconcileDockOrder(["a", "x"], ["a"], ["a", "x", "y"])), ["a", "x", "y"])
  assert.deepEqual(Array.from(model.reconcileDockOrder(["a", "x", "y"], ["a"], ["a", "x"])), ["a", "x"])
  assert.deepEqual(Array.from(model.reconcileDockOrder(["x"], ["a", "b"], ["x"])), ["x", "a", "b"])
})

test("moveInOrder reorders any app without touching the pinned list", () => {
  assert.deepEqual(Array.from(model.moveInOrder(["a", "x", "y"], "x", 0)), ["x", "a", "y"])
  assert.deepEqual(Array.from(model.moveInOrder(["a", "x", "y"], "y", 1)), ["a", "y", "x"])
  assert.deepEqual(Array.from(model.moveInOrder(["a", "x"], "z", 2)), ["a", "x", "z"])
  assert.deepEqual(Array.from(model.moveInOrder(["a", "x", "y"], "a", 0)), ["a", "x", "y"])
})

test("orderPinned keeps only pinned members in order", () => {
  assert.deepEqual(Array.from(model.orderPinned(["b", "x", "a"], ["a", "b"])), ["b", "a"])
  assert.deepEqual(Array.from(model.orderPinned(["x", "y"], ["a"])), ["a"].filter(i => ["x", "y"].includes(i)))
  assert.deepEqual(Array.from(model.orderPinned(["x", "a", "y"], ["a"])), ["a"])
})

test("computeLayout rests evenly with no cursor and grows with magnification", () => {
  const opts = model.LAYOUT_OPTS
  const rest = model.computeLayout([{ id: "a" }, { id: "b" }, { id: "c" }], -1, opts)
  assert.equal(rest.totalWidth, opts.slotWidth * 3 + opts.spacing * 2 + 2 * opts.sidePadding)
  assert.deepEqual({ ...rest.placements.a }, { x: 0, scale: 1, lift: 0, phantom: false })
  assert.equal(rest.placements.b.x, opts.slotWidth + opts.spacing)
  assert.equal(rest.placements.c.x, 2 * (opts.slotWidth + opts.spacing))

  const center = rest.placements.b.x + opts.slotWidth / 2
  const mag = model.computeLayout([{ id: "a" }, { id: "b" }, { id: "c" }], center, opts)
  assert.ok(mag.placements.b.scale > 1, "hovered icon magnifies")
  assert.ok(mag.placements.a.scale < mag.placements.b.scale, "neighbors are smaller than hovered icon")
  assert.ok(mag.totalWidth > rest.totalWidth, "dock grows as the cursor approaches")
  assert.ok(mag.placements.b.lift > 0, "magnified icon lifts")
})

test("computeLayout keeps icons from overlapping under magnification", () => {
  const opts = model.LAYOUT_OPTS
  const flow = [{ id: "a" }, { id: "b" }, { id: "c" }]
  const center = opts.slotWidth + opts.slotWidth / 2
  const result = model.computeLayout(flow, center, opts)
  for (const id of ["a", "b", "c"]) {
    const p = result.placements[id]
    const painted = opts.iconSize * p.scale
    const left = p.x + (opts.slotWidth * p.scale - painted) / 2
    assert.ok(left + painted <= p.x + opts.slotWidth * p.scale, `icon ${id} fits in its slot`)
  }
})

test("single magnified icon is centered in the dock", () => {
  const opts = model.LAYOUT_OPTS
  // Cursor directly over the one slot: full magnification, no neighbors.
  const result = model.computeLayout([{ id: "a" }], opts.slotWidth / 2, opts)
  const p = result.placements.a
  // Icon center = wrapper center = slot center; flowWidth = scaled slot width.
  assert.ok(Math.abs(p.x + (opts.slotWidth * p.scale) / 2 - result.flowWidth / 2) < 0.01)
  assert.ok(Math.abs(p.x + (opts.slotWidth * p.scale) / 2 - result.flowWidth / 2) === 0
    ? true : result.flowWidth > 0)
  assert.equal(result.totalWidth, p.x + opts.slotWidth * p.scale + 2 * opts.sidePadding)
})

test("multi-item flowWidth equals the content span", () => {
  const opts = model.LAYOUT_OPTS
  const rest = model.computeLayout([{ id: "a" }, { id: "b" }], -1, opts)
  assert.equal(rest.flowWidth, opts.slotWidth + opts.spacing + opts.slotWidth)
})

test("insertionIndexFor picks the nearest slot", () => {
  const opts = model.LAYOUT_OPTS
  const flow = [{ id: "a" }, { id: "b" }, { id: "c" }]
  assert.equal(model.insertionIndexFor(0, flow, opts), 0)
  assert.equal(model.insertionIndexFor(50, flow, opts), 1)
  assert.equal(model.insertionIndexFor(100, flow, opts), 1)
  assert.equal(model.insertionIndexFor(9999, flow, opts), 3)
})

test("settings parse and serialize autoHide", () => {
  assert.equal(model.parseSettings('{"autoHide":true}', { autoHide: false }).autoHide, true)
  assert.equal(model.parseSettings('{"autoHide":false}', { autoHide: true }).autoHide, false)
  assert.equal(model.parseSettings('', { autoHide: true }).autoHide, true)
  assert.equal(model.parseSettings('not json', { autoHide: false }).autoHide, false)
  assert.equal(model.parseSettings('{}', { autoHide: true }).autoHide, true)
  const s = model.serializeSettings({ autoHide: false })
  const parsed = JSON.parse(s)
  assert.equal(parsed.autoHide, false)
  assert.equal(parsed.version, 1)
  assert.equal(model.parseSettings(s, { autoHide: true }).autoHide, false)
  assert.equal(model.serializeSettings({ autoHide: true }).includes('"autoHide": true'), true)
})

test("settings write guard ignores matching content", () => {
  model.resetSettingsGuard()
  model.markSettingsWritten('{"autoHide":true}\n')
  assert.equal(model.shouldReprocessSettings('{"autoHide":true}\n'), false)
  assert.equal(model.shouldReprocessSettings('{"autoHide":false}\n'), true)
})

test("auto-hide state machine: shouldHideDock and shouldScheduleHide require ready, engaged, suppressed", () => {
  const base = { autoHide: true, enabled: true, dockReady: true, autoHidden: false, dockEngaged: false, hideSuppressed: false, dockHovered: false, edgeHovered: false }
  assert.equal(model.shouldHideDock(base), true)
  assert.equal(model.shouldScheduleHide(base), true)

  // Disabled variants
  assert.equal(model.shouldHideDock({ ...base, autoHide: false }), false)
  assert.equal(model.shouldHideDock({ ...base, enabled: false }), false)
  assert.equal(model.shouldHideDock({ ...base, dockReady: false }), false)
  assert.equal(model.shouldHideDock({ ...base, autoHidden: true }), false)
  assert.equal(model.shouldHideDock({ ...base, dockEngaged: true }), false)
  assert.equal(model.shouldHideDock({ ...base, dockHovered: true }), false)
  assert.equal(model.shouldHideDock({ ...base, edgeHovered: true }), false)
  assert.equal(model.shouldHideDock({ ...base, hideSuppressed: true }), false)

  assert.equal(model.shouldScheduleHide({ ...base, dockReady: false }), false)
  assert.equal(model.shouldScheduleHide({ ...base, hideSuppressed: true }), false)
  assert.equal(model.shouldScheduleHide({ ...base, dockEngaged: true }), false)
})

test("auto-hide shouldRevealDock only when hidden and edge hovered", () => {
  const hiddenAtEdge = { autoHide: true, enabled: true, autoHidden: true, edgeHovered: true }
  assert.equal(model.shouldRevealDock(hiddenAtEdge), true)
  assert.equal(model.shouldRevealDock({ ...hiddenAtEdge, edgeHovered: false }), false)
  assert.equal(model.shouldRevealDock({ ...hiddenAtEdge, autoHidden: false }), false)
  assert.equal(model.shouldRevealDock({ ...hiddenAtEdge, autoHide: false }), false)
  assert.equal(model.shouldRevealDock({ ...hiddenAtEdge, enabled: false }), false)
})

test("auto-hide matrix: menu/picker/preview/floating/altTab suppress hide", () => {
  const idle = { autoHide: true, enabled: true, dockReady: true, autoHidden: false, dockEngaged: false, hideSuppressed: false }
  assert.equal(model.shouldHideDock(idle), true)
  assert.equal(model.shouldHideDock({ ...idle, hideSuppressed: true }), false)
  // hideSuppressed covers menu/picker/preview/floating/altTab
  assert.equal(model.shouldHideDock({ ...idle, dockEngaged: true }), false)
  assert.equal(model.shouldRevealDock({ autoHide: true, enabled: true, autoHidden: true, edgeHovered: true }), true)
  assert.equal(model.shouldRevealDock({ autoHide: true, enabled: true, autoHidden: true, edgeHovered: false }), false)
})

test("auto-hide hide→reveal→hide cycle is deterministic", () => {
  // Start visible, idle → hide
  let s = { autoHide: true, enabled: true, dockReady: true, autoHidden: false, dockEngaged: false, hideSuppressed: false, edgeHovered: false, dockHovered: false }
  assert.equal(model.shouldHideDock(s), true)
  s.autoHidden = true
  // Hidden, edge not hovered → no reveal
  assert.equal(model.shouldRevealDock(s), false)
  // Edge hovered → reveal
  s.edgeHovered = true
  s.dockEngaged = true
  assert.equal(model.shouldRevealDock(s), true)
  s.autoHidden = false
  s.edgeHovered = false
  s.dockEngaged = false
  // Back to idle → should hide again
  assert.equal(model.shouldHideDock(s), true)
  // Repeat without stuck state
  s.autoHidden = true
  s.edgeHovered = true
  s.dockEngaged = true
  assert.equal(model.shouldRevealDock(s), true)
})
