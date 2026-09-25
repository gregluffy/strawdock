import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "DockModel.js" as Model

// One dock on one screen. The layer surface spans the whole screen edge but
// its input mask only covers the dock itself (or a thin reveal strip when
// hidden), so clicks elsewhere fall through to windows.
PanelWindow {
  id: win

  required property var modelData
  required property var dock
  screen: modelData

  readonly property var s: dock.settings
  readonly property string position: s.position
  readonly property bool vertical: position !== "bottom"
  // Unit vector pointing away from the screen edge (towards the desktop).
  readonly property int outX: position === "left" ? 1 : (position === "right" ? -1 : 0)
  readonly property int outY: position === "bottom" ? -1 : 0

  // ------------------------------------------------------------ geometry
  readonly property int iconSize: s.iconSize
  readonly property int innerPad: Math.max(3, Math.round(iconSize * 0.12))
  readonly property int tileBase: iconSize + innerPad * 2
  readonly property int dockPad: Math.max(4, Math.round(iconSize * 0.16))
  readonly property int itemGap: Math.max(2, Math.round(iconSize * 0.08))
  readonly property int sepLen: Math.max(6, Math.round(iconSize * 0.3))
  readonly property int thickness: tileBase + dockPad * 2
  readonly property int margin: s.margin
  readonly property real zoomPeak: s.magnification ? s.magnifyScale : 1
  readonly property int zoomExtra: Math.ceil(tileBase * (zoomPeak - 1))
  readonly property int tipSpace: Math.round(Style.font.body * 2.2) + Style.space(18)
  readonly property int popupGap: Style.space(10)
  readonly property int radius: Style.cornerRadius > 0 ? Style.cornerRadius + Math.round(dockPad / 2) : 0
  readonly property int tileRadius: Style.cornerRadius

  readonly property int crossBase: margin + thickness + zoomExtra + tipSpace
  // The surface keeps a fixed size with room for popups reserved up front.
  // Resizing a layer surface when a popup opens/closes makes Hyprland show
  // the dock missing or misplaced for a frame. The extra area is transparent
  // and outside the input mask, so it's invisible and click-through.
  readonly property int screenCross: win.screen ? (vertical ? win.screen.width : win.screen.height) : 1080
  readonly property int cross: Math.max(crossBase, Math.round(screenCross * 0.75))

  anchors {
    bottom: position === "bottom" || vertical
    top: vertical
    left: position !== "right"
    right: position !== "left"
  }
  implicitWidth: vertical ? cross : 200
  implicitHeight: vertical ? 200 : cross
  color: "transparent"

  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: popupMode !== "" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
  exclusionMode: s.autoHide === "never" ? ExclusionMode.Normal : ExclusionMode.Ignore
  exclusiveZone: s.autoHide === "never" ? thickness + margin : 0

  mask: Region {
    item: win.revealed ? hitBox : revealStrip
    Region { item: popupHit }
  }

  // ---------------------------------------------------------------- apps
  readonly property var hyprMonitor: Hyprland.monitorFor(win.screen)
  readonly property int workspaceId: hyprMonitor && hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1
  readonly property var apps: dock.appsFor(String(win.screen ? win.screen.name : ""), workspaceId)
  property var appsByKey: ({})

  ListModel { id: appsModel }

  onAppsChanged: syncModel()
  Component.onCompleted: syncModel()

  function targetItems() {
    var out = []
    if (s.showLauncher) out.push({ key: "__launcher__", kind: "launcher" })
    if (s.showNewWorkspace) out.push({ key: "__newworkspace__", kind: "newworkspace" })
    var pinnedCount = 0
    for (var i = 0; i < apps.length; i++) if (apps[i].pinned) pinnedCount++
    for (var j = 0; j < apps.length; j++) {
      if (j === pinnedCount && pinnedCount > 0) out.push({ key: "__separator__", kind: "separator" })
      out.push({ key: apps[j].key, kind: "app" })
    }
    return out
  }

  // Diff the model instead of replacing it, so delegates (and a drag in
  // progress) survive window-list updates.
  function syncModel() {
    var map = {}
    for (var a = 0; a < apps.length; a++) map[apps[a].key] = apps[a]
    appsByKey = map
    if (dragKey !== "") { syncPending = true; return }

    var target = targetItems()
    var wanted = {}
    for (var t = 0; t < target.length; t++) wanted[target[t].key] = true
    for (var r = appsModel.count - 1; r >= 0; r--)
      if (!wanted[appsModel.get(r).key]) appsModel.remove(r)
    for (var i = 0; i < target.length; i++) {
      var found = -1
      for (var k = i; k < appsModel.count; k++) if (appsModel.get(k).key === target[i].key) { found = k; break }
      if (found === -1) appsModel.insert(i, target[i])
      else if (found !== i) appsModel.move(found, i, 1)
    }
    recomputeBase()
  }

  property bool syncPending: false
  property var baseCenters: []
  property real baseRowLength: 0

  function recomputeBase() {
    var centers = []
    var pos = 0
    for (var i = 0; i < appsModel.count; i++) {
      var len = appsModel.get(i).kind === "separator" ? sepLen : tileBase
      centers.push(pos + len / 2)
      pos += len + (i < appsModel.count - 1 ? itemGap : 0)
    }
    baseCenters = centers
    baseRowLength = pos
  }

  onTileBaseChanged: recomputeBase()
  onItemGapChanged: recomputeBase()

  // --------------------------------------------------------- magnification
  property real hoverBase: -1
  readonly property bool magnifying: s.magnification && hoverBase >= 0 && popupMode === "" && dragKey === ""

  function magnifyFor(index, kind) {
    if (!magnifying || kind === "separator" || index < 0 || index >= baseCenters.length) return 1
    var d = Math.abs(hoverBase - baseCenters[index])
    var range = tileBase * 2.6
    if (d >= range) return 1
    return 1 + (zoomPeak - 1) * (Math.cos(Math.PI * d / range) + 1) / 2
  }

  function updateHover(p) {
    var inside = p.x >= hitBox.x && p.x <= hitBox.x + hitBox.width
      && p.y >= hitBox.y && p.y <= hitBox.y + hitBox.height
    if (!inside || !revealed) { hoverBase = -1; return }
    var along = vertical ? p.y - row.y : p.x - row.x
    var magLen = vertical ? row.height : row.width
    if (magLen <= 0) { hoverBase = -1; return }
    // Map the pointer back into unmagnified coordinates so zoom doesn't feed
    // back into itself as the row grows.
    hoverBase = Util.clamp(along * baseRowLength / magLen, -tileBase, baseRowLength + tileBase)
  }

  // -------------------------------------------------------------- hiding
  property bool pointerInside: false
  property bool peeking: false
  readonly property bool overlapped: {
    if (s.autoHide !== "smart" || !win.screen) return false
    var ws = workspaceId
    var r = restRect()
    var gx = win.screen.x + (position === "right" ? win.screen.width - win.width : 0) + r.x
    var gy = win.screen.y + win.screen.height - win.height + r.y
    var rect = { x: gx, y: gy, w: r.w, h: r.h }
    var list = dock.clients
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (c.workspaceId !== ws) continue
      if (c.fullscreen) return true
      if (Model.rectsOverlap(rect, { x: c.at[0], y: c.at[1], w: c.size[0], h: c.size[1] })) return true
    }
    return false
  }
  readonly property bool revealed: s.autoHide === "never" || pointerInside || peeking
    || popupMode !== "" || dragKey !== "" || (s.autoHide === "smart" && !overlapped)

  property real hideOffset: revealed ? 0 : thickness + margin + 2
  Behavior on hideOffset { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

  Timer {
    id: leaveTimer
    interval: 450
    onTriggered: win.pointerInside = false
  }

  Timer {
    id: peekTimer
    interval: 2500
    onTriggered: win.peeking = false
  }

  Connections {
    target: win.dock
    function onPeekSerialChanged() { win.peeking = true; peekTimer.restart() }
    function onPopupRequested(mode, appKey) {
      if (mode === "") { win.closePopup(); return }
      if (!win.hyprMonitor || !win.hyprMonitor.focused) return
      if (mode === "settings") { win.openPopup("settings", null); return }
      for (var i = 0; i < row.children.length; i++) {
        var t = row.children[i]
        if (t.key === appKey && t.kind === "app") { win.openPopup(mode, t); return }
      }
    }
  }

  // Dock rectangle at rest (not hidden, not magnified), window-local.
  function restRect() {
    var len = baseRowLength + dockPad * 2
    if (position === "bottom") return { x: (win.width - len) / 2, y: win.height - margin - thickness, w: len, h: thickness }
    if (position === "left") return { x: margin, y: (win.height - len) / 2, w: thickness, h: len }
    return { x: win.width - margin - thickness, y: (win.height - len) / 2, w: thickness, h: len }
  }

  // --------------------------------------------------------------- stage
  Item {
    id: stage
    anchors.fill: parent

    HoverHandler {
      id: hover
      onHoveredChanged: {
        if (hovered) { leaveTimer.stop(); win.pointerInside = true }
        else { win.hoverBase = -1; leaveTimer.restart() }
      }
      onPointChanged: win.updateHover(point.position)
    }

    // Input regions.
    Item {
      id: hitBox
      readonly property real outer: win.position === "bottom" ? Math.min(dockBg.y, row.y)
        : (win.position === "left" ? Math.max(dockBg.x + dockBg.width, row.x + row.width) : Math.min(dockBg.x, row.x))
      x: win.position === "bottom" ? dockBg.x : (win.position === "left" ? 0 : outer)
      y: win.position === "bottom" ? outer : dockBg.y
      width: win.position === "bottom" ? dockBg.width : (win.position === "left" ? outer : win.width - outer)
      height: win.position === "bottom" ? win.height - outer : dockBg.height
    }

    Item {
      id: revealStrip
      readonly property var rest: win.restRect()
      readonly property int strip: 3
      x: win.position === "bottom" ? rest.x : (win.position === "left" ? 0 : win.width - strip)
      y: win.position === "bottom" ? win.height - strip : rest.y
      width: win.position === "bottom" ? rest.w : strip
      height: win.position === "bottom" ? strip : rest.h
    }

    Item {
      id: popupHit
      x: popupCard.x
      y: popupCard.y
      width: win.popupMode !== "" ? popupCard.width : 0
      height: win.popupMode !== "" ? popupCard.height : 0
    }

    // Dock background.
    BorderSurface {
      id: dockBg
      readonly property var rest: win.restRect()
      readonly property real length: (win.vertical ? row.height : row.width) + win.dockPad * 2
      width: win.vertical ? win.thickness : length
      height: win.vertical ? length : win.thickness
      x: win.position === "bottom" ? (win.width - width) / 2
        : (win.position === "left" ? win.margin - win.hideOffset : win.width - win.margin - width + win.hideOffset)
      y: win.position === "bottom" ? win.height - win.margin - height + win.hideOffset : (win.height - height) / 2
      radius: win.radius
      color: Util.alpha(Color.bar.background, win.s.opacity)
      borderSpec: win.s.border
        ? Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(1)))
        : Border.none()
      opacity: win.hideOffset > win.thickness ? 0 : 1
      Behavior on opacity { NumberAnimation { duration: 160 } }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: win.openPopup("settings", null)
      }
    }

    // Icons. Tiles hug the screen-side edge and grow outward when zoomed.
    Grid {
      id: row
      columns: win.vertical ? 1 : Math.max(1, appsModel.count)
      spacing: win.itemGap
      verticalItemAlignment: Grid.AlignBottom
      horizontalItemAlignment: win.position === "left" ? Grid.AlignLeft
        : (win.position === "right" ? Grid.AlignRight : Grid.AlignHCenter)
      x: win.position === "bottom" ? dockBg.x + win.dockPad
        : (win.position === "left" ? dockBg.x + win.dockPad : dockBg.x + dockBg.width - win.dockPad - width)
      y: win.position === "bottom" ? dockBg.y + dockBg.height - win.dockPad - height : dockBg.y + win.dockPad
      opacity: dockBg.opacity

      Repeater {
        model: appsModel
        delegate: DockItem {
          host: win
        }
      }
    }

    // Tooltip label for the hovered icon.
    BorderSurface {
      id: tooltip
      readonly property var tile: win.hoveredTile
      readonly property bool shown: tile !== null && tile.kind !== "separator" && win.popupMode === ""
        && win.dragKey === "" && win.revealed
      readonly property var anchorPoint: {
        var t = tile
        if (!t) return Qt.point(0, 0)
        var deps = [t.x, t.y, t.width, t.height, row.x, row.y, row.width, row.height]
        return t.mapToItem(stage, t.width / 2, t.height / 2)
      }
      readonly property real tileHalf: tile ? (win.vertical ? tile.width : tile.height) / 2 : 0
      visible: shown && tipText.text.length > 0
      width: tipText.implicitWidth + Style.space(10) * 2
      height: tipText.implicitHeight + Style.space(5) * 2
      x: win.position === "bottom" ? Util.clamp(anchorPoint.x - width / 2, 4, win.width - width - 4)
        : (win.position === "left" ? anchorPoint.x + tileHalf + Style.space(8) : anchorPoint.x - tileHalf - Style.space(8) - width)
      y: win.position === "bottom" ? anchorPoint.y - tileHalf - Style.space(8) - height
        : Util.clamp(anchorPoint.y - height / 2, 4, win.height - height - 4)
      radius: Style.cornerRadius
      color: Color.tooltip.background
      borderSpec: Border.localOrSurfaceSpec("tooltip", "border", Color.tooltip.border, Color.tooltip.border, 1)

      Text {
        id: tipText
        anchors.centerIn: parent
        color: Color.tooltip.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: {
          var t = tooltip.tile
          if (!t) return ""
          if (t.kind === "launcher") return "Applications"
          if (t.kind === "newworkspace") return "New workspace"
          var app = t.app
          if (!app) return ""
          var n = app.windows.length
          return n > 1 ? app.name + "  ·  " + n + " windows" : app.name
        }
      }
    }

    // Popups: window picker, app menu, dock settings.
    BorderSurface {
      id: popupCard
      visible: win.popupMode !== ""
      focus: visible
      readonly property int pad: Style.spacing.popupPadding
      width: popupLoader.item ? popupLoader.item.width + pad * 2 : 0
      height: popupLoader.item ? popupLoader.item.height + pad * 2 : 0
      x: win.position === "bottom" ? Util.clamp(win.popupAnchor.x - width / 2, 8, win.width - width - 8)
        : (win.position === "left" ? dockBg.x + dockBg.width + win.popupGap : dockBg.x - win.popupGap - width)
      y: win.position === "bottom" ? dockBg.y - win.popupGap - height
        : Util.clamp(win.popupAnchor.y - height / 2, 8, win.height - height - 8)
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
      Keys.onEscapePressed: win.closePopup()

      Loader {
        id: popupLoader
        x: popupCard.pad
        y: popupCard.pad
        sourceComponent: win.popupMode === "picker" ? pickerComponent
          : (win.popupMode === "menu" ? menuComponent : (win.popupMode === "settings" ? settingsComponent : null))
      }
    }
  }

  HyprlandFocusGrab {
    windows: [win]
    active: win.popupMode !== ""
    onCleared: win.closePopup()
  }

  // --------------------------------------------------------------- state
  property var hoveredTile: null
  property string dragKey: ""
  property string popupMode: ""
  property string popupKey: ""
  property point popupAnchor: Qt.point(0, 0)
  readonly property var popupApp: popupKey !== "" ? (appsByKey[popupKey] || null) : null

  onPopupAppChanged: {
    // The app went away (last window closed and not pinned).
    if (popupMode !== "" && popupMode !== "settings" && popupApp === null) closePopup()
  }

  function openPopup(mode, tile) {
    hoverBase = -1
    popupKey = tile && tile.app ? tile.app.key : ""
    if (tile) {
      popupAnchor = tile.mapToItem(stage, tile.width / 2, tile.height / 2)
    } else {
      var r = restRect()
      popupAnchor = Qt.point(r.x + r.w / 2, r.y + r.h / 2)
    }
    if (mode === "picker") Hyprland.refreshToplevels()
    popupMode = mode
    popupCard.forceActiveFocus()
  }

  function closePopup() {
    popupMode = ""
    popupKey = ""
  }

  // ------------------------------------------------------------- actions
  function activate(tile, button) {
    if (tile.kind === "launcher" || tile.kind === "newworkspace") {
      if (button === Qt.RightButton) openPopup("settings", null)
      else if (tile.kind === "launcher") dock.openAppGrid()
      else dock.newWorkspace(win.screen ? win.screen.name : "")
      return
    }
    var app = tile.app
    if (!app) return
    if (button === Qt.RightButton) { openPopup("menu", tile); return }
    if (button === Qt.MiddleButton) { if (app.canLaunch) dock.launch(app.entryId); return }
    if (app.windows.length === 0) {
      if (app.canLaunch) dock.launch(app.entryId)
    } else if (app.windows.length === 1) {
      dock.focusWindow(app.windows[0].address)
    } else {
      if (popupMode === "picker" && popupKey === app.key) closePopup()
      else openPopup("picker", tile)
    }
  }

  function beginDrag(tile) {
    dragKey = tile.key
    hoverBase = -1
  }

  function dragMove(tile, mouse) {
    var p = tile.mapToItem(row, mouse.x, mouse.y)
    var target = row.childAt(p.x, p.y)
    if (!target || target === tile || target.kind !== "app" || !target.app || !target.app.pinned) return
    if (target.index < 0 || tile.index < 0) return
    appsModel.move(tile.index, target.index, 1)
    recomputeBase()
  }

  function endDrag() {
    var order = []
    for (var i = 0; i < appsModel.count; i++) {
      var it = appsModel.get(i)
      var app = appsByKey[it.key]
      if (it.kind === "app" && app && app.pinned) order.push(it.key)
    }
    // Keep pinned ids that this dock doesn't show (e.g. uninstalled apps).
    var all = s.pinned.slice()
    for (var j = 0; j < all.length; j++) if (order.indexOf(all[j]) === -1) order.push(all[j])
    dragKey = ""
    if (JSON.stringify(order) !== JSON.stringify(s.pinned)) dock.setPinned(order)
    if (syncPending) { syncPending = false; syncModel() }
  }

  // ------------------------------------------------------ popup contents

  component MenuRow: Item {
    id: menuRow
    property string label: ""
    property string glyph: ""
    property string hint: ""
    property bool emphasized: false
    signal triggered()
    implicitWidth: rowGlyph.implicitWidth + rowLabel.implicitWidth + rowHint.implicitWidth + Style.space(12) * 2 + Style.space(10) * 2
    implicitHeight: Style.spacing.popupRowHeight + Style.space(2)
    width: parent ? parent.width : implicitWidth

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowMouse.pressed ? Style.pressedFill : (rowMouse.containsMouse ? Style.hoverFill : "transparent")
    }
    Text {
      id: rowGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: menuRow.glyph ? Style.font.icon + Style.space(4) : 0
      text: menuRow.glyph
      color: menuRow.emphasized ? Color.accent : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.icon
    }
    Text {
      id: rowLabel
      anchors.left: rowGlyph.right
      anchors.leftMargin: menuRow.glyph ? Style.space(8) : 0
      anchors.right: rowHint.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: menuRow.label
      elide: Text.ElideRight
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: menuRow.emphasized
    }
    Text {
      id: rowHint
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: menuRow.hint
      color: Util.alpha(Color.popups.text, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: menuRow.triggered()
    }
  }

  component SettingRow: Row {
    property string label: ""
    property int labelW: Style.space(120)
    property int controlW: Style.space(230)
    default property alias control: holder.data
    spacing: Style.space(12)
    Text {
      width: parent.labelW
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Item {
      id: holder
      width: parent.controlW
      height: childrenRect.height
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component Divider: Rectangle {
    width: parent ? parent.width : 0
    height: 1
    color: Util.alpha(Color.popups.text, 0.15)
  }

  component SectionTitle: Text {
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.subtitle
    font.bold: true
    elide: Text.ElideRight
  }

  // Window picker: one card per window with a live preview.
  Component {
    id: pickerComponent

    Column {
      id: picker
      readonly property var app: win.popupApp
      readonly property int thumbW: Math.round(Math.max(180, win.iconSize * 4.6))
      readonly property int thumbH: Math.round(thumbW * 9 / 16)
      spacing: Style.space(10)

      SectionTitle {
        text: picker.app ? picker.app.name : ""
        width: Math.min(implicitWidth, cards.implicitWidth)
      }

      Grid {
        id: cards
        columns: win.vertical ? 1 : Math.min(4, picker.app ? Math.max(1, picker.app.windows.length) : 1)
        spacing: Style.space(10)

        Repeater {
          model: picker.app ? picker.app.windows : []

          delegate: Item {
            id: card
            required property var modelData
            readonly property bool isActive: modelData.address === win.dock.activeAddress
            readonly property var toplevel: win.s.previews ? win.dock.toplevelFor(modelData.address) : null
            width: picker.thumbW + Style.space(8) * 2
            height: picker.thumbH + titleRow.height + Style.space(8) * 3

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: cardMouse.pressed ? Style.pressedFill : (cardMouse.containsMouse ? Style.hoverFill : Style.normalFill)
              border.width: card.isActive ? Math.max(1, Style.space(2)) : 1
              border.color: card.isActive ? Color.accent : Style.normalBorderColor
            }

            Item {
              id: thumb
              x: Style.space(8)
              y: Style.space(8)
              width: picker.thumbW
              height: picker.thumbH
              clip: true

              ScreencopyView {
                id: preview
                anchors.centerIn: parent
                width: implicitWidth > 0 ? implicitWidth : parent.width
                height: implicitHeight > 0 ? implicitHeight : parent.height
                captureSource: card.toplevel
                live: win.popupMode === "picker"
                constraintSize: Qt.size(picker.thumbW, picker.thumbH)
                visible: hasContent
              }

              IconImage {
                anchors.centerIn: parent
                visible: !preview.hasContent
                implicitSize: Math.round(picker.thumbH * 0.5)
                source: picker.app ? picker.app.icon : ""
                asynchronous: true
              }
            }

            Row {
              id: titleRow
              x: Style.space(8)
              anchors.top: thumb.bottom
              anchors.topMargin: Style.space(8)
              width: picker.thumbW
              spacing: Style.space(6)

              Rectangle {
                id: wsBadge
                height: wsText.implicitHeight + Style.space(2) * 2
                width: Math.max(height, wsText.implicitWidth + Style.space(5) * 2)
                radius: Style.cornerRadius
                color: card.isActive ? Color.accent : Util.alpha(Color.popups.text, 0.14)
                Text {
                  id: wsText
                  anchors.centerIn: parent
                  text: card.modelData.workspaceId < 0 ? "S" : card.modelData.workspaceName
                  color: card.isActive ? Color.popups.background : Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Text {
                width: parent.width - wsBadge.width - parent.spacing
                anchors.verticalCenter: wsBadge.verticalCenter
                text: card.modelData.title
                elide: Text.ElideRight
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: cardMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              cursorShape: Qt.PointingHandCursor
              onClicked: function(mouse) {
                if (mouse.button === Qt.MiddleButton) {
                  win.dock.closeWindow(card.modelData.address)
                } else {
                  win.dock.focusWindow(card.modelData.address)
                  win.closePopup()
                }
              }
            }

            // Close button, shown on hover.
            Rectangle {
              visible: cardMouse.containsMouse || closeMouse.containsMouse
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(4)
              width: Math.round(Style.font.icon * 1.7)
              height: width
              radius: Style.cornerRadius > 0 ? width / 2 : 0
              color: closeMouse.containsMouse ? Color.urgent : Util.alpha(Color.popups.background, 0.85)
              border.width: 1
              border.color: Util.alpha(Color.popups.text, 0.2)
              Text {
                anchors.centerIn: parent
                text: "󰅖"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
              }
              MouseArea {
                id: closeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: win.dock.closeWindow(card.modelData.address)
              }
            }
          }
        }
      }
    }
  }

  // Right-click menu for an app.
  Component {
    id: menuComponent

    Column {
      id: menu
      readonly property var app: win.popupApp
      readonly property var entry: app && app.entryId ? win.dock.entryById(app.entryId) : null
      readonly property var actions: entry && entry.actions ? entry.actions : []
      width: Math.max(Style.space(240), Math.min(Style.space(380), widest))
      property real widest: 0
      spacing: Style.space(2)

      function measure() {
        var w = 0
        for (var i = 0; i < children.length; i++) {
          var c = children[i]
          if (c.implicitWidth !== undefined && c.visible) w = Math.max(w, c.implicitWidth)
        }
        widest = w
      }
      Component.onCompleted: Qt.callLater(measure)

      SectionTitle {
        text: menu.app ? menu.app.name : ""
        width: menu.width
        bottomPadding: Style.space(6)
      }

      Repeater {
        model: menu.app ? menu.app.windows : []
        delegate: MenuRow {
          required property var modelData
          glyph: modelData.address === win.dock.activeAddress ? "󰄾" : "󰖯"
          emphasized: modelData.address === win.dock.activeAddress
          label: modelData.title
          hint: modelData.workspaceId < 0 ? "special" : "ws " + modelData.workspaceName
          onTriggered: { win.dock.focusWindow(modelData.address); win.closePopup() }
        }
      }

      Divider { visible: menu.app && menu.app.windows.length > 0 }

      MenuRow {
        visible: menu.app && menu.app.canLaunch
        glyph: "󰐕"
        label: menu.app && menu.app.windows.length > 0 ? "New window" : "Open"
        hint: "middle-click"
        onTriggered: { win.dock.launch(menu.app.entryId); win.closePopup() }
      }

      Repeater {
        model: menu.actions
        delegate: MenuRow {
          required property var modelData
          glyph: "󰁔"
          label: String(modelData.name || "")
          onTriggered: { win.dock.runAction(modelData); win.closePopup() }
        }
      }

      MenuRow {
        visible: menu.app && menu.app.canLaunch
        glyph: menu.app && menu.app.pinned ? "󰐄" : "󰐃"
        label: menu.app && menu.app.pinned ? "Unpin from dock" : "Pin to dock"
        onTriggered: {
          if (menu.app.pinned) win.dock.unpin(menu.app.entryId)
          else win.dock.pin(menu.app.entryId)
          win.closePopup()
        }
      }

      MenuRow {
        visible: menu.app && menu.app.windows.length > 0
        glyph: "󰅖"
        label: menu.app && menu.app.windows.length > 1 ? "Close all " + menu.app.windows.length + " windows" : "Close window"
        onTriggered: {
          var list = menu.app.windows
          for (var i = 0; i < list.length; i++) win.dock.closeWindow(list[i].address)
          win.closePopup()
        }
      }

      Divider {}

      MenuRow {
        glyph: "󰒓"
        label: "Dock settings"
        onTriggered: win.openPopup("settings", null)
      }
    }
  }

  // Dock settings.
  Component {
    id: settingsComponent

    Column {
      id: settingsCol
      readonly property int labelW: Style.space(120)
      readonly property int controlW: Style.space(230)
      spacing: Style.space(12)

      SectionTitle { text: "Dock" }

      SettingRow {
        label: "Position"
        ButtonGroup {
          options: [{ value: "left", label: "Left" }, { value: "bottom", label: "Bottom" }, { value: "right", label: "Right" }]
          value: win.s.position
          onChanged: function(v) { win.dock.updateSettings({ position: v }); win.closePopup() }
        }
      }

      SettingRow {
        label: "Auto-hide"
        ButtonGroup {
          options: [
            { value: "never", label: "Off", tooltip: "Always visible, windows make room" },
            { value: "smart", label: "Smart", tooltip: "Hide when a window touches the dock" },
            { value: "always", label: "Always", tooltip: "Show only when the pointer hits the edge" }
          ]
          value: win.s.autoHide
          onChanged: function(v) { win.dock.updateSettings({ autoHide: v }) }
        }
      }

      SettingRow {
        label: "Monitors"
        ButtonGroup {
          options: [
            { value: "all", label: "All" },
            { value: "main", label: "Main", tooltip: "Only on " + win.dock.mainMonitorName },
            { value: "custom", label: "Selected" }
          ]
          value: Array.isArray(win.s.monitors) ? "custom" : win.s.monitors
          onChanged: function(v) { win.dock.setMonitorMode(v) }
        }
      }

      // Main: pick which monitor is main. Selected: toggle monitors on/off.
      SettingRow {
        visible: win.s.monitors !== "all"
        label: win.s.monitors === "main" ? "Main monitor" : "Show on"
        Flow {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: Quickshell.screens
            delegate: Rectangle {
              id: chip
              required property var modelData
              readonly property string name: String(modelData.name)
              readonly property bool selected: win.s.monitors === "main"
                ? name === win.dock.mainMonitorName
                : (Array.isArray(win.s.monitors) && win.s.monitors.indexOf(name) !== -1)
              readonly property bool here: name === String(win.screen ? win.screen.name : "")
              width: chipText.implicitWidth + Style.space(10) * 2
              height: chipText.implicitHeight + Style.space(5) * 2
              radius: Style.cornerRadius
              color: chipMouse.containsMouse ? Style.hoverFill : (selected ? Style.selectedFill : Style.normalFill)
              border.width: 1
              border.color: selected ? Color.accent : Style.normalBorderColor
              Text {
                id: chipText
                anchors.centerIn: parent
                text: chip.name + (chip.here ? " •" : "")
                color: chip.selected ? Color.accent : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: chip.selected
              }
              MouseArea {
                id: chipMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (win.s.monitors === "main") win.dock.updateSettings({ mainMonitor: chip.name })
                  else win.dock.toggleMonitor(chip.name)
                }
              }
              PanelToolTip {
                visible: chipMouse.containsMouse
                text: String(chip.modelData.model || chip.modelData.name) + (chip.here ? " (this monitor)" : "")
              }
            }
          }
        }
      }

      SettingRow {
        label: "Show windows"
        ButtonGroup {
          options: [
            { value: "all", label: "All" },
            { value: "monitor", label: "Monitor" },
            { value: "workspace", label: "Workspace" }
          ]
          value: win.s.windowScope
          onChanged: function(v) { win.dock.updateSettings({ windowScope: v }) }
        }
      }

      SettingRow {
        label: "Icon size  " + sizeSlider.liveValue
        PanelSlider {
          id: sizeSlider
          width: settingsCol.controlW
          minimum: 24
          maximum: 96
          step: 2
          integer: true
          value: win.s.iconSize
          onReleased: function(v) { win.dock.updateSettings({ iconSize: Math.round(v) }) }
        }
      }

      SettingRow {
        label: "Zoom  " + zoomSlider.liveValue.toFixed(1) + "×"
        PanelSlider {
          id: zoomSlider
          width: settingsCol.controlW
          minimum: 1.1
          maximum: 2.2
          step: 0.1
          value: win.s.magnifyScale
          onReleased: function(v) { win.dock.updateSettings({ magnifyScale: Math.round(v * 10) / 10 }) }
        }
      }

      SettingRow {
        label: "Opacity  " + Math.round(opacitySlider.liveValue * 100) + "%"
        PanelSlider {
          id: opacitySlider
          width: settingsCol.controlW
          minimum: 0
          maximum: 1
          step: 0.05
          value: win.s.opacity
          onReleased: function(v) { win.dock.updateSettings({ opacity: Math.round(v * 100) / 100 }) }
        }
      }

      SettingRow {
        label: "Magnification"
        ToggleSwitch {
          checked: win.s.magnification
          onToggled: win.dock.updateSettings({ magnification: !win.s.magnification })
        }
      }

      SettingRow {
        label: "Previews"
        ToggleSwitch {
          checked: win.s.previews
          onToggled: win.dock.updateSettings({ previews: !win.s.previews })
        }
      }

      SettingRow {
        label: "Running apps"
        ToggleSwitch {
          checked: win.s.showRunning
          onToggled: win.dock.updateSettings({ showRunning: !win.s.showRunning })
        }
      }

      SettingRow {
        label: "App grid button"
        ToggleSwitch {
          checked: win.s.showLauncher
          onToggled: win.dock.updateSettings({ showLauncher: !win.s.showLauncher })
        }
      }

      SettingRow {
        label: "New workspace button"
        ToggleSwitch {
          checked: win.s.showNewWorkspace
          onToggled: win.dock.updateSettings({ showNewWorkspace: !win.s.showNewWorkspace })
        }
      }

      SettingRow {
        label: "Border"
        ToggleSwitch {
          checked: win.s.border
          onToggled: win.dock.updateSettings({ border: !win.s.border })
        }
      }
    }
  }
}
