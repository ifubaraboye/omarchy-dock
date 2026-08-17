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

test("resolves explicit and fallback icons", () => {
  assert.equal(resolver.resolveIcon({ icon: "mail" }), "mail")
  assert.equal(resolver.resolveIcon({ id: "code.desktop" }), "vscode")
  assert.equal(resolver.resolveIcon({ id: "WhatsApp" }), "WhatsApp")
  assert.equal(resolver.resolveIcon({ id: "unknown" }), "application-x-executable")
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
