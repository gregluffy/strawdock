import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.Commons

// One dock slot: an app icon, the app-grid button, or the separator between
// pinned and running apps.
Item {
  id: tile

  required property int index
  required property string key
  required property string kind
  required property var host

  readonly property var dock: host ? host.dock : null
  readonly property var app: kind === "app" && host ? (host.appsByKey[key] || null) : null
  readonly property bool isSeparator: kind === "separator"
  readonly property bool dragging: host !== null && host.dragKey === key && key !== ""

  // Smoothed zoom factor from the dock's magnification curve.
  property real zoom: host ? host.magnifyFor(index, kind) : 1
  Behavior on zoom { SmoothedAnimation { duration: 90; velocity: -1 } }

  readonly property real size: host ? host.tileBase * zoom : 0
  width: isSeparator ? (host && host.vertical ? host.tileBase : host.sepLen) : size
  height: isSeparator ? (host && host.vertical ? host.sepLen : host.tileBase) : size
  z: dragging ? 10 : 0

  // Bounce while launching or demanding attention.
  property real bounce: 0
  readonly property bool bouncing: app !== null && (app.launching || app.urgent)
  SequentialAnimation {
    running: tile.bouncing
    loops: Animation.Infinite
    NumberAnimation { target: tile; property: "bounce"; to: host ? host.iconSize * 0.32 : 12; duration: 280; easing.type: Easing.OutQuad }
    NumberAnimation { target: tile; property: "bounce"; to: 0; duration: 280; easing.type: Easing.InQuad }
    PauseAnimation { duration: tile.app && tile.app.urgent ? 700 : 120 }
    onRunningChanged: if (!running) tile.bounce = 0
  }

  // Separator.
  Rectangle {
    visible: tile.isSeparator
    anchors.centerIn: parent
    width: host && host.vertical ? parent.width * 0.6 : 1
    height: host && host.vertical ? 1 : parent.height * 0.6
    color: Util.alpha(Color.foreground, 0.25)
  }

  Item {
    id: face
    visible: !tile.isSeparator
    anchors.fill: parent
    opacity: tile.dragging ? 0.65 : 1
    transform: Translate {
      x: host ? host.outX * tile.bounce : 0
      y: host ? host.outY * tile.bounce : 0
    }

    Rectangle {
      anchors.fill: parent
      radius: tile.host ? tile.host.tileRadius : 0
      color: "transparent"
      border.width: tile.dragging ? Math.max(1, Style.space(2)) : 0
      border.color: Color.accent
      Behavior on color { ColorAnimation { duration: 120 } }
    }

    // Hover: a line in the theme's border color on the icon's outer edge
    // (top for a bottom dock), growing out from the middle.
    Rectangle {
      id: hoverLine
      readonly property bool active: mouse.containsMouse && !tile.dragging
      readonly property bool vert: tile.host !== null && tile.host.vertical
      readonly property real thick: Math.max(2, Style.space(2))
      readonly property real full: (vert ? tile.height : tile.width) * (mouse.pressed ? 0.8 : 0.55)
      property real len: active ? full : 0
      Behavior on len { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
      visible: len > 0.5
      width: vert ? thick : len
      height: vert ? len : thick
      x: vert ? (tile.host.position === "left" ? tile.width - thick : 0) : (tile.width - width) / 2
      y: vert ? (tile.height - height) / 2 : 0
      radius: thick / 2
      color: Color.popups.border
    }

    IconImage {
      id: icon
      visible: tile.kind === "app"
      anchors.centerIn: parent
      implicitSize: tile.host ? Math.round(tile.host.iconSize * tile.zoom) : 32
      source: tile.app ? tile.app.icon : ""
      asynchronous: true
      // Launching apps are dimmed until their window shows up.
      opacity: tile.app && tile.app.launching ? 0.6 : 1
    }

    Text {
      visible: tile.kind === "launcher" || tile.kind === "newworkspace"
      anchors.centerIn: parent
      text: tile.kind === "launcher" ? "󰀻" : "󰐕"
      color: mouse.containsMouse ? Color.accent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: tile.host ? Math.round(tile.host.iconSize * 0.62 * tile.zoom) : 24
    }
  }

  // Running indicators, drawn in the dock padding on the screen-edge side:
  // one dot per window (up to three), accent + stretched for the focused app.
  Grid {
    id: dots
    visible: tile.app !== null && tile.app.windows.length > 0
    readonly property int n: tile.app ? Math.min(3, tile.app.windows.length) : 0
    readonly property int dot: tile.host ? Math.max(4, Math.round(tile.host.iconSize * 0.09)) : 4
    readonly property color tint: !tile.app ? "transparent"
      : (tile.app.urgent ? Color.urgent : (tile.app.focused ? Color.accent : Util.alpha(Color.foreground, 0.7)))
    columns: tile.host && tile.host.vertical ? 1 : 3
    spacing: Math.max(2, Math.round(dot * 0.6))
    readonly property real gapToTile: tile.host ? (tile.host.dockPad - dot) / 2 : 0
    x: !tile.host ? 0 : (tile.host.position === "bottom" ? (tile.width - width) / 2
      : (tile.host.position === "left" ? -dot - gapToTile : tile.width + gapToTile))
    y: !tile.host ? 0 : (tile.host.position === "bottom" ? tile.height + gapToTile : (tile.height - height) / 2)

    Repeater {
      model: dots.n
      delegate: Rectangle {
        required property int index
        readonly property bool stretched: tile.app && tile.app.focused && index === 0
        readonly property int longSide: stretched ? dots.dot * 3 : dots.dot
        width: tile.host && tile.host.vertical ? dots.dot : longSide
        height: tile.host && tile.host.vertical ? longSide : dots.dot
        radius: dots.dot / 2
        color: dots.tint
        Behavior on width { NumberAnimation { duration: 150 } }
        Behavior on height { NumberAnimation { duration: 150 } }
      }
    }
  }

  MouseArea {
    id: mouse
    enabled: !tile.isSeparator
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    preventStealing: true

    property point pressPoint: Qt.point(0, 0)
    property bool dragArmed: false
    property bool suppressClick: false
    property real wheelAccumulator: 0

    onEntered: tile.host.hoveredTile = tile
    onExited: if (tile.host.hoveredTile === tile) tile.host.hoveredTile = null
    Component.onDestruction: if (tile.host && tile.host.hoveredTile === tile) tile.host.hoveredTile = null

    onPressed: function(event) {
      pressPoint = Qt.point(event.x, event.y)
      suppressClick = false
      dragArmed = event.button === Qt.LeftButton && tile.app !== null && tile.app.pinned
    }

    onPositionChanged: function(event) {
      if (!pressed || !dragArmed) return
      if (!tile.dragging) {
        if (Math.abs(event.x - pressPoint.x) + Math.abs(event.y - pressPoint.y) < 10) return
        tile.host.beginDrag(tile)
      }
      tile.host.dragMove(tile, event)
    }

    onReleased: function(event) {
      if (tile.dragging) {
        suppressClick = true
        tile.host.endDrag()
      }
      dragArmed = false
    }

    onClicked: function(event) {
      if (suppressClick) { suppressClick = false; return }
      tile.host.activate(tile, event.button)
    }

    onWheel: function(event) {
      if (!tile.app || tile.app.windows.length === 0) return
      var delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
      var r = Util.wheelSteps(wheelAccumulator, delta)
      wheelAccumulator = r.remainder
      if (r.steps !== 0) tile.dock.cycle(tile.app, r.steps > 0 ? -1 : 1)
    }
  }
}
