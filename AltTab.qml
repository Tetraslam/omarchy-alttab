// Windows-style Alt+Tab for Omarchy.
//
// Tap Alt+Tab to flip to the previous window without any UI. Hold Alt and a
// centered, frosted panel shows every window as a live thumbnail, in
// most-recently-used order across all workspaces, starting on the previous
// window. Tab / Shift+Tab (Alt still held) and the arrows move the selection;
// letting go of Alt switches. Enter or a click switches too, Esc goes back,
// Delete, a middle click or the X closes a window. The layout is fixed while
// the panel is open, so only the highlight moves.
//
// Speed comes from never starting anything on the hot path:
//   * the overlay surface is mapped the moment Alt+Tab is pressed and only
//     revealed after a short delay, so a quick tap never flashes it while a
//     hold shows a panel whose thumbnails are already streaming;
//   * every window keeps one capture view for its whole life, so opening the
//     panel resumes captures instead of negotiating new ones, and a window
//     that cannot be captured right now (another workspace, scrolled away)
//     still shows the last frame it produced;
//   * recency, icons and window sizes are tracked from compositor events as
//     they happen, never queried when the chord fires.
//
// Input arrives as Hyprland global shortcuts alttab:next, alttab:previous and
// alttab:release (bound by hypr/alttab.lua), keys and the pointer on the
// overlay, and `omarchy-shell alttab <method>`.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons

Item {
  id: root

  // Injected by Omarchy's panel loader.
  property var shell: null
  property var manifest: null

  // "closed"; "pending": chord pressed, surface mapped but not yet shown;
  // "hold": shown while Alt is held; "sticky": shown until Enter, a click or Esc.
  property string phase: "closed"
  property var entries: []
  // key -> index into entries, for the persistent tiles to find their place.
  property var slots: ({})
  property int selectedIndex: -1
  property int hoveredIndex: -1
  property var layout: ({ tiles: [], rows: [], width: 0, height: 0, thumbHeight: 0, pad: 0, header: 0 })
  property var targetScreen: null

  readonly property bool active: phase !== "closed"
  readonly property bool shown: phase === "hold" || phase === "sticky"
  property int revealDelayMs: 80
  // Windows whose last frame is held between openings, by recency. Each is a
  // full-resolution buffer, so older windows reconnect when the panel opens.
  property int warmWindows: 12

  // Fullscreen windows left through the switcher, by address.
  property var parkedFullscreen: ({})

  function normalize(address) {
    var text = String(address || "").toLowerCase()
    return text.indexOf("0x") === 0 ? text.slice(2) : text
  }

  // ---------------------------------------------------------------- recency

  property var mru: []

  function touch(key) {
    if (!key) return
    var next = [key]
    for (var i = 0; i < mru.length; i++) if (mru[i] !== key) next.push(mru[i])
    mru = next
  }

  function seedRecency() {
    var toplevels = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var seeded = []
    for (var i = 0; i < toplevels.length; i++) {
      var ipc = toplevels[i].lastIpcObject
      if (ipc && ipc.focusHistoryID !== undefined)
        seeded.push({ key: normalize(toplevels[i].address), rank: Number(ipc.focusHistoryID) })
    }
    if (seeded.length === 0) return false
    seeded.sort(function(a, b) { return a.rank - b.rank })
    var next = mru.slice()
    for (var j = 0; j < seeded.length; j++) if (next.indexOf(seeded[j].key) === -1) next.push(seeded[j].key)
    mru = next
    return true
  }

  Component.onCompleted: {
    Hyprland.refreshToplevels()
    seedTimer.start()
  }

  Timer {
    id: seedTimer
    property int attempts: 0
    interval: 300
    repeat: true
    onTriggered: {
      attempts++
      if (root.seedRecency() || attempts >= 30) stop()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event.name
      if (name === "activewindowv2") {
        var key = root.normalize(String(event.data).split(",")[0])
        root.touch(key)
        // Photograph the window once it has settled on screen; that frame is
        // its preview whenever it can't be captured live.
        stillTimer.key = key
        stillTimer.restart()
      } else if (name === "closewindow") {
        var closed = root.normalize(String(event.data).split(",")[0])
        root.mru = root.mru.filter(function(k) { return k !== closed })
        root.dropEntry(closed)
      } else if (name === "openwindow" || name === "movewindowv2") {
        // Keep window sizes (for tile shapes) fresh without a query at open.
        sizeRefresh.restart()
      }
    }
  }

  Timer {
    id: sizeRefresh
    interval: 250
    onTriggered: if (root.phase === "closed") Hyprland.refreshToplevels()
  }

  // ---------------------------------------------------------------- windows

  property var iconCache: ({})

  function iconFor(appId) {
    if (appId in iconCache) return iconCache[appId]
    var name = ""
    try {
      var entry = DesktopEntries.heuristicLookup(appId)
      if (entry && entry.icon) name = String(entry.icon)
    } catch (error) {}
    var path = Quickshell.iconPath(name || appId, "application-x-executable")
    iconCache[appId] = path
    return path
  }

  function appIdFor(toplevel) {
    var w = toplevel.wayland
    if (w && w.appId) return String(w.appId)
    var ipc = toplevel.lastIpcObject
    return ipc && ipc["class"] ? String(ipc["class"]) : ""
  }

  // Capture views register here so stills and aspect ratios can find them.
  property var views: ({})

  function snapshot() {
    var toplevels = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var rank = {}
    for (var j = 0; j < mru.length; j++) rank[mru[j]] = j
    var list = []
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t || !t.wayland) continue
      var key = normalize(t.address)
      var ipc = t.lastIpcObject || {}
      var aspect = 1.6
      var view = views[key]
      if (view && view.sourceSize.width > 0 && view.sourceSize.height > 0) aspect = view.sourceSize.width / view.sourceSize.height
      else if (ipc.size && ipc.size.length === 2 && ipc.size[1] > 0) aspect = ipc.size[0] / ipc.size[1]
      list.push({ key: key, aspect: aspect, rank: key in rank ? rank[key] : 1e6 + i })
    }
    list.sort(function(a, b) { return a.rank - b.rank })
    return list
  }

  // ----------------------------------------------------------------- layout
  //
  // Tiles share one thumbnail height and keep their window's shape, flow into
  // centered rows, and shrink together until everything fits the screen.

  function computeLayout(list, maxWidth, maxHeight) {
    var pad = Style.space(8)
    var gap = Style.space(10)
    var header = Style.space(26)
    var best = null
    for (var thumb = Style.space(170); thumb >= Style.space(60); thumb -= Style.space(10)) {
      var rows = [[]]
      var rowWidth = 0
      var widths = []
      for (var i = 0; i < list.length; i++) {
        var w = Math.round(Math.max(thumb * 0.7, Math.min(thumb * 2.0, thumb * list[i].aspect))) + pad * 2
        widths.push(w)
        var last = rows[rows.length - 1]
        var needed = last.length === 0 ? w : rowWidth + gap + w
        if (needed > maxWidth && last.length > 0) {
          rows.push([i])
          rowWidth = w
        } else {
          last.push(i)
          rowWidth = needed
        }
      }
      var tileHeight = header + thumb + pad * 2
      var height = rows.length * tileHeight + (rows.length - 1) * gap
      best = { rows: rows, widths: widths, tileHeight: tileHeight, thumb: thumb, height: height, gap: gap }
      if (height <= maxHeight) break
    }

    var tiles = []
    var width = 0
    var rowWidths = []
    for (var r = 0; r < best.rows.length; r++) {
      var total = 0
      for (var k = 0; k < best.rows[r].length; k++) total += best.widths[best.rows[r][k]] + (k > 0 ? best.gap : 0)
      rowWidths.push(total)
      width = Math.max(width, total)
    }
    for (var row = 0; row < best.rows.length; row++) {
      var x = (width - rowWidths[row]) / 2
      for (var m = 0; m < best.rows[row].length; m++) {
        var index = best.rows[row][m]
        tiles[index] = { x: x, y: row * (best.tileHeight + best.gap), w: best.widths[index], h: best.tileHeight, row: row }
        x += best.widths[index] + best.gap
      }
    }
    return { tiles: tiles, rows: best.rows, width: width, height: best.height, thumbHeight: best.thumb, pad: pad, header: header }
  }

  function relayout() {
    var screen = targetScreen
    var maxWidth = (screen ? screen.width : 1600) * 0.88 - Style.space(48)
    var maxHeight = (screen ? screen.height : 1000) * 0.8 - Style.space(48)
    layout = computeLayout(entries, maxWidth, maxHeight)
    var next = {}
    for (var i = 0; i < entries.length; i++) next[entries[i].key] = i
    slots = next
  }

  // ------------------------------------------------------------------- flow

  function screenForFocusedMonitor() {
    var name = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i] && String(screens[i].name || "") === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function begin(direction, sticky) {
    stillTimer.stop()
    var list = snapshot()
    if (list.length === 0) return false
    entries = list
    targetScreen = screenForFocusedMonitor()
    relayout()
    selectedIndex = list.length === 1 ? 0 : (direction < 0 ? list.length - 1 : 1)
    hoveredIndex = -1
    if (sticky) phase = "sticky"
    else {
      phase = "pending"
      revealTimer.restart()
    }
    return true
  }

  function step(direction) {
    if (phase === "closed") return begin(direction, false)
    if (entries.length === 0) return false
    selectedIndex = (selectedIndex + direction + entries.length) % entries.length
    return true
  }

  function moveVertical(direction) {
    var tiles = layout.tiles
    var current = tiles[selectedIndex]
    if (!current) return
    var targetRow = current.row + direction
    if (targetRow < 0 || targetRow >= layout.rows.length) return
    var center = current.x + current.w / 2
    var row = layout.rows[targetRow]
    var best = row[0]
    var bestDistance = 1e9
    for (var i = 0; i < row.length; i++) {
      var t = tiles[row[i]]
      var d = Math.abs(t.x + t.w / 2 - center)
      if (d < bestDistance) { bestDistance = d; best = row[i] }
    }
    selectedIndex = best
  }

  function commit(index) {
    var entry = index >= 0 && index < entries.length ? entries[index] : null
    finish()
    if (!entry) return
    var active = Hyprland.activeToplevel
    if (active && normalize(active.address) === entry.key) return
    parkFullscreen(active)
    Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + entry.key + '" })')
    unparkFullscreen(entry.key)
  }

  function cancel() { finish() }

  function finish() {
    revealTimer.stop()
    phase = "closed"
    hoveredIndex = -1
  }

  // A game left fullscreen keeps believing it is fullscreen (client state)
  // while the compositor shows it windowed, so it doesn't drop resolution or
  // minimize; switching back restores real fullscreen.
  function parkFullscreen(toplevel) {
    if (!toplevel || !toplevel.wayland || !toplevel.wayland.fullscreen) return
    var key = normalize(toplevel.address)
    var parked = parkedFullscreen
    parked[key] = true
    parkedFullscreen = parked
    Hyprland.dispatch('hl.dsp.window.fullscreen_state({ window = "address:0x' + key + '", internal = 0, client = 2 })')
  }

  function unparkFullscreen(key) {
    if (!parkedFullscreen[key]) return
    var parked = parkedFullscreen
    delete parked[key]
    parkedFullscreen = parked
    Hyprland.dispatch('hl.dsp.window.fullscreen_state({ window = "address:0x' + key + '", internal = 2, client = 2 })')
  }

  function closeEntry(index) {
    var entry = entries[index]
    if (entry) Hyprland.dispatch('hl.dsp.window.close({ window = "address:0x' + entry.key + '" })')
  }

  // A window closed while the panel is up leaves it, and the rest reflow.
  function dropEntry(key) {
    if (phase === "closed") return
    var index = key in slots ? slots[key] : -1
    if (index < 0) return
    var next = entries.slice()
    next.splice(index, 1)
    entries = next
    if (entries.length === 0) { finish(); return }
    if (selectedIndex > index || selectedIndex >= entries.length) selectedIndex = Math.max(0, selectedIndex - 1)
    hoveredIndex = -1
    relayout()
  }

  Timer {
    id: revealTimer
    interval: root.revealDelayMs
    onTriggered: if (root.phase === "pending") root.phase = "hold"
  }

  Timer {
    id: stillTimer
    property string key: ""
    interval: 500
    onTriggered: {
      var view = root.views[key]
      if (view && root.phase === "closed") view.captureFrame()
    }
  }

  GlobalShortcut {
    appid: "alttab"
    name: "next"
    description: "Alt+Tab: next window"
    onPressed: root.step(1)
  }

  GlobalShortcut {
    appid: "alttab"
    name: "previous"
    description: "Alt+Tab: previous window"
    onPressed: root.step(-1)
  }

  GlobalShortcut {
    appid: "alttab"
    name: "release"
    description: "Alt+Tab: Alt released"
    onPressed: if (root.phase === "pending" || root.phase === "hold") root.commit(root.selectedIndex)
  }

  IpcHandler {
    target: "alttab"
    function open(): void { if (root.phase === "closed") root.begin(1, true) }
    function next(): void { root.step(1) }
    function previous(): void { root.step(-1) }
    function cancel(): void { root.cancel() }
    function state(): string {
      var tiles = []
      for (var key in root.views) {
        var v = root.views[key]
        tiles.push({ key: key, hasContent: v.hasContent, live: v.live, source: v.sourceSize.width + "x" + v.sourceSize.height })
      }
      return JSON.stringify({ phase: root.phase, mru: root.mru, views: tiles })
    }
  }

  // Omarchy's summon/hide/toggle.
  function open(payloadJson) { if (phase === "closed") begin(1, true) }
  function close() { cancel() }

  // ------------------------------------------------------------------- view

  readonly property color fg: Color.popups.text
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  PanelWindow {
    id: surface
    // Mapped as soon as the chord fires; drawn once revealed.
    visible: root.active
    screen: root.targetScreen
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "alttab"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    // Until revealed the surface takes no pointer input at all.
    mask: Region { item: root.shown ? fullArea : null }

    Item { id: fullArea; anchors.fill: parent }

    MouseArea {
      anchors.fill: parent
      enabled: root.shown
      onClicked: root.cancel()
    }

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        var k = event.key
        if (k === Qt.Key_Escape) root.cancel()
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.commit(root.selectedIndex)
        else if (k === Qt.Key_Backtab || (k === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) root.step(-1)
        else if (k === Qt.Key_Tab || k === Qt.Key_Right) root.step(1)
        else if (k === Qt.Key_Left) root.step(-1)
        else if (k === Qt.Key_Down) root.moveVertical(1)
        else if (k === Qt.Key_Up) root.moveVertical(-1)
        else if (k === Qt.Key_Delete) root.closeEntry(root.selectedIndex)
        else return
        event.accepted = true
      }
    }

    onVisibleChanged: if (visible) keys.forceActiveFocus()

    Rectangle {
      id: panel
      anchors.centerIn: parent
      visible: root.shown
      width: root.layout.width + Style.space(24) * 2
      height: root.layout.height + Style.space(24) * 2
      radius: Style.space(14)
      color: root.alpha(Color.popups.background, 0.86)
      border.width: Math.max(1, Style.space(1))
      border.color: root.alpha(root.fg, 0.10)

      MouseArea { anchors.fill: parent }
    }

    // The tiles live for as long as their windows do, outside the panel so a
    // hidden panel doesn't stop their capture views from updating.
    Item {
      id: grid
      x: panel.x + Style.space(24)
      y: panel.y + Style.space(24)
      width: root.layout.width
      height: root.layout.height
      opacity: root.shown ? 1 : 0

      Repeater {
        model: Hyprland.toplevels

        Tile {
          required property var modelData
          toplevel: modelData
        }
      }
    }
  }

  component Tile: Item {
    id: tile
    property var toplevel: null
    readonly property string key: toplevel ? root.normalize(toplevel.address) : ""
    readonly property int slot: key in root.slots && root.active ? root.slots[key] : -1
    readonly property var geometry: slot >= 0 ? root.layout.tiles[slot] : null
    readonly property bool selected: slot >= 0 && root.selectedIndex === slot
    readonly property bool hovered: slot >= 0 && root.hoveredIndex === slot
    readonly property real pad: root.layout.pad
    readonly property string appId: toplevel ? root.appIdFor(toplevel) : ""
    readonly property string icon: appId ? root.iconFor(appId) : ""
    readonly property bool warm: {
      var rank = root.mru.indexOf(key)
      return rank >= 0 && rank < root.warmWindows
    }

    visible: !!geometry
    x: geometry ? geometry.x : 0
    y: geometry ? geometry.y : 0
    width: geometry ? geometry.w : 0
    height: geometry ? geometry.h : 0

    Rectangle {
      anchors.fill: parent
      radius: Style.space(10)
      color: tile.selected ? root.alpha(root.fg, 0.13) : (tile.hovered ? root.alpha(root.fg, 0.07) : "transparent")
      border.width: tile.selected ? Math.max(2, Style.space(2)) : 0
      border.color: root.alpha(root.fg, 0.85)
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.shown && tile.visible
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      // Hover selects only once the pointer moves: the panel opens under
      // wherever the pointer already was.
      onPositionChanged: root.hoveredIndex = tile.slot
      onExited: if (root.hoveredIndex === tile.slot) root.hoveredIndex = -1
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) root.closeEntry(tile.slot)
        else root.commit(tile.slot)
      }
    }

    Item {
      x: tile.pad
      y: tile.pad
      width: tile.width - tile.pad * 2
      height: root.layout.header

      IconImage {
        id: icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        implicitSize: Style.space(16)
        source: tile.icon
        asynchronous: true
      }

      Text {
        anchors.left: icon.right
        anchors.leftMargin: Style.space(8)
        anchors.right: closeButton.visible ? closeButton.left : parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        text: tile.toplevel ? String(tile.toplevel.title || tile.appId) : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Rectangle {
        id: closeButton
        visible: tile.hovered || tile.selected
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        height: Style.space(22)
        radius: Style.space(6)
        color: closeArea.containsMouse ? Color.urgent : "transparent"

        Text {
          anchors.centerIn: parent
          text: "✕"
          color: closeArea.containsMouse ? Color.background : root.alpha(root.fg, 0.8)
          font.pixelSize: Style.space(12)
        }

        MouseArea {
          id: closeArea
          anchors.fill: parent
          enabled: root.shown
          hoverEnabled: true
          onClicked: root.closeEntry(tile.slot)
        }
      }
    }

    Rectangle {
      id: thumbBox
      x: tile.pad
      y: tile.pad + root.layout.header
      width: Math.max(1, tile.width - tile.pad * 2)
      height: Math.max(1, root.layout.thumbHeight)
      radius: Style.space(6)
      color: root.alpha(root.fg, 0.04)
      clip: true

      ScreencopyView {
        id: capture
        anchors.centerIn: parent
        // Bound for the window's whole life: opening the panel only resumes
        // streaming, and the last frame stays as the preview when no new ones
        // can come (another workspace, scrolled off).
        captureSource: tile.toplevel && (root.active || tile.warm) ? tile.toplevel.wayland : null
        live: root.active
        paintCursor: false
        constraintSize: Qt.size(thumbBox.width, thumbBox.height)
        Component.onCompleted: if (tile.key) root.views[tile.key] = capture
        Component.onDestruction: if (root.views[tile.key] === capture) delete root.views[tile.key]
      }

      IconImage {
        anchors.centerIn: parent
        visible: !capture.hasContent
        implicitSize: Math.min(thumbBox.width, thumbBox.height) * 0.4
        source: tile.icon
        asynchronous: true
      }
    }
  }
}
