import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "TextFieldBuffer.js" as Buffer

// Single-line text input that never instantiates a native TextInput.
//
// Qt's editable QQuickTextInput polls the platform clipboard on every
// selection change (QQuickTextInput::q_canPasteChanged -> mimeData->text()),
// and a Wayland data offer can be arbitrarily large, so a hostile clipboard
// client can stall the shared omarchy-shell GUI thread. A read-only native
// input skips that read, but cannot be edited or paste with IME; this control
// keeps the string in QML, edits it through TextFieldBuffer.js, and reads the
// clipboard only when the user presses paste, through a byte-capped,
// time-limited wl-paste in a separate process.
//
// Trade-offs, deliberate and documented in the README: the native text
// selection/IME path is not used, so composition (CJK IME) input is not
// available in these fields and pasted text is inserted at the caret.
Item {
  id: root

  property string text: ""
  property string placeholderText: ""
  property int maximumLength: Buffer.DEFAULT_MAX_LENGTH
  property color color: Color.foreground
  property color placeholderColor: Qt.darker(Color.foreground, 1.6)
  property alias font: content.font
  property int cursor: 0

  // Bounded, deadline-limited clipboard reader. 4 KiB is far above any search
  // term or image URL, and timeout(1) guarantees the process (and the GUI
  // queue behind it) cannot wait on an endless producer.
  readonly property int pasteByteLimit: 4096
  readonly property string pasteCommand: "set -o pipefail; timeout -k 1 2 wl-paste --no-newline 2>/dev/null | head -c " + root.pasteByteLimit

  implicitWidth: 120
  implicitHeight: Math.max(20, content.implicitHeight + 6)
  activeFocusOnTab: true
  clip: true

  signal escapePressed()
  signal accepted()
  signal pasteFailed()

  readonly property bool editing: root.activeFocus

  function focusInput() {
    root.forceActiveFocus()
  }

  function apply(result) {
    root.text = result.text
    root.cursor = result.cursor
  }

  function insertChunk(chunk) {
    if (!chunk) return
    root.apply(Buffer.insert(root.text, root.cursor, chunk, root.maximumLength))
  }

  function setText(value) {
    root.apply(Buffer.setText(value))
  }

  function clear() {
    root.apply(Buffer.clear())
  }

  function pasteFromClipboard() {
    if (pasteProcess.running) return
    pasteProcess.collected = ""
    pasteProcess.running = true
  }

  Keys.onPressed: function(event) {
    var mods = event.modifiers
    var command = (mods & Qt.ControlModifier) && !(mods & Qt.AltModifier)
    if (event.key === Qt.Key_Escape) {
      root.escapePressed()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.accepted()
      event.accepted = true
      return
    }
    if (command && event.key === Qt.Key_V) {
      root.pasteFromClipboard()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Insert && (mods & Qt.ShiftModifier)) {
      root.pasteFromClipboard()
      event.accepted = true
      return
    }
    if (command && event.key === Qt.Key_U) {
      root.clear()
      event.accepted = true
      return
    }
    if (command) return
    // Let the window's focus traversal handle Tab instead of inserting it as
    // text (which would also trap keyboard focus inside the field).
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) return
    if (event.key === Qt.Key_Backspace) {
      root.apply(Buffer.backspace(root.text, root.cursor))
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Delete) {
      root.apply(Buffer.removeForward(root.text, root.cursor))
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Left) {
      root.cursor = Buffer.moveLeft(root.text, root.cursor)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Right) {
      root.cursor = Buffer.moveRight(root.text, root.cursor)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Home) {
      root.cursor = Buffer.home()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_End) {
      root.cursor = Buffer.end(root.text)
      event.accepted = true
      return
    }
    if (event.text && event.text.length > 0) {
      root.insertChunk(event.text)
      event.accepted = true
    }
  }

  onTextChanged: if (root.cursor > root.text.length) root.cursor = root.text.length

  // Display ---------------------------------------------------------------

  Text {
    id: content
    textFormat: Text.PlainText
    text: root.text
    color: root.color
    anchors.verticalCenter: parent.verticalCenter
    // Scroll the single line just enough to keep the caret in view, which
    // matters when Home/End or a long paste moves it outside the field.
    x: {
      var minimum = Math.min(0, root.width - content.implicitWidth)
      var desired = root.width - caretMetrics.width - 4
      return Math.max(minimum, Math.min(0, desired))
    }
    visible: root.text.length > 0
  }

  Text {
    id: placeholder
    textFormat: Text.PlainText
    text: root.placeholderText
    color: root.placeholderColor
    font: content.font
    anchors.verticalCenter: parent.verticalCenter
    x: 0
    visible: root.text.length === 0
  }

  TextMetrics {
    id: caretMetrics
    font: content.font
    text: root.text.substring(0, root.cursor)
  }

  Rectangle {
    id: caret
    visible: root.activeFocus
    width: 1
    height: Math.max(12, content.implicitHeight)
    color: root.color
    x: content.x + caretMetrics.width
    y: content.y
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.IBeamCursor
    onClicked: {
      root.forceActiveFocus()
      root.cursor = root.text.length
    }
  }

  Process {
    id: pasteProcess
    property string collected: ""
    command: ["bash", "-c", root.pasteCommand]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: pasteProcess.collected = text
    }
    onExited: function(exitCode) {
      // A paste larger than the cap makes wl-paste die of SIGPIPE after head
      // has already collected its 4 KiB, so partial data is still inserted.
      // An empty result means either an empty clipboard (exit 0) or a missing
      // helper / expired deadline (non-zero), which is worth reporting.
      if (pasteProcess.collected !== "")
        root.insertChunk(pasteProcess.collected)
      else if (exitCode !== 0)
        root.pasteFailed()
      pasteProcess.collected = ""
    }
  }
}
