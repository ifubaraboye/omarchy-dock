import QtQuick
import Quickshell.Io
import qs.Commons

// Translation access with a fallback for shells that predate
// qs.Commons.Translations. Omarchy 4.5+ gets the shell component, which follows
// the configured language. Older shells read the bundled i18n/en.json
// synchronously (blockLoading) so the first t() call already has text instead
// of returning a raw key.
Item {
  id: root
  property var shellStrings: null

  readonly property string catalogPath: decodeURIComponent(
    String(Qt.resolvedUrl("i18n/en.json")).replace(/^file:\/\//, ""))

  readonly property var table: {
    try {
      var parsed = JSON.parse(englishFile.text() || "{}")
      return (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : ({})
    } catch (error) {
      return ({})
    }
  }

  Component.onCompleted: {
    try {
      var directory = String(Qt.resolvedUrl("i18n"))
      var code = 'import qs.Commons; Commons.Translations { directory: '
        + JSON.stringify(directory) + ' }'
      root.shellStrings = Qt.createQmlObject(code, root, "shellStrings")
    } catch (error) {
      root.shellStrings = null
    }
  }

  function t(key, fallback) {
    if (root.shellStrings) return root.shellStrings.t(key, fallback)
    var value = root.table[String(key)]
    if (typeof value === "string" && value.length > 0) return value
    return fallback !== undefined ? fallback : String(key)
  }

  function tn(key, count, fallback) {
    if (root.shellStrings) return root.shellStrings.tn(key, count, fallback)
    var value = root.table[String(key)]
    if (value && typeof value === "object") {
      var form = Number(count) === 1 ? value.one : value.other
      if (typeof form === "string" && form.length > 0) return form
    }
    return root.t(key, fallback)
  }

  // Locale-aware helpers, kept here so callers never touch a 4.5-only API
  // directly. Older shells fall back to plain decimal text and the Qt layout
  // direction.
  function formatNumber(value) {
    try {
      if (typeof Commons !== "undefined" && Commons.I18n
          && typeof Commons.I18n.formatNumber === "function")
        return Commons.I18n.formatNumber(value)
    } catch (error) {}
    return String(value)
  }

  function isRightToLeft() {
    try {
      if (typeof Commons !== "undefined" && Commons.I18n
          && typeof Commons.I18n.rightToLeft === "boolean")
        return Commons.I18n.rightToLeft
    } catch (error) {}
    return Qt.application.layoutDirection === Qt.RightToLeft
  }

  property FileView englishFile: FileView {
    path: root.catalogPath
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }
}
