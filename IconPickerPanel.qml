import QtQuick
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "IconResolver.js" as IconResolver
import "IconSearch.js" as IconSearch

// macOS "Get Info"-style icon picker. Two views share one glass surface:
//  - picker: change the icon of one app (macOSicons search, own image, URL)
//  - manage: browse every installed app and open the picker for any of them,
//    docked or not. Custom icons are keyed by app id, so an app that is not
//    on the dock shows its assigned icon the moment it appears.
//
// All downloads, normalization and persistence happen in the omarchy-dock-icon
// helper through Quickshell Processes; the dock's dock-icons.json watcher
// hot-reloads changes, so the dock updates without a restart.
PanelWindow {
  id: root

  property bool open: false
  property string mode: "picker" // "picker" | "manage"
  property string currentAppId: ""
  property string currentAppName: ""
  property bool fromManage: false
  property var customIcons: ({})
  property var iconSourceFor: function(id) { return "" }
  property string helperPath: ""
  property var shell: null

  property var results: []
  property var appRows: []
  property bool busy: false
  property string statusText: ""
  // Bumped after every successful apply/clear and when the icon mapping is
  // reloaded, forcing preview/row bindings (which cannot track property reads
  // inside the iconSourceFor function) to re-evaluate.
  property int appliedRevision: 0
  property bool pasteVisible: false
  property int gridCell: 112

  function appHasCustomIcon(id) {
    return IconResolver.customIconFile(root.customIcons, id) !== ""
  }

  function previewSource(id) {
    var source = root.iconSourceFor(id)
    if (!source) return ""
    return String(source) + "?v=" + root.appliedRevision
  }

  function openForApp(appId, appName, fromManage) {
    root.currentAppId = String(appId || "")
    root.currentAppName = String(appName || IconResolver.sanitizeName(root.currentAppId))
    root.fromManage = !!fromManage
    root.mode = "picker"
    root.pasteVisible = false
    root.statusText = ""
    root.open = true
    root.appliedRevision++
    Qt.callLater(function() { searchField.forceActiveFocus() })
    root.prefillSearch()
  }

  function openManage() {
    root.mode = "manage"
    root.statusText = ""
    root.open = true
    root.appliedRevision++
    root.reloadApps()
    Qt.callLater(function() { appsField.forceActiveFocus() })
  }

  function close() {
    root.open = false
    root.results = []
    root.appRows = []
    root.statusText = ""
    root.busy = false
  }

  // Seed the grid with the app's own name so users rarely have to type.
  function prefillSearch() {
    searchField.text = ""
    var query = IconResolver.sanitizeName(root.currentAppName).toLowerCase()
    if (!query) return
    root.searching(query)
  }

  function searching(query) {
    searchTimer.stop()
    if (!String(query).trim()) {
      root.results = []
      root.statusText = ""
      return
    }
    root.searchingNow(query)
  }

  function searchingNow(query) {
    if (!root.helperPath) {
      root.statusText = "Icon helper not found — reinstall the plugin"
      return
    }
    root.statusText = "Searching macOSicons"
    searchProcess.command = [root.helperPath, "search", String(query).trim()]
    searchProcess.running = true
  }

  function applyResult(item) {
    if (!item || !item.iOSUrl) return
    root.applyWith([root.helperPath, "set", root.currentAppId, item.iOSUrl], "Icon updated")
  }

  function applyLocalFile(path) {
    if (!String(path).trim()) return
    root.applyWith([root.helperPath, "set", root.currentAppId, "--file", path], "Icon updated")
  }

  function applyPastedUrl() {
    var url = String(pasteField.text).trim()
    if (!/^https?:\/\//.test(url)) {
      root.statusText = "Enter a full http(s) image URL"
      return
    }
    root.applyWith([root.helperPath, "set", root.currentAppId, url], "Icon updated")
  }

  function clearIcon(appId) {
    root.applyWith([root.helperPath, "clear", appId], "Custom icon cleared")
  }

  function applyWith(command, successMessage) {
    if (root.busy || !root.helperPath) {
      if (!root.helperPath) root.statusText = "Icon helper not found — reinstall the plugin"
      return
    }
    root.busy = true
    root.statusText = "Applying"
    applyProcess.pendingSuccess = successMessage
    applyProcess.command = command
    applyProcess.running = true
  }

  function reloadApps() {
    if (!root.shell || !root.shell.appLibrary) {
      root.appRows = []
      return
    }
    try {
      var rows = root.shell.appLibrary.sortedEntries(String(appsField.text).trim())
      var list = []
      for (var i = 0; i < rows.length && list.length < 400; i++) {
        var entry = rows[i] && rows[i].entry ? rows[i].entry : (rows[i] || {})
        var id = String(entry.id || "").replace(/\.desktop$/, "")
        if (!id) continue
        list.push({ id: id, name: entry.name || entry.displayName || id })
      }
      root.appRows = list
    } catch (error) {
      root.appRows = []
    }
  }

  function openAppPicker(row) {
    if (!row || !row.id) return
    root.openForApp(row.id, row.name, true)
  }

  visible: root.open
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "macos-dock-icon-picker"
  WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: dismissSurface }

  onCustomIconsChanged: root.appliedRevision++

  // Search debounce. The macOSicons API is polled on a short timer so typing
  // never fires a request per keystroke.
  Timer {
    id: searchTimer
    interval: 250
    onTriggered: root.searchingNow(String(searchField.text).trim())
  }

  Timer {
    id: appsTimer
    interval: 200
    onTriggered: root.reloadApps()
  }

  Process {
    id: searchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = IconSearch.parseResponse(text)
        root.results = parsed
        if (parsed.length > 0)
          root.statusText = parsed.length + " icons found"
        else
          root.statusText = "No matches — try another term"
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim() && root.results.length === 0)
          root.statusText = "Couldn't reach macOSicons — check your connection"
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.results.length === 0)
        root.statusText = "Couldn't reach macOSicons — check your connection"
    }
  }

  Process {
    id: applyProcess
    property string pendingSuccess: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim()) root.applyError = text.trim()
      }
    }
    onExited: function(exitCode) {
      var success = exitCode === 0
      root.busy = false
      if (success) {
        root.appliedRevision++
        root.statusText = applyProcess.pendingSuccess
      } else {
        root.statusText = "Failed — " + (root.applyError || "couldn't complete the change")
      }
      root.applyError = ""
    }
  }

  property string applyError: ""

  FileDialog {
    id: fileDialog
    title: "Choose an image for " + root.currentAppName
    nameFilters: ["Images (*.png *.webp)", "All files (*)"]
    onAccepted: root.applyLocalFile(IconSearch.fileUrlToPath(fileDialog.selectedFile))
  }

  Connections {
    target: root.shell && root.shell.appLibrary ? root.shell.appLibrary : null
    function onAppsChanged() { if (root.open && root.mode === "manage") root.reloadApps() }
  }

  // ---- Surface -------------------------------------------------------------

  Item {
    id: dismissSurface
    anchors.fill: parent
    z: -1

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: 760
    height: 540
    radius: 18
    color: Util.alpha(Color.background, 0.97)
    border.color: Util.alpha(Color.foreground, 0.18)
    border.width: 1

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: function(event) { root.close(); event.accepted = true }

      Column {
        anchors.fill: parent
        anchors.margins: 18
        spacing: 12

        // Header -------------------------------------------------------------
        Row {
          id: headerRow
          width: parent.width
          height: 50
          spacing: 12

          Rectangle {
            id: previewTile
            width: 48
            height: 48
            radius: 12
            color: Util.alpha(Color.foreground, 0.07)
            visible: root.mode === "picker"

            Image {
              id: previewImage
              anchors.centerIn: parent
              width: 40
              height: 40
              source: root.mode === "picker" ? root.previewSource(root.currentAppId) : ""
              sourceSize: Qt.size(80, 80)
              fillMode: Image.PreserveAspectFit
              cache: true

              Text {
                anchors.centerIn: parent
                visible: parent.status !== Image.Ready
                text: "◆"
                color: Color.foreground
                font.pixelSize: 18
              }
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (root.mode === "picker" ? previewTile.width + 12 : 0) - (root.mode === "picker" && root.fromManage ? backButton.width + 12 : 0) - closeButton.width - 12
            spacing: 2

            Text {
              width: parent.width
              text: root.mode === "picker" ? root.currentAppName : "Icon Manager"
              elide: Text.ElideRight
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              width: parent.width
              text: root.mode === "picker"
                ? "Change the icon shown for this app"
                : "Change icons for any installed app"
              elide: Text.ElideRight
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          Rectangle {
            id: backButton
            anchors.verticalCenter: parent.verticalCenter
            width: 74
            height: 30
            radius: 8
            color: backMouse.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent"
            visible: root.mode === "picker" && root.fromManage

            Text {
              anchors.centerIn: parent
              text: "‹ All apps"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: backMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: { root.mode = "manage"; root.statusText = ""; Qt.callLater(function() { appsField.forceActiveFocus() }) }
            }
          }

          Rectangle {
            id: closeButton
            anchors.verticalCenter: parent.verticalCenter
            width: 36
            height: 36
            radius: 10
            color: closeMouse.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "✕"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: 18
            }
            MouseArea {
              id: closeMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.close()
            }
          }
        }

        // Search row ---------------------------------------------------------
        Rectangle {
          id: searchRow
          width: parent.width
          height: 38
          radius: 10
          color: Util.alpha(Color.foreground, 0.06)
          border.color: Util.alpha(Color.foreground, 0.12)
          border.width: 1

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: root.mode === "picker" ? "🔍" : "🔎"
            color: Qt.darker(Color.foreground, 1.4)
            font.pixelSize: 14
          }

          TextField {
            id: searchField
            visible: root.mode === "picker"
            anchors.left: parent.left
            anchors.leftMargin: 34
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Search macOSicons"
            placeholderTextColor: Qt.darker(Color.foreground, 1.6)
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            background: Item {}
            onTextChanged: { root.pasteVisible = false; root.statusText = ""; searchTimer.restart() }
            Keys.onEscapePressed: function(event) { root.close(); event.accepted = true }
          }

          TextField {
            id: appsField
            visible: root.mode === "manage"
            anchors.left: parent.left
            anchors.leftMargin: 34
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Search installed apps"
            placeholderTextColor: Qt.darker(Color.foreground, 1.6)
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            background: Item {}
            onTextChanged: { root.statusText = ""; appsTimer.restart() }
            Keys.onEscapePressed: function(event) { root.close(); event.accepted = true }
          }
        }

        // Paste URL row ------------------------------------------------------
        Rectangle {
          width: parent.width
          height: 34
          radius: 10
          color: Util.alpha(Color.foreground, 0.05)
          visible: root.pasteVisible && root.mode === "picker"

          TextField {
            id: pasteField
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: pasteApply.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "https:// direct PNG or WebP image URL"
            placeholderTextColor: Qt.darker(Color.foreground, 1.6)
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            background: Item {}
            Keys.onEscapePressed: function(event) { root.pasteVisible = false; event.accepted = true }
          }

          Rectangle {
            id: pasteApply
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 64
            height: 26
            radius: 8
            color: pasteApplyMouse.containsMouse ? Util.alpha(Color.accent, 0.85) : Util.alpha(Color.accent, 0.7)
            Text {
              anchors.centerIn: parent
              text: "Apply"
              color: Color.background
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: pasteApplyMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.applyPastedUrl()
            }
          }
        }

        // Content ------------------------------------------------------------
        Rectangle {
          width: parent.width
          height: 314 - (root.pasteVisible ? 58 : 0)
          radius: 12
          clip: true
          color: "transparent"

          GridView {
            id: resultGrid
            visible: root.mode === "picker"
            anchors.fill: parent
            model: root.results
            cellWidth: root.gridCell
            cellHeight: root.gridCell
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              required property var modelData
              width: root.gridCell
              height: root.gridCell
              radius: 12
              color: gridMouse.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent"

              Column {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: 76
                  height: 76
                  radius: 16
                  color: Util.alpha(Color.foreground, 0.06)

                  Image {
                    anchors.centerIn: parent
                    width: 68
                    height: 68
                    source: modelData.lowResPngUrl
                    sourceSize: Qt.size(136, 136)
                    fillMode: Image.PreserveAspectFit
                    cache: true
                    asynchronous: true
                  }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: root.gridCell - 12
                  text: modelData.appName || "icon"
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                id: gridMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.applyResult(modelData)
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.results.length === 0 && root.statusText === ""
              text: "Type to search macOSicons"
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          ListView {
            id: appList
            visible: root.mode === "manage"
            anchors.fill: parent
            model: root.appRows
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: 4

            delegate: Rectangle {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: 52
              radius: 10
              color: rowMouse.containsMouse ? Util.alpha(Color.foreground, 0.08) : (index % 2 === 1 ? Util.alpha(Color.foreground, 0.03) : "transparent")

              Image {
                id: rowIcon
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 36
                height: 36
                source: root.previewSource(modelData.id)
                sourceSize: Qt.size(72, 72)
                fillMode: Image.PreserveAspectFit
                cache: true
                asynchronous: true
              }

              Text {
                anchors.left: rowIcon.right
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.name
                elide: Text.ElideRight
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Rectangle {
                  width: 70
                  height: 28
                  radius: 8
                  color: changeMouse.containsMouse ? Util.alpha(Color.foreground, 0.16) : Util.alpha(Color.foreground, 0.08)
                  Text {
                    anchors.centerIn: parent
                    text: "Change"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    id: changeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openAppPicker(modelData)
                  }
                }

                Rectangle {
                  width: 56
                  height: 28
                  radius: 8
                  color: clearMouse.containsMouse ? Util.alpha(Color.foreground, 0.16) : Util.alpha(Color.foreground, 0.08)
                  visible: root.appHasCustomIcon(modelData.id)
                  Text {
                    anchors.centerIn: parent
                    text: "Clear"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    id: clearMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearIcon(modelData.id)
                  }
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openAppPicker(modelData)
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.appRows.length === 0
              text: root.shell && root.shell.appLibrary ? "No apps match" : "App library unavailable"
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }
        }

        // Bottom actions ------------------------------------------------------
        Row {
          id: bottomRow
          width: parent.width
          height: 38
          spacing: 8
          visible: root.mode === "picker"

          ActionButton {
            text: "Use Your Own Image"
            width: 168
            onClicked: fileDialog.open()
          }
          ActionButton {
            text: "Paste Image URL"
            width: 138
            onClicked: {
              root.pasteVisible = !root.pasteVisible
              if (root.pasteVisible) Qt.callLater(function() { pasteField.forceActiveFocus() })
            }
          }
          ActionButton {
            text: "Clear Custom Icon"
            width: 150
            enabled: root.appHasCustomIcon(root.currentAppId)
            dimmed: !root.appHasCustomIcon(root.currentAppId)
            onClicked: root.clearIcon(root.currentAppId)
          }

          Item { width: 1; height: 1 }

          ActionButton {
            text: "Done"
            width: 72
            accent: true
            onClicked: root.close()
          }
        }

        // Status --------------------------------------------------------------
        Row {
          id: statusRow
          width: parent.width
          height: 16

          Text {
            width: parent.width
            text: root.statusText
            elide: Text.ElideRight
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  component ActionButton: Rectangle {
    id: buttonSelf
    property string text: ""
    property bool accent: false
    property bool enabled: true
    property bool dimmed: false
    height: 34
    radius: 10
    color: {
      if (!buttonSelf.enabled || buttonSelf.dimmed) return Util.alpha(Color.foreground, 0.05)
      if (buttonSelf.accent) return buttonMouse.containsMouse ? Util.alpha(Color.accent, 0.85) : Util.alpha(Color.accent, 0.7)
      return buttonMouse.containsMouse ? Util.alpha(Color.foreground, 0.16) : Util.alpha(Color.foreground, 0.08)
    }
    signal clicked()

    Text {
      anchors.centerIn: parent
      text: buttonSelf.text
      color: buttonSelf.accent ? Color.background : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: buttonSelf.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (buttonSelf.enabled) buttonSelf.clicked()
    }
  }
}