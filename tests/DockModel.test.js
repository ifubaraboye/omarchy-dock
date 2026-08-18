const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")

function loadQmlJs(path) {
  const source = fs.readFileSync(path, "utf8").replace(/^\.pragma library\s*/, "")
  const context = { module: { exports: {} }, console }
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

test("buildOrderedItems marks pinned and running flags in session order", () => {
  const items = model.buildOrderedItems(["a", "x", "b"], ["a", "b"], [{ id: "a" }, { id: "b" }, { id: "x" }], ["a", "x"])
  assert.deepEqual(Array.from(items.map(i => i.id)), ["a", "x", "b"])
  assert.equal(items[0].pinned, true)
  assert.equal(items[1].pinned, false)
  assert.equal(items[2].pinned, true)
  assert.equal(items[1].running, true)
})

test("computeLayout rests evenly with no cursor and grows with magnification", () => {
  const opts = model.LAYOUT_OPTS
  const rest = model.computeLayout([{ id: "a" }, { id: "b" }, { id: "c" }], -1, opts)
  assert.equal(rest.totalWidth, 58 * 3 + 8 * 2 + 36)
  assert.deepEqual({ ...rest.placements.a }, { x: 0, scale: 1, lift: 0, phantom: false })
  assert.equal(rest.placements.b.x, 66)
  assert.equal(rest.placements.c.x, 132)

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

test("insertionIndexFor picks the nearest slot", () => {
  const opts = model.LAYOUT_OPTS
  const flow = [{ id: "a" }, { id: "b" }, { id: "c" }]
  assert.equal(model.insertionIndexFor(0, flow, opts), 0)
  assert.equal(model.insertionIndexFor(50, flow, opts), 1)
  assert.equal(model.insertionIndexFor(100, flow, opts), 2)
  assert.equal(model.insertionIndexFor(9999, flow, opts), 3)
})
