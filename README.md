# macos.dock

A compact, bottom-centered macOS-inspired dock plugin for Omarchy.

## Features

- Glassy floating dock surface
- Subtle hover scaling and application tooltips
- Pinned application persistence
- Running-application indicators
- Pin, unpin, new-window, and close actions
- Conflict detection for `rosakodu.dock`
- Custom macOSicons, local PNG, and WebP icon overrides

## Install

Copy this directory to:

```text
~/.config/omarchy/plugins/macos.dock
```

Enable `macos.dock` through Omarchy's normal plugin configuration. The dock stores pins in:

```text
~/.config/omarchy/dock-pinned-macos.json
```

## Custom icons

Use the helper to assign an icon from macOSicons, a direct image URL, or a
local image:

```bash
omarchy-dock-icon set code figma-i3FsrkYvf6
omarchy-dock-icon set code --file ~/Pictures/code.png
omarchy-dock-icon list
omarchy-dock-icon clear code
omarchy-dock-icon folder
```

The dock visibility shortcut is `SUPER + H`. It can also be controlled from a
terminal:

```bash
omarchy-shell macos.dock hide
omarchy-shell macos.dock show
omarchy-shell macos.dock toggle
```

Icons are normalized into transparent macOS-style rounded PNGs and metadata is
stored in `~/.config/omarchy/icons/` and `~/.config/omarchy/dock-icons.json`.
Changes are watched and applied without restarting the shell. The helper is installed at
`~/.local/bin/omarchy-dock-icon`.

## Development

```bash
./tests/run.sh
qmllint DockPanel.qml DockItem.qml DockMenu.qml
```

The dock is intended for a single primary output and uses the first configured Quickshell screen.
