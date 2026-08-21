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

const search = loadQmlJs("IconSearch.js")

test("builds the macOSicons search request", () => {
  const request = search.buildSearchRequest("figma")
  assert.equal(request.url, "https://macosicons.com/api/search")
  const body = JSON.parse(request.body)
  assert.equal(body.query, "figma")
  assert.equal(body.searchOptions.hitsPerPage, 24)
  assert.deepEqual(body.searchOptions.sort, ["downloads:desc"])
})

test("parses helper search output into display items", () => {
  const items = search.parseResponse(JSON.stringify([
    { appName: "Figma", appSlug: "figma", objectID: "i3FsrkYvf6",
      iOSUrl: "https://s3-new.macosicons.com/parse/Figma.png",
      lowResPngUrl: "https://s3-new.macosicons.com/parse/low_res_Figma.png", downloads: 18 },
    { appName: "No Image", appSlug: "x", objectID: "y", downloads: 1 }
  ]))
  assert.equal(items.length, 1)
  assert.equal(items[0].appName, "Figma")
  assert.equal(items[0].objectID, "i3FsrkYvf6")
  assert.equal(items[0].downloads, 18)
  assert.equal(items[0].iOSUrl, "https://s3-new.macosicons.com/parse/Figma.png")
})

test("degrades gracefully on bad input", () => {
  assert.equal(search.parseResponse("").length, 0)
  assert.equal(search.parseResponse("not json").length, 0)
  assert.equal(search.parseResponse("[1,2]").length, 0)
  assert.equal(search.parseResponse("{}").length, 0)
  assert.equal(search.parseResponse("null").length, 0)
})

test("builds the icon page URL from a result", () => {
  assert.equal(search.pageUrl({ appName: "VS Code", objectID: "abc123" }), "https://macosicons.com/icon/vs-code-abc123")
  assert.equal(search.pageUrl({ appName: "Figma", objectID: "i3FsrkYvf6" }), "https://macosicons.com/icon/figma-i3FsrkYvf6")
  assert.equal(search.pageUrl({}), "")
  assert.equal(search.pageUrl(null), "")
})

test("converts file dialog URLs to paths", () => {
  assert.equal(search.fileUrlToPath("file:///home/user/my%20icon.png"), "/home/user/my icon.png")
  assert.equal(search.fileUrlToPath("file:///home/user/plain.png"), "/home/user/plain.png")
  assert.equal(search.fileUrlToPath("/plain/path.png"), "/plain/path.png")
})