.pragma library

// Reuse the battle-tested dock model and only tune the geometry used by the
// visual refinement branch. Keeping the original implementation in
// DockModelBase.js avoids duplicating ordering, drag and persistence logic.
Qt.include("DockModelBase.js")

LAYOUT_OPTS.slotWidth = 60
LAYOUT_OPTS.spacing = 6
LAYOUT_OPTS.iconSize = 54
LAYOUT_OPTS.hoverScale = 1.36
LAYOUT_OPTS.radius = 96
LAYOUT_OPTS.sidePadding = 12
LAYOUT_OPTS.separatorWidth = 12
