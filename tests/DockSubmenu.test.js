const test = require("node:test")
// Plain (loose) assert on purpose: values compared across the generated
// module boundary should match structurally, not by prototype identity.
const assert = require("node:assert")
const fs = require("node:fs")

// Loads a .pragma-library QML JS file for testing: strips the QML pragma
// and appends a CommonJS export of the same names Quickshell exposes
// through the library import, then requires the generated copy from inside
// the project. Two vm-free choices on purpose:
//   - require() gives correct line attribution; V8 coverage of vm scripts
//     never attributes a script's final statements, which makes 100% line
//     thresholds impossible to satisfy honestly.
//   - the generated file must live under the project root, or the test
//     runner's coverage include filter ignores it entirely.
function load(relPath) {
  const path = require("node:path")
  const abs = path.resolve(relPath)
  const source = fs.readFileSync(abs, "utf8")
    .replace(/^\.pragma library\s*/, "")
    .trimEnd() + "\nmodule.exports = { create, entered, exited, graceElapsed, menuClosed }\n"
  const genDir = path.join(__dirname, ".generated")
  fs.mkdirSync(genDir, { recursive: true })
  const genPath = path.join(genDir, relPath.replace(/\.js$/, ".cjs"))
  fs.writeFileSync(genPath, source)
  delete require.cache[genPath]
  return require(genPath)
}

const submenu = load("DockSubmenu.js")

test("entering the row opens the flyout and stops any pending close", () => {
  const state = submenu.create()
  assert.deepEqual(submenu.entered(state, "row"), { open: true, stopGrace: true })
})

test("entering a flyout source holds the flyout without opening it", () => {
  const state = submenu.create()
  assert.deepEqual(submenu.entered(state, "padding"), { open: false, stopGrace: true })
  assert.deepEqual(submenu.entered(state, "keep"), { open: false, stopGrace: true })
})

test("leaving one source while another is active never arms the close timer", () => {
  const state = submenu.create()
  submenu.entered(state, "row")
  submenu.entered(state, "padding")
  assert.deepEqual(submenu.exited(state, "row"), { startGrace: false })
})

test("leaving the last source arms the close timer", () => {
  const state = submenu.create()
  submenu.entered(state, "row")
  assert.deepEqual(submenu.exited(state, "row"), { startGrace: true })
})

test("grace elapse closes the flyout when nothing re-entered", () => {
  const state = submenu.create()
  submenu.entered(state, "row")
  submenu.exited(state, "row")
  assert.deepEqual(submenu.graceElapsed(state), { close: true })
})

test("grace elapse holds the flyout when something re-entered during the wait", () => {
  const state = submenu.create()
  submenu.entered(state, "row")
  submenu.exited(state, "row")
  submenu.entered(state, "padding")
  assert.deepEqual(submenu.graceElapsed(state), { close: false })
})

test("menuClosed forgets all hover state so the next open starts clean", () => {
  const state = submenu.create()
  submenu.entered(state, "row")
  submenu.entered(state, "padding")
  submenu.menuClosed(state)
  assert.deepEqual(submenu.graceElapsed(state), { close: true })
})

test("re-entering the same source is idempotent", () => {
  const state = submenu.create()
  submenu.entered(state, "row")
  submenu.entered(state, "row")
  assert.deepEqual(submenu.exited(state, "row"), { startGrace: true })
})

test("exposes the five state machine functions, as Quickshell's import does", () => {
  for (const name of ["create", "entered", "exited", "graceElapsed", "menuClosed"]) {
    assert.equal(typeof submenu[name], "function", name + " should be callable")
  }
})
