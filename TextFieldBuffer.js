.pragma library

// Pure editing model for BoundedTextField.qml. The picker deliberately does
// not use Qt's native TextInput: an editable QQuickTextInput asks the platform
// clipboard for its text on every selection change, which on Wayland can block
// the shared Omarchy shell on a hostile offer. Keeping the string in QML and
// editing it through these functions removes that automatic transfer; the
// clipboard is only read when the user explicitly pastes.

var DEFAULT_MAX_LENGTH = 4096

// Control characters, bidi overrides, and line separators would either break
// the one-line layout or reorder what the user sees after a paste. Replace
// them with spaces and collapse runs so pasted text stays predictable.
function sanitize(value) {
    var text = String(value == null ? "" : value)
    text = text.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ")
    text = text.replace(/[ \t]{2,}/g, " ")
    return text
}

function maxLengthFor(value) {
    var limit = Number(value)
    if (!isFinite(limit) || limit < 0) return DEFAULT_MAX_LENGTH
    return Math.floor(limit)
}

function clampCursor(text, cursor) {
    var length = String(text == null ? "" : text).length
    var position = Number(cursor)
    if (!isFinite(position)) return length
    position = Math.floor(position)
    if (position < 0) return 0
    return position > length ? length : position
}

function insert(text, cursor, chunk, maximumLength) {
    var current = String(text == null ? "" : text)
    var position = clampCursor(current, cursor)
    var addition = sanitize(chunk)
    var room = maxLengthFor(maximumLength) - current.length
    if (room <= 0 || addition === "") return { text: current, cursor: position }
    if (addition.length > room) addition = addition.slice(0, room)
    return {
        text: current.slice(0, position) + addition + current.slice(position),
        cursor: position + addition.length
    }
}

function backspace(text, cursor) {
    var current = String(text == null ? "" : text)
    var position = clampCursor(current, cursor)
    if (position <= 0) return { text: current, cursor: 0 }
    return {
        text: current.slice(0, position - 1) + current.slice(position),
        cursor: position - 1
    }
}

function removeForward(text, cursor) {
    var current = String(text == null ? "" : text)
    var position = clampCursor(current, cursor)
    if (position >= current.length) return { text: current, cursor: position }
    return {
        text: current.slice(0, position) + current.slice(position + 1),
        cursor: position
    }
}

function moveLeft(text, cursor) {
    var position = clampCursor(text, cursor)
    return position > 0 ? position - 1 : 0
}

function moveRight(text, cursor) {
    var current = String(text == null ? "" : text)
    var position = clampCursor(current, cursor)
    return position < current.length ? position + 1 : current.length
}

function home() {
    return 0
}

function end(text) {
    return String(text == null ? "" : text).length
}

function clear() {
    return { text: "", cursor: 0 }
}

// Programmatic writes (prefill, reset) are owned by the plugin, not the
// clipboard, so they are not sanitized; only the cursor is normalized.
function setText(value) {
    var text = String(value == null ? "" : value)
    return { text: text, cursor: text.length }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        DEFAULT_MAX_LENGTH: DEFAULT_MAX_LENGTH,
        sanitize: sanitize,
        clampCursor: clampCursor,
        insert: insert,
        backspace: backspace,
        removeForward: removeForward,
        moveLeft: moveLeft,
        moveRight: moveRight,
        home: home,
        end: end,
        clear: clear,
        setText: setText
    }
}
