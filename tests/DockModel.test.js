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
