# macos.dock

A compact, bottom-centered macOS-inspired dock plugin for Omarchy.

![Omarchy macOS dock preview](assets/dock-preview.png)

## Features

- Glassy floating dock surface
- Subtle hover scaling and application tooltips
- Pinned application persistence
- Running-application indicators
- Pin, unpin, new-window, and close actions
- Live window previews on hover, with cached thumbnail fallbacks
- Custom macOSicons, local PNG, and WebP icon overrides
- macOS-style Alt+Tab application switcher (most-recently-used order)
- Tiling window adaptation: while the dock is shown, it reserves its footprint
  as a Wayland exclusive zone, so tiled windows never overlap it

## Install

Add and enable the plugin through Omarchy's plugin manager:

```bash
omarchy plugin add https://github.com/ifubaraboye/omarchy-dock.git
omarchy plugin enable ifubaraboye.dock
```

The dock stores pins in:

```text
~/.config/omarchy/dock-pinned-macos.json
```

## Requirements and removal

This plugin requires Omarchy with Quickshell, plus `bash`, `curl`, `python3`,
ImageMagick (`magick` or `convert` and `identify`), and `xdg-open` for the
optional custom-icon helper.

For the best experience, use **floating windows** (not tiling): the dock is
designed to work with a floating layout where windows overlap its surface, and
it behaves best when windows are allowed to float over it rather than being
tiled up to its edges.

Tiled layouts are supported too: while the dock is visible ("Always Show"
mode), it claims its footprint (dock surface plus bottom margin) as a Wayland
exclusive zone, so tiled Hyprland windows reserve that space and never overlap
the dock. Hiding the dock releases the zone and tiled windows reclaim the
space. Floating windows are unaffected and may still overlap the dock by
design.

To remove the plugin, disable it and delete its installed directory:

```bash
omarchy plugin disable ifubaraboye.dock
rm -rf ~/.config/omarchy/plugins/ifubaraboye.dock
omarchy restart shell
```

The plugin does not overwrite existing Omarchy or user configuration files.
It only creates or updates its own files under `~/.config/omarchy/` after the
user explicitly invokes a dock action or the custom-icon helper. Custom icon
files and mappings can be removed with `omarchy-dock-icon clear <app-id>`.

The repository author owns this plugin and has permission to submit the source
code and preview assets. External icons downloaded from macOSicons remain
subject to their respective rights and terms; users should only use assets
they are permitted to use.

Plugin-directory approval is for listing in the Omarchy plugin directory and
is not a security review or endorsement. Review the source and dependencies
before installing.

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

## Alt+Tab application switcher

The plugin ships a macOS-style app switcher (a glass pill with the running
applications in most-recently-used order). No setup is needed: when the shell
starts, the plugin registers the bindings automatically:

- `ALT + GRAVE` (Alt + `` ` ``) — next application
- `ALT + SHIFT + GRAVE` (Alt + Shift + `` ` ``) — previous application

Behavior:

- Hold `Alt`, press `` ` `` to cycle forward, `Shift + `` ` `` to cycle
  backward. The first press selects the application after the currently
  focused one, like macOS.
- Release `Alt` to activate the selected application (its most recently
  focused window, or launch it if none is open).
- `Enter` activates the selection, `Escape` cancels without changing focus,
  arrow keys move the selection, and the mouse can hover to select or click
  to activate.
- The switcher opens on the dock's primary screen and cycles applications
  only — pinned-but-closed applications are never included.

### Changing the keybind

The registered binds live only for the current session (they are re-added at
each shell start and never written to any config file). To use a different
combination, add your own bind to `~/.config/hypr/bindings.lua` — your
config-file bind takes precedence over the plugin's default:

```lua
o.bind("ALT + TAB", "App switcher next", "omarchy-shell -q macos.dock altTabNext")
o.bind("ALT + SHIFT + TAB", "App switcher prev", "omarchy-shell -q macos.dock altTabPrev")
```

Note: Omarchy's default config already binds `ALT + TAB` to window cycling, so
if you rebind to `ALT + TAB` you must first free it with `hl.unbind("ALT + TAB")`
in your `bindings.lua` (and `hl.unbind("ALT + SHIFT + TAB")` for the previous
direction).

For testing without bindings:

```bash
omarchy-shell -q macos.dock altTabNext
omarchy-shell -q macos.dock altTabPrev
omarchy-shell -q macos.dock altTabCancel
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
