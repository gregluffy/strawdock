import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Qt.labs.folderlistmodel
import qs.Commons
import "DockModel.js" as Model

// Dock host: owns settings, the Hyprland window list, app grouping and the
// actions (launch / focus / close / pin). One DockWindow per screen renders it.
Item {
  id: root

  // Injected by omarchy-shell.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "straw.dock"
  readonly property string home: Quickshell.env("HOME")

  // Raw entry from shell.json plugins[] (settings live inline on it).
  property var entry: ({})
  readonly property var settings: Model.normalizeSettings(entry)
  onSettingsChanged: annotateClients()

  // Hyprland clients (hyprctl clients -j), annotated with appKey/entryId.
  property var clients: []
  property string activeAddress: ""
  property var urgentAddresses: ({})
  // entryId -> { t: launch time, count: windows it had }, cleared once it
  // gains a window (or after a timeout).
  property var launching: ({})
  // Unpinned app keys in first-seen order, so running apps don't reshuffle.
  property var runningOrder: []
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property var _classCache: ({})

  // User icon overrides for the mono/line styles:
  // ~/.config/omarchy/dock-icons/<desktop-id or window class>.svg|png
  readonly property string customIconDir: root.home + "/.config/omarchy/dock-icons"
  property var customIcons: ({})

  FolderListModel {
    id: customIconFolder
    folder: Util.fileUrl(root.customIconDir)
    nameFilters: ["*.svg", "*.png"]
    showDirs: false
    onCountChanged: root.scanCustomIcons()
    onStatusChanged: if (status === FolderListModel.Ready) root.scanCustomIcons()
  }

  function scanCustomIcons() {
    var next = {}
    for (var i = 0; i < customIconFolder.count; i++) {
      var file = String(customIconFolder.get(i, "fileName"))
      var base = file.slice(0, file.lastIndexOf(".")).toLowerCase()
      if (base && next[base] === undefined) next[base] = Util.fileUrl(root.customIconDir + "/" + file)
    }
    root.customIcons = next
  }

  function customIconFor(entryId, cls) {
    var keys = [entryId, cls]
    for (var i = 0; i < keys.length; i++) {
      var k = String(keys[i] || "").toLowerCase()
      if (k && root.customIcons[k]) return root.customIcons[k]
    }
    return ""
  }
  property var _rawClients: []

  // Bumped to ask every dock to reveal itself for a moment (IPC `reveal`).
  property int peekSerial: 0

  // Asks the dock on the focused monitor to open a popup (IPC).
  signal popupRequested(string mode, string appKey)

  // ------------------------------------------------------------ settings

  function loadShellConfig(text) {
    var found = null
    try {
      var cfg = JSON.parse(text || "{}")
      var list = Array.isArray(cfg.plugins) ? cfg.plugins : []
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].id) === root.pluginId) { found = list[i]; break }
      }
    } catch (e) {
      console.warn("straw.dock: could not parse shell.json:", e)
      return
    }
    var next = found ? Model.cloneJson(found) : ({})
    if (JSON.stringify(next) !== JSON.stringify(root.entry)) root.entry = next
  }

  function updateSettings(patch) {
    var next = Model.cloneJson(root.entry) || {}
    next.id = root.pluginId
    for (var k in patch) next[k] = patch[k]
    root.entry = next
    var persisted = {}
    for (var key in next) if (key !== "id") persisted[key] = next[key]
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.pluginId, persisted)
    else
      console.warn("straw.dock: shell API unavailable, settings not persisted")
  }

  function setPinned(ids) {
    root.updateSettings({ pinned: ids.slice() })
  }

  function isPinned(entryId) {
    return root.settings.pinned.indexOf(String(entryId)) !== -1
  }

  function pin(entryId) {
    var id = Model.normalizeDesktopId(entryId)
    if (!id || root.isPinned(id)) return
    var next = root.settings.pinned.slice()
    next.push(id)
    root.setPinned(next)
  }

  function unpin(entryId) {
    var id = Model.normalizeDesktopId(entryId)
    root.setPinned(root.settings.pinned.filter(function(p) { return p !== id }))
  }

  FileView {
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadShellConfig(text())
    onFileChanged: reload()
    onLoadFailed: root.loadShellConfig("{}")
  }

  // ------------------------------------------------------ desktop entries

  function desktopEntries() {
    return DesktopEntries.applications.values || []
  }

  function entryById(id) {
    try { return DesktopEntries.byId(String(id)) } catch (e) { return null }
  }

  function entryForClass(cls) {
    var key = String(cls || "").toLowerCase()
    if (!key) return null
    if (root._classCache[key] !== undefined) return root._classCache[key]
    var found = Model.bestEntryForClass(cls, root.desktopEntries())
    if (!found) {
      try { found = DesktopEntries.heuristicLookup(cls) } catch (e) { found = null }
    }
    root._classCache[key] = found || null
    return found || null
  }

  function iconSource(icon, fallbackName) {
    var value = String(icon || "")
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var names = [value, String(fallbackName || ""), String(fallbackName || "").toLowerCase()]
    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      if (!name) continue
      var indexed = root.iconIndex[name]
      if (indexed) return Util.fileUrl(indexed)
      var themed = Quickshell.iconPath(name, true)
      if (themed.length > 0) return themed
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root._classCache = ({})
      iconIndexDebounce.restart()
      root.annotateClients()
    }
  }

  // Themed lookups miss icons installed after the shell started (Qt caches the
  // theme), so index app icons on disk as a fallback — same as the app menu.
  Process {
    id: iconIndexScan
    command: ["bash", "-c", [
      'dirs="$HOME/.icons $HOME/.local/share/icons $HOME/.local/share/applications/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/applications/icons/*" \\) -name "*.$ext" 2>/dev/null; done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(" ")]
    stdout: SplitParser {
      onRead: function(line) {
        var path = String(line || "").trim()
        if (!path) return
        var file = path.slice(path.lastIndexOf("/") + 1)
        var name = file.slice(0, file.lastIndexOf("."))
        if (name && root.pendingIconIndex[name] === undefined) root.pendingIconIndex[name] = path
      }
    }
    onStarted: root.pendingIconIndex = ({})
    onExited: root.iconIndex = root.pendingIconIndex
  }

  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: if (!iconIndexScan.running) iconIndexScan.running = true
  }

  // --------------------------------------------------------------- windows

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "[]")
          root._rawClients = Array.isArray(parsed) ? parsed : []
        } catch (e) {
          return
        }
        root.annotateClients()
      }
    }
  }

  function refreshClients() {
    if (clientsProc.running) refreshAgain.restart()
    else clientsProc.running = true
  }

  Timer {
    id: refreshDebounce
    interval: 40
    onTriggered: root.refreshClients()
  }

  Timer {
    id: refreshAgain
    interval: 120
    onTriggered: root.refreshClients()
  }

  function monitorName(id) {
    var list = Hyprland.monitors.values || []
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return String(list[i].name)
    return ""
  }

  // Assign every client to an app. Pinned entries win so a window lands on
  // its pinned icon even when several desktop entries claim the same class.
  function annotateClients() {
    var pinnedEntries = []
    var pinned = root.settings.pinned
    for (var p = 0; p < pinned.length; p++) {
      var pe = root.entryById(pinned[p])
      if (pe) pinnedEntries.push(pe)
    }

    var out = []
    var seen = {}
    var active = ""
    var counts = {}
    for (var i = 0; i < root._rawClients.length; i++) {
      var c = root._rawClients[i]
      if (!c || c.mapped === false || !c.class && !c.initialClass) continue
      if (c.workspace && c.workspace.id === -1 && c.hidden) continue
      var cls = String(c.class || c.initialClass)
      var entry = Model.bestEntryForClass(cls, pinnedEntries)
        || (c.initialClass ? Model.bestEntryForClass(String(c.initialClass), pinnedEntries) : null)
        || root.entryForClass(cls)
        || (c.initialClass ? root.entryForClass(String(c.initialClass)) : null)
      var address = Model.normalizeAddress(c.address)
      var item = {
        address: address,
        cls: cls,
        title: String(c.title || c.initialTitle || cls),
        workspaceId: c.workspace ? c.workspace.id : 0,
        workspaceName: c.workspace ? String(c.workspace.name || c.workspace.id) : "",
        monitor: root.monitorName(c.monitor),
        at: c.at || [0, 0],
        size: c.size || [0, 0],
        fullscreen: Number(c.fullscreen || 0) > 0,
        focusHistoryID: c.focusHistoryID,
        entryId: entry ? String(entry.id) : "",
        appKey: entry ? String(entry.id) : "class:" + cls.toLowerCase()
      }
      if (c.focusHistoryID === 0) active = address
      if (item.entryId) counts[item.entryId] = (counts[item.entryId] || 0) + 1
      seen[item.appKey] = true
      out.push(item)
    }

    var launchingChanged = false
    var nextLaunching = {}
    for (var id in root.launching) {
      if ((counts[id] || 0) > root.launching[id].count) launchingChanged = true
      else nextLaunching[id] = root.launching[id]
    }
    if (launchingChanged) root.launching = nextLaunching

    var order = root.runningOrder.filter(function(k) { return seen[k] === true })
    for (var j = 0; j < out.length; j++)
      if (order.indexOf(out[j].appKey) === -1) order.push(out[j].appKey)

    if (JSON.stringify(order) !== JSON.stringify(root.runningOrder)) root.runningOrder = order
    if (active && root.activeAddress === "") root.activeAddress = active
    root.clients = out
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name || "")
      if (name === "activewindowv2") {
        root.activeAddress = Model.normalizeAddress(String(event.data || "").split(",")[0])
        if (root.urgentAddresses[root.activeAddress]) {
          var nextUrgent = {}
          for (var a in root.urgentAddresses) if (a !== root.activeAddress) nextUrgent[a] = true
          root.urgentAddresses = nextUrgent
        }
        refreshDebounce.restart()
        return
      }
      if (name === "urgent") {
        var addr = Model.normalizeAddress(event.data)
        if (addr && addr !== root.activeAddress) {
          var u = {}
          for (var k in root.urgentAddresses) u[k] = true
          u[addr] = true
          root.urgentAddresses = u
        }
        return
      }
      if (["openwindow", "closewindow", "movewindowv2", "windowtitlev2", "workspacev2",
           "focusedmonv2", "changefloatingmode", "fullscreen", "moveworkspacev2",
           "monitoraddedv2", "monitorremovedv2", "configreloaded"].indexOf(name) !== -1)
        refreshDebounce.restart()
    }
  }

  // Floating windows can be moved/resized without an event; keep geometry
  // (used by smart auto-hide) reasonably fresh.
  Timer {
    interval: 1500
    running: root.settings.autoHide === "smart"
    repeat: true
    onTriggered: root.refreshClients()
  }

  Timer {
    // Launches that never produce a window stop bouncing eventually.
    interval: 2000
    running: Object.keys(root.launching).length > 0
    repeat: true
    onTriggered: {
      var now = Date.now()
      var next = {}
      var changed = false
      for (var id in root.launching) {
        if (now - root.launching[id].t < 12000) next[id] = root.launching[id]
        else changed = true
      }
      if (changed) root.launching = next
    }
  }

  // ------------------------------------------------------------ app model

  // Apps for one dock. Returns pinned apps (in pinned order) followed by
  // running unpinned apps. `screenName`/`workspaceId` scope the windows.
  function appsFor(screenName, workspaceId) {
    var s = root.settings
    var groups = {}
    for (var i = 0; i < root.clients.length; i++) {
      var c = root.clients[i]
      if (s.windowScope === "monitor" && c.monitor !== screenName) continue
      if (s.windowScope === "workspace" && c.workspaceId !== workspaceId) continue
      if (!groups[c.appKey]) groups[c.appKey] = []
      groups[c.appKey].push(c)
    }

    var apps = []
    for (var p = 0; p < s.pinned.length; p++) {
      var id = s.pinned[p]
      var entry = root.entryById(id)
      if (!entry && !groups[id]) continue
      apps.push(root.makeApp(id, entry, groups[id] || [], true, ""))
    }

    if (s.showRunning) {
      for (var r = 0; r < root.runningOrder.length; r++) {
        var key = root.runningOrder[r]
        if (!groups[key] || s.pinned.indexOf(key) !== -1) continue
        var windows = groups[key]
        var e = windows[0].entryId ? root.entryById(windows[0].entryId) : null
        apps.push(root.makeApp(key, e, windows, false, windows[0].cls))
      }
    }
    return apps
  }

  function makeApp(key, entry, windows, pinned, cls) {
    var sorted = Model.sortWindows(windows)
    var focused = false
    var urgent = false
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i].address === root.activeAddress) focused = true
      if (root.urgentAddresses[sorted[i].address]) urgent = true
    }
    var entryId = entry ? String(entry.id) : ""
    var windowClass = cls || (sorted.length > 0 ? sorted[0].cls : "")
    var name = entry ? String(entry.name || entryId) : Model.prettyClass(cls)
    return {
      key: key,
      entryId: entryId,
      name: name,
      glyph: Model.glyphFor(entryId, windowClass, name),
      customIcon: root.customIconFor(entryId, windowClass),
      icon: root.iconSource(entry ? entry.icon : "", cls || key),
      pinned: pinned,
      windows: sorted,
      focused: focused,
      urgent: urgent,
      launching: entryId !== "" && root.launching[entryId] !== undefined,
      canLaunch: entryId !== ""
    }
  }

  // --------------------------------------------------------------- actions

  function dispatch(expr) {
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
  }

  function focusWindow(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    root.dispatch('hl.dsp.focus({ window = "address:0x' + addr + '" })')
  }

  function closeWindow(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    root.dispatch('hl.dsp.window.close({ window = "address:0x' + addr + '" })')
  }

  function launch(entryId) {
    var id = Model.normalizeDesktopId(entryId)
    if (!id) return
    var count = 0
    for (var i = 0; i < root.clients.length; i++) if (root.clients[i].entryId === id) count++
    var next = {}
    for (var k in root.launching) next[k] = root.launching[k]
    next[id] = { t: Date.now(), count: count }
    root.launching = next
    // Same launch path as the Omarchy app menu: gtk-launch inside a uwsm scope.
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  function runAction(action) {
    if (action && typeof action.execute === "function") action.execute()
  }

  // Jump the given monitor to its first empty workspace (see new-workspace.sh).
  function newWorkspace(monitorName) {
    var script = String(Qt.resolvedUrl("new-workspace.sh")).replace(/^file:\/\//, "")
    Quickshell.execDetached(["bash", decodeURIComponent(script), String(monitorName || "")])
  }

  function openAppGrid() {
    Quickshell.execDetached(["omarchy-menu", "toggle", "apps"])
  }

  // Scroll over an icon: step through that app's windows in a stable order.
  function cycle(app, direction) {
    if (!app || app.windows.length === 0) return
    var ordered = app.windows.slice().sort(function(a, b) { return a.address < b.address ? -1 : 1 })
    var idx = -1
    for (var i = 0; i < ordered.length; i++) if (ordered[i].address === root.activeAddress) idx = i
    var next = idx === -1 ? 0 : (idx + direction + ordered.length) % ordered.length
    root.focusWindow(ordered[next].address)
  }

  function toplevelFor(address) {
    var addr = Model.normalizeAddress(address)
    var list = Hyprland.toplevels.values || []
    for (var i = 0; i < list.length; i++) {
      if (Model.normalizeAddress(list[i].address) === addr) return list[i].wayland || null
    }
    return null
  }

  // ------------------------------------------------------------- screens

  // The "main" monitor: the configured one if it's connected, otherwise the
  // monitor holding workspace 1, otherwise Hyprland's first monitor.
  readonly property string mainMonitorName: {
    var screens = Quickshell.screens
    var names = screens.map(function(scr) { return String(scr.name) })
    var configured = root.settings.mainMonitor
    if (configured && names.indexOf(configured) !== -1) return configured
    var workspaces = Hyprland.workspaces.values || []
    for (var i = 0; i < workspaces.length; i++) {
      var ws = workspaces[i]
      if (ws.id === 1 && ws.monitor && names.indexOf(String(ws.monitor.name)) !== -1) return String(ws.monitor.name)
    }
    var monitors = (Hyprland.monitors.values || []).slice().sort(function(a, b) { return a.id - b.id })
    for (var m = 0; m < monitors.length; m++)
      if (names.indexOf(String(monitors[m].name)) !== -1) return String(monitors[m].name)
    return names.length > 0 ? names[0] : ""
  }

  readonly property var targetScreens: {
    var all = Quickshell.screens
    var wanted = root.settings.monitors
    if (wanted === "main") return all.filter(function(scr) { return String(scr.name) === root.mainMonitorName })
    if (!Array.isArray(wanted)) return all
    var picked = all.filter(function(scr) { return wanted.indexOf(String(scr.name)) !== -1 })
    // Never leave the user without a dock because a chosen monitor is unplugged.
    return picked.length > 0 ? picked : all
  }

  function setMonitorMode(mode) {
    if (mode === "custom") {
      var current = root.targetScreens.map(function(scr) { return String(scr.name) })
      root.updateSettings({ monitors: current })
    } else {
      root.updateSettings({ monitors: mode })
    }
  }

  // The user's name for an output, falling back to the output name itself.
  function monitorLabel(name) {
    return root.settings.monitorNames[String(name)] || String(name)
  }

  function setMonitorName(name, label) {
    var next = Model.cloneJson(root.settings.monitorNames) || {}
    label = String(label || "").trim()
    if (label.length > 0) next[name] = label
    else delete next[name]
    if (JSON.stringify(next) !== JSON.stringify(root.settings.monitorNames)) root.updateSettings({ monitorNames: next })
  }

  // Custom mode: toggle one monitor, keeping at least one selected.
  function toggleMonitor(name) {
    var current = Array.isArray(root.settings.monitors)
      ? root.settings.monitors.slice()
      : root.targetScreens.map(function(scr) { return String(scr.name) })
    var idx = current.indexOf(name)
    if (idx === -1) current.push(name)
    else if (current.length > 1) current.splice(idx, 1)
    else return
    root.updateSettings({ monitors: current })
  }

  Variants {
    model: root.targetScreens
    delegate: DockWindow {
      dock: root
    }
  }

  // ------------------------------------------------------------------ IPC

  IpcHandler {
    target: "dock"
    function reveal(): string { root.peekSerial++; return "ok" }
    function setPosition(position: string): string { root.updateSettings({ position: position }); return "ok" }
    function setIconSize(size: int): string { root.updateSettings({ iconSize: size }); return "ok" }
    function setMonitors(mode: string): string {
      // "all", "main", or a comma-separated list of output names.
      if (mode === "all" || mode === "main") root.updateSettings({ monitors: mode })
      else root.updateSettings({ monitors: mode.split(",").map(function(n) { return n.trim() }).filter(function(n) { return n.length > 0 }) })
      return "ok"
    }
    function setMainMonitor(name: string): string { root.updateSettings({ mainMonitor: name }); return "ok" }
    function setMonitorName(monitor: string, name: string): string { root.setMonitorName(monitor, name); return "ok" }
    function newWorkspace(monitor: string): string { root.newWorkspace(monitor); return "ok" }
    function setIconStyle(style: string): string { root.updateSettings({ iconStyle: style }); return "ok" }
    function setBorder(enabled: bool): string { root.updateSettings({ border: enabled }); return "ok" }
    function setAutoHide(mode: string): string { root.updateSettings({ autoHide: mode }); return "ok" }
    function pin(desktopId: string): string { root.pin(desktopId); return "ok" }
    function unpin(desktopId: string): string { root.unpin(desktopId); return "ok" }
    function settings(): string { return JSON.stringify(root.settings) }
    function closePopups(): string { root.popupRequested("", ""); return "ok" }
    function openSettings(): string { root.popupRequested("settings", ""); return "ok" }
    function showWindows(appKey: string): string { root.popupRequested("picker", appKey); return "ok" }
    function showMenu(appKey: string): string { root.popupRequested("menu", appKey); return "ok" }
    function ping(): string { return "ok" }
  }

  Component.onCompleted: {
    Hyprland.refreshToplevels()
    iconIndexScan.running = true
    root.refreshClients()
  }
}
