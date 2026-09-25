# luffy.dock

Themed application dock for the Omarchy shell (a keep-loaded `panel` plugin).

- Pinned apps plus running apps. Click to launch, or to focus a single window
  (this switches to its workspace). With 2+ windows, click opens a picker with
  live previews.
- Middle-click: new window. Right-click: window list, desktop actions,
  pin/unpin, close. Scroll: cycle the app's windows. Drag pinned icons to reorder.
- Right-click the dock background (or the app-grid button) for settings.
- Colors, borders, font and corner radius follow the current Omarchy theme.

## Settings

Stored inline on the `luffy.dock` entry in `~/.config/omarchy/shell.json`
under `plugins[]` (hot-reloads on save):

| key | default | values |
|---|---|---|
| `position` | `"bottom"` | `bottom`, `left`, `right` |
| `iconSize` | `48` | 24–128 |
| `magnification` | `true` | bool |
| `magnifyScale` | `1.6` | 1–2.5 |
| `autoHide` | `"smart"` | `never` (reserves space), `smart` (hide when a window touches it), `always` |
| `windowScope` | `"all"` | `all`, `monitor`, `workspace` |
| `previews` | `true` | bool |
| `showLauncher` | `true` | bool |
| `showNewWorkspace` | `true` | bool — button that jumps to an empty workspace on that monitor |
| `showRunning` | `true` | bool |
| `border` | `true` | bool — theme border around the dock |
| `monitors` | `"all"` | `"all"`, `"main"`, or `["DP-1", ...]` |
| `mainMonitor` | `""` | output name for `"main"`; empty = monitor holding workspace 1 |
| `opacity` | `0.92` | 0–1 |
| `margin` | `8` | px from the screen edge |
| `pinned` | foot, Nautilus, Chrome, Code, Spotify, Obsidian | desktop ids |

## IPC

```
omarchy-shell dock reveal | openSettings | closePopups
omarchy-shell dock setPosition left|bottom|right
omarchy-shell dock setIconSize 56
omarchy-shell dock setAutoHide never|smart|always
omarchy-shell dock setBorder true|false
omarchy-shell dock newWorkspace [monitor]   # empty = focused monitor
omarchy-shell dock setMonitors all|main|DP-1,DP-3
omarchy-shell dock setMainMonitor DP-1
omarchy-shell dock pin <desktop-id> | unpin <desktop-id>
omarchy-shell dock showWindows <desktop-id> | showMenu <desktop-id>
omarchy-shell dock settings
```

## Install

```
omarchy plugin add git@gitlab.com:administration7242251/quick-shell-plugins/straw-dock.git --enable --yes
```

Or by hand: clone this repo to `~/.config/omarchy/plugins/luffy.dock`, then
`omarchy-shell shell rescanPlugins && omarchy plugin enable luffy.dock`.
