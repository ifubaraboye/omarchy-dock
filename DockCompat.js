.pragma library

// Omarchy 4.5 added Style.duration() so the shell's animation setting applies
// to plugin motion. Older shells have no such helper, so use the plain
// millisecond value there.
function duration(style, ms) {
    if (style && typeof style.duration === "function") return style.duration(ms)
    return Number(ms) || 0
}
