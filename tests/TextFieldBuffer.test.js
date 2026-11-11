const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

function loadQmlJs(relativePath) {
  const source = fs.readFileSync(path.join(__dirname, "..", relativePath), "utf8").replace(/^\.pragma library\s*/, "")
  const context = { module: { exports: {} } }
  vm.runInNewContext(source, context, { filename: relativePath })
  return context.module.exports
}

const Buffer = loadQmlJs("TextFieldBuffer.js")

test("inserts typed text at the caret and advances it", () => {
  const result = Buffer.insert("figm", 4, "a", 64)
  assert.equal(result.text, "figma")
  assert.equal(result.cursor, 5)
})

test("inserts in the middle of existing text", () => {
  const result = Buffer.insert("fma", 1, "ig", 64)
  assert.equal(result.text, "figma")
  assert.equal(result.cursor, 3)
})

test("clamps insertion to maximumLength", () => {
  const result = Buffer.insert("abc", 3, "def", 4)
  assert.equal(result.text, "abcd")
  assert.equal(result.cursor, 4)
})

test("refuses further input once the limit is reached", () => {
  const result = Buffer.insert("abcd", 4, "e", 4)
  assert.equal(result.text, "abcd")
  assert.equal(result.cursor, 4)
})

test("normalizes clipboard control characters and line breaks to one line", () => {
  const result = Buffer.insert("", 0, "https://example.com/a.png\n\tsecond", 256)
  assert.equal(result.text, "https://example.com/a.png second")
  assert.ok(!result.text.includes("\n"))
})

test("strips bidi overrides so a paste cannot reorder the visible field", () => {
  const result = Buffer.insert("", 0, "\u202Eevil\u202C", 64)
  assert.equal(result.text, " evil ")
})

function expect(result, text, cursor) {
  assert.equal(result.text, text)
  assert.equal(result.cursor, cursor)
}

test("backspace removes the character before the caret only", () => {
  expect(Buffer.backspace("figma", 3), "fima", 2)
  expect(Buffer.backspace("figma", 0), "figma", 0)
})

test("forward delete removes the character under the caret", () => {
  expect(Buffer.removeForward("figma", 2), "fima", 2)
  expect(Buffer.removeForward("figma", 5), "figma", 5)
})

test("cursor movement stays inside the text", () => {
  assert.equal(Buffer.moveLeft("abc", 0), 0)
  assert.equal(Buffer.moveRight("abc", 3), 3)
  assert.equal(Buffer.moveRight("abc", 0), 1)
  assert.equal(Buffer.home("abc", 3), 0)
  assert.equal(Buffer.end("abc"), 3)
})

test("setText and clear place the caret predictably", () => {
  expect(Buffer.setText("Figma"), "Figma", 5)
  expect(Buffer.clear(), "", 0)
})

test("a huge paste is bounded by maximumLength", () => {
  const result = Buffer.insert("", 0, "x".repeat(100000), 16)
  assert.equal(result.text.length, 16)
  assert.equal(result.cursor, 16)
})
