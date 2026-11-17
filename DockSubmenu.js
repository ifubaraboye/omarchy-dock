.pragma library

// Submenu hover state machine for the dock context menus, extracted from
// DockMenu.qml so the discipline is unit-testable: a flyout opens on its row,
// stays up while any hover source is active (row, flyout padding, flyout
// rows), and closes only when nothing has re-entered by the time the grace
// timer elapses. A background MouseArea cannot observe hover over a flyout's
// rows — Qt delivers hover to the topmost acceptor only — so every source
// reports through this module instead and the state here is authoritative.
//
// Sources are keyed strings. "row" is special: only the parent row opens the
// flyout; the other sources merely hold it open. The QML side owns the
// bindable `open` flags and the timers and applies the returned commands:
//   entered(...)    -> { open, stopGrace }   open on row enters, always stop
//   exited(...)     -> { startGrace }        arm the close timer when idle
//   graceElapsed(..)-> { close }             close only when still idle
//   menuClosed(..)  -> forget all hover state

function create() {
    return { sources: {} }
}

function isEmpty(state) {
    for (var key in state.sources) return false
    return true
}

function entered(state, source) {
    state.sources[source] = true
    return {
        open: source === "row",
        stopGrace: true
    }
}

// The grace timer only arms when every source has been left, so a crossing
// (row -> gap -> padding) never starts a close.
function exited(state, source) {
    delete state.sources[source]
    return {
        startGrace: isEmpty(state)
    }
}

function graceElapsed(state) {
    return {
        close: isEmpty(state)
    }
}

function menuClosed(state) {
    state.sources = {}
}
