const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")

function loadQmlJs(path) {
  const source = fs.readFileSync(path, "utf8").replace(/^\.pragma library\s*/, "")
  const context = { module: { exports: {} } }
  vm.runInNewContext(source, context, { filename: path })
  return context.module.exports
}

const resolver = loadQmlJs("IconResolver.js")

test("bundled neutral fallback asset is present", () => {
  assert.equal(resolver.DEFAULT_ICON_ASSET, "default-app.svg")
  assert.equal(fs.existsSync(`assets/${resolver.DEFAULT_ICON_ASSET}`), true)
})

test("resolves explicit and fallback icons", () => {
  assert.equal(resolver.resolveIcon({ icon: "mail" }), "mail")
  assert.equal(resolver.resolveIcon({ id: "code.desktop" }), "vscode")
  assert.equal(resolver.resolveIcon({ id: "WhatsApp" }), "WhatsApp")
  assert.equal(resolver.resolveIcon({ id: "unknown" }), "application-x-executable")
})

test("an unmatched entry's own generic placeholder does not block the id-based fallback", () => {
  // DockModelBase.entryFor()'s own default for an id with no matching desktop
  // entry sets icon to this exact literal -- trusting it as a "real" icon
  // short-circuited the FALLBACK_MAP lookup below for every one of those
  // entries, which is exactly the case FALLBACK_MAP exists to handle.
  assert.equal(
    resolver.resolveIcon({ id: "tui.tile", icon: "application-x-executable" }),
    "kitty"
  )
  // An id with no FALLBACK_MAP entry still degrades to the placeholder --
  // this is "no real icon found", not a regression.
  assert.equal(
    resolver.resolveIcon({ id: "unknown", icon: "application-x-executable" }),
    "application-x-executable"
  )
})

test("terminal multiplexers sharing kitty's generic --class get kitty's icon", () => {
  // Herdr (and any other tool invoking `kitty --class TUI.tile`) launches
  // every pane under one class shared by whatever app runs inside it, so it
  // never matches a specific .desktop entry. The class is kitty-specific by
  // construction, so kitty's own icon is accurate here, not a guess.
  assert.equal(resolver.resolveIcon({ id: "TUI.tile" }), "kitty")
  assert.equal(resolver.resolveIcon({ id: "tui.tile" }), "kitty")
})

test("sanitizes desktop names", () => {
  assert.equal(resolver.sanitizeName("my-app.desktop"), "my app")
})

test("resolves safe custom icon filenames", () => {
  const icons = {
    code: { file: "code.png" },
    whatsapp: "whatsapp.webp",
    bad: { file: "../outside.png" }
  }
  assert.equal(resolver.customIconFile(icons, "code.desktop"), "code.png")
  assert.equal(resolver.customIconFile(icons, "whatsapp"), "whatsapp.webp")
  assert.equal(resolver.customIconFile(icons, "WhatsApp"), "whatsapp.webp")
  assert.equal(resolver.customIconFile(icons, "chrome-web.whatsapp.com__-Default"), "whatsapp.webp")
  assert.equal(resolver.customIconFile(icons, "bad"), "")
})
