.pragma library

// Pure helpers for the dock: settings normalization, window-class to
// desktop-entry matching, and app grouping. No QML state lives here.

var DEFAULT_PINNED = ["foot", "org.gnome.Nautilus", "google-chrome", "code", "spotify", "obsidian"]

var DEFAULTS = {
  position: "bottom",       // bottom | left | right
  iconSize: 48,             // px, before magnification
  magnification: true,
  magnifyScale: 1.6,        // peak zoom of the hovered icon
  autoHide: "smart",        // never | smart (hide when a window touches the dock) | always
  windowScope: "all",       // all | monitor | workspace — which windows each dock shows
  previews: true,           // live thumbnails in the window picker
  showLauncher: true,       // app-grid button at the start of the dock
  showRunning: true,        // show running apps that are not pinned
  monitors: "all",          // "all", "main", or an array of output names, e.g. ["DP-1", "DP-3"]
  mainMonitor: "",          // output name used for "main"; empty = the monitor holding workspace 1
  opacity: 0.92,            // dock background opacity
  margin: 8,                // gap between the dock and the screen edge
  pinned: DEFAULT_PINNED
}

function clamp(value, min, max, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function oneOf(value, options, fallback) {
  return options.indexOf(String(value)) !== -1 ? String(value) : fallback
}

function normalizeSettings(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var pinned = Array.isArray(s.pinned) ? s.pinned.map(normalizeDesktopId).filter(function(id) { return id.length > 0 }) : DEFAULT_PINNED.slice()
  var monitors = "all"
  if (Array.isArray(s.monitors)) {
    monitors = s.monitors.map(String).filter(function(n) { return n.length > 0 })
    if (monitors.length === 0) monitors = "all"
  } else if (s.monitors === "main") {
    monitors = "main"
  }
  return {
    position: oneOf(s.position, ["bottom", "left", "right"], DEFAULTS.position),
    iconSize: Math.round(clamp(s.iconSize, 24, 128, DEFAULTS.iconSize)),
    magnification: s.magnification === undefined ? DEFAULTS.magnification : s.magnification === true,
    magnifyScale: clamp(s.magnifyScale, 1, 2.5, DEFAULTS.magnifyScale),
    autoHide: oneOf(s.autoHide, ["never", "smart", "always"], DEFAULTS.autoHide),
    windowScope: oneOf(s.windowScope, ["all", "monitor", "workspace"], DEFAULTS.windowScope),
    previews: s.previews === undefined ? DEFAULTS.previews : s.previews === true,
    showLauncher: s.showLauncher === undefined ? DEFAULTS.showLauncher : s.showLauncher === true,
    showRunning: s.showRunning === undefined ? DEFAULTS.showRunning : s.showRunning === true,
    monitors: monitors,
    mainMonitor: typeof s.mainMonitor === "string" ? s.mainMonitor : DEFAULTS.mainMonitor,
    opacity: clamp(s.opacity, 0, 1, DEFAULTS.opacity),
    margin: Math.round(clamp(s.margin, 0, 64, DEFAULTS.margin)),
    pinned: pinned
  }
}

function normalizeDesktopId(id) {
  var value = String(id || "").trim()
  if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
  return value
}

function normalizeAddress(address) {
  return String(address || "").trim().toLowerCase().replace(/^0x/, "")
}

// Chromium names --app windows "chrome-<host>_<path with / as _>-<profile>",
// e.g. https://discord.com/channels/@me -> chrome-discord.com__channels_@me-Default.
// Omarchy web apps launch through omarchy-launch-webapp <url>, so the class
// can be derived from the URL in the desktop entry's Exec line.
function webappClassStem(execString) {
  var m = String(execString || "").match(/https?:\/\/([^\s"'%]+)/)
  if (!m) return ""
  var rest = m[1].split(/[?#]/)[0]
  var slash = rest.indexOf("/")
  var host = slash === -1 ? rest : rest.slice(0, slash)
  var path = slash === -1 ? "/" : rest.slice(slash)
  return ("chrome-" + host + "_" + path.replace(/\//g, "_")).toLowerCase()
}

function classMatchesEntry(cls, entry) {
  if (!entry) return 0
  var c = String(cls || "").toLowerCase()
  if (!c) return 0
  var id = String(entry.id || "").toLowerCase()
  var startup = String(entry.startupClass || "").toLowerCase()
  if (startup && startup === c) return 100
  if (id === c) return 90
  var stem = webappClassStem(entry.execString)
  if (stem && c.indexOf(stem + "-") === 0) return 85
  // Reverse-DNS ids (org.gnome.Nautilus) vs short classes (nautilus).
  var lastDot = id.lastIndexOf(".")
  if (lastDot !== -1 && id.slice(lastDot + 1) === c) return 70
  var cmd = Array.isArray(entry.command) && entry.command.length > 0 ? String(entry.command[0]) : ""
  var base = cmd.slice(cmd.lastIndexOf("/") + 1).toLowerCase()
  if (base && base === c) return 60
  if (String(entry.name || "").toLowerCase() === c) return 50
  return 0
}

function bestEntryForClass(cls, entries) {
  var best = null
  var bestScore = 0
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var score = classMatchesEntry(cls, e)
    // Prefer entries that appear in launchers over helper/hidden ones.
    if (score > 0 && e.noDisplay) score -= 5
    if (score > bestScore) { best = e; bestScore = score }
  }
  return best
}

function prettyClass(cls) {
  var c = String(cls || "")
  var dot = c.lastIndexOf(".")
  if (dot !== -1) c = c.slice(dot + 1)
  c = c.replace(/[-_]+/g, " ")
  return c.length > 0 ? c.charAt(0).toUpperCase() + c.slice(1) : "Application"
}

// Sort a group's windows so the most recently focused window comes first.
function sortWindows(windows) {
  return windows.slice().sort(function(a, b) {
    var fa = a.focusHistoryID === undefined ? 9999 : a.focusHistoryID
    var fb = b.focusHistoryID === undefined ? 9999 : b.focusHistoryID
    return fa - fb
  })
}

function rectsOverlap(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value === undefined ? null : value))
}
