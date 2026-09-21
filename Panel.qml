import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "seb-krz.omarchy-connect"
  ipcTarget: "seb-krz.omarchy-connect"
  // manageIpc off so this panel owns the single IpcHandler the target
  // permits — needed for openSettings below.
  manageIpc: false

  IpcHandler {
    target: "seb-krz.omarchy-connect"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function openSettings() {
      root.open()
      root.settingsOpen = true
    }
    // Same code path as the settings toggle; scriptable for testing.
    function setPairingPopupSuppression(on: bool) {
      root.setSuppressPairingPopup(on)
    }
    // Target of the received-file notification's click. Takes no argument:
    // the folder comes from KDE Connect's own config, never from the wire.
    function openReceivedFolder() {
      if (root.primary && root.svc) root.svc.openReceivedFolder(root.primary.id)
    }
    // Open the primary device's storage in the file manager; scriptable for
    // testing. The device id is resolved here, never taken off the wire.
    function browseFiles() {
      if (root.primary && root.svc) root.svc.openFiles(root.primary.id)
    }
    function setNotifyOnReceive(on: bool) {
      root.setNotifyOnReceive(on)
    }
    // Target of a received-file notification's click. The argument is a slot
    // index this plugin minted, never a name off the wire; the path it maps to
    // is handed to xdg-open as a single argv element.
    function openReceived(slot: string) {
      if (root.svc) root.svc.openReceivedSlot(slot)
    }
  }

  // One service per session, not one per bar. The shell mounts it once
  // (manifest declares the `service` kind) and hands the same instance to
  // every bar widget. Instantiating it here instead gave each of N monitors
  // its own bus monitor, its own snapshot loop, and — once arrivals became
  // announceable — N copies of every notification.
  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName)
    : null

  // Settings live on the bar entry, the service does not see them. Every bar
  // pushes the same values, so this is idempotent.
  function syncServiceSettings() {
    if (!root.svc) return
    root.svc.preferredDeviceId = root.setting("preferredDevice", "")
    root.svc.notifyEnabled = root.notifyOnReceive
    root.svc.urlHandlerEnabled = root.installUrlHandler
  }
  onSvcChanged: root.syncServiceSettings()
  onSettingsChanged: root.syncServiceSettings()
  Component.onCompleted: root.syncServiceSettings()

  // ---- pairing-popup suppression (opt-in, value-preserving) ----
  // KNotification's own pairingRequest popup duplicates the panel's pairing
  // card; an opt-in setting suppresses it via ~/.config/kdeconnect.notifyrc.
  // Contract (marketplace review): the file is written ONLY on the explicit
  // toggle, plus a restore/re-apply pair around widget unload/load while the
  // opt-in stands. The user's pre-existing Action value is saved in plugin
  // settings before overriding and restored exactly on disable; a suppression
  // the user configured themselves is marked preexisting and never modified
  // in either direction.
  readonly property bool suppressPairingPopup: setting("suppressPairingPopup", false) === true
  readonly property var pairPopupSaved: setting("pairPopupSaved", null)
  property bool notifyrcReady: false

  function _notifyrcText() {
    try { return notifyrcFile.text() || "" } catch (e) { return "" }
  }

  function _persistPairPopup(on, saved) {
    var next = {}
    for (var k in root.settings) if (k !== "pairPopupSaved") next[k] = root.settings[k]
    next.suppressPairingPopup = on
    if (saved !== null) next.pairPopupSaved = saved
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function setSuppressPairingPopup(on) {
    var current = _notifyrcText()
    if (on) {
      if (Model.notifyrcPairingPopupSuppressed(current)) {
        // Already suppressed by the user's own config — never touch it.
        _persistPairPopup(true, { preexisting: true })
      } else {
        var orig = Model.notifyrcGetPairingAction(current)
        _persistPairPopup(true, { preexisting: false, action: orig.action })
        notifyrcFile.setText(Model.notifyrcSetPairingAction(current, ""))
      }
    } else {
      var s = pairPopupSaved
      if (s && s.preexisting !== true && Model.notifyrcPairingPopupSuppressed(current))
        notifyrcFile.setText(Model.notifyrcSetPairingAction(current, s.action === undefined ? null : s.action))
      _persistPairPopup(false, null)
    }
  }

  // Re-apply an earlier opt-in after the restore-on-unload below (shell
  // restarts unload and reload the widget). Idempotent; never acts on the
  // default or on a preexisting user suppression.
  function _reapplyPairPopup() {
    if (!suppressPairingPopup) return
    var s = pairPopupSaved
    if (!s || s.preexisting === true) return
    var current = _notifyrcText()
    if (!Model.notifyrcPairingPopupSuppressed(current))
      notifyrcFile.setText(Model.notifyrcSetPairingAction(current, ""))
  }

  FileView {
    id: notifyrcFile
    path: Quickshell.env("HOME") + "/.config/kdeconnect.notifyrc"
    printErrors: false
    atomicWrites: true
    watchChanges: true
    onLoaded: { root.notifyrcReady = true; root._reapplyPairPopup() }
    onLoadFailed: { root.notifyrcReady = true; root._reapplyPairPopup() }
    onFileChanged: reload()
  }

  // Restore the exact saved Action on unload (disable/remove/shell restart),
  // so a departing plugin never leaves pairing requests silently suppressed.
  Component.onDestruction: {
    if (!notifyrcReady || !suppressPairingPopup) return
    var s = pairPopupSaved
    if (!s || s.preexisting === true) return
    var current = _notifyrcText()
    if (Model.notifyrcPairingPopupSuppressed(current))
      notifyrcFile.setText(Model.notifyrcSetPairingAction(current, s.action === undefined ? null : s.action))
  }

  // ---- derived state ----
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family
  // Popup content sits on the panel surface, not the wallpaper, so it takes the
  // theme foreground. barForeground shifts with the wallpaper when the bar is
  // transparent and goes unreadable on the dark panel (issue #1).
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color urgentColor: root.bar ? root.bar.urgent : Color.urgent

  readonly property var primary: svc.primaryDevice
  readonly property bool backendReady: svc.backendState === "ready"
  readonly property bool showPercentage: setting("showPercentage", true) === true
  readonly property var incomingRequest: {
    for (var i = 0; i < svc.devices.length; i++)
      if (svc.devices[i].pairRequestedByPeer) return svc.devices[i]
    return null
  }
  readonly property var outgoingRequest: {
    for (var i = 0; i < svc.devices.length; i++)
      if (svc.devices[i].pairRequested) return svc.devices[i]
    return null
  }
  readonly property int pairedCount: {
    var n = 0
    for (var i = 0; i < svc.devices.length; i++) if (svc.devices[i].paired) n++
    return n
  }

  // ---- bar presentation ----
  readonly property bool primaryConnected: primary !== null && primary.connected
  readonly property bool batteryShown: primaryConnected && primary.battery.available
  readonly property bool wideBar: showPercentage && batteryShown && !button.vertical
  readonly property real openPanelIndicatorWidth: wideBar ? button.glyphPaintedWidth : 0

  readonly property string barText: {
    var glyph = primary ? Model.deviceGlyph(primary.type) : Model.deviceGlyph("")
    if (!wideBar) return glyph
    return glyph + " " + primary.battery.percentage + "%" + (primary.battery.charging ? "\u{f140b}" : "")
  }

  readonly property string barTooltip: {
    if (!backendReady) return "KDE Connect unavailable"
    if (!primary) return "No devices found"
    var lines = [primary.name, Model.statusLine(primary)
      + (batteryShown ? " · " + primary.battery.percentage + "%" : "")]
    if (pairedCount > 1) lines.push(pairedCount + " paired devices")
    return lines.join("\n")
  }

  // ---- actions (capability-driven, user-hideable) ----
  // Every action this plugin can offer; the settings card lists these, the
  // action row shows the intersection with device capabilities and the
  // user's hiddenActions preference.
  // Send File is intentionally absent: a portal file picker can't be driven
  // safely from V1's toolset. Qt's in-process FileDialog loads GTK into the
  // shell process and crashes it (SIGABRT in gvfs/glib); pure busctl can't
  // hold the portal request open (the ephemeral call connection drops
  // immediately, so no Response arrives); and Quickshell exposes no generic
  // D-Bus for a persistent connection. Deferred per DesignDocument.md §17.
  readonly property var allActions: [
    { key: "ring", cap: "ring", icon: "\u{f009e}", label: "Ring" },
    { key: "ping", cap: "ping", icon: "\u{f0361}", label: "Ping" },
    { key: "clipboard", cap: "clipboard", icon: "\u{f014d}", label: "Clipboard" },
    { key: "sharetext", cap: "share", icon: "\u{f048a}", label: "Text", settingsLabel: "Share text" },
    { key: "files", cap: "sftp", icon: "\u{f024b}", label: "Files", settingsLabel: "Browse phone files" }
  ]
  readonly property var hiddenActions: setting("hiddenActions", []) || []

  readonly property var actionDefs: {
    var d = primary
    if (!d || !d.connected || !backendReady) return []
    var list = []
    for (var i = 0; i < allActions.length; i++) {
      var a = allActions[i]
      if (d.caps[a.cap] && hiddenActions.indexOf(a.key) === -1) list.push(a)
    }
    return list
  }

  property bool shareOpen: false
  property bool settingsOpen: false

  // ---- received-file notification ----
  // The announcement itself lives in the service, which exists once; this
  // panel only owns the setting that gates it. See Service.qml.
  readonly property bool notifyOnReceive: setting("notifyOnReceive", true)

  function setNotifyOnReceive(on) {
    root.settings = Object.assign({}, root.settings, { notifyOnReceive: !!on })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ---- kdeconnect:// handler (opt-in, default off) ----
  // The install writes outside the plugin folder (~/.local/bin, a .desktop and
  // a mimeapps default), so it runs only when the user switches this on.
  // Switching it off uninstalls again; the Files action never needs it.
  readonly property bool installUrlHandler: setting("installUrlHandler", false) === true

  function setInstallUrlHandler(on) {
    root.settings = Object.assign({}, root.settings, { installUrlHandler: !!on })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function runAction(key) {
    if (!primary) return
    if (key === "sharetext") {
      shareOpen = !shareOpen
      if (shareOpen) Qt.callLater(function () { shareField.forceActiveFocus() })
      return
    }
    if (key === "ring") svc.ring(primary.id)
    else if (key === "ping") svc.ping(primary.id)
    else if (key === "clipboard") svc.sendClipboard(primary.id)
    else if (key === "files") svc.openFiles(primary.id)
  }

  function sendShareText() {
    var t = shareField.text
    if (!t || !primary) return
    svc.shareText(primary.id, t)
    shareField.text = ""
    shareOpen = false
    keyCatcher.forceActiveFocus()
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function toggleHiddenAction(key) {
    var arr = hiddenActions.slice()
    var i = arr.indexOf(key)
    if (i === -1) arr.push(key)
    else arr.splice(i, 1)
    root.settings = Object.assign({}, root.settings, { hiddenActions: arr })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ---- bar position ----
  readonly property string barSection: {
    var sh = root.bar && root.bar.shell ? root.bar.shell : null
    var cfg = sh ? sh.shellConfig : null
    var layout = cfg && cfg.bar ? cfg.bar.layout : null
    if (!layout) return "center"
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var a = layout[sections[s]] || []
      for (var i = 0; i < a.length; i++)
        if (String((a[i] && a[i].id) || "").indexOf(root.moduleName) === 0) return sections[s]
    }
    return "center"
  }

  function moveToSection(name) {
    if (!root.bar || !root.bar.shell || name === barSection) return
    var moduleId = root.moduleName
    root.bar.shell.mutateShellConfig(function (cfg) {
      if (!cfg.bar) cfg.bar = {}
      if (!cfg.bar.layout) cfg.bar.layout = {}
      var layout = cfg.bar.layout
      var entry = null
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length; s++) {
        var a = layout[sections[s]] || []
        for (var i = 0; i < a.length; i++) {
          if (String((a[i] && a[i].id) || "").indexOf(moduleId) === 0) {
            entry = a[i]
            a.splice(i, 1)
            break
          }
        }
      }
      if (!entry) entry = { id: moduleId }
      if (!layout[name]) layout[name] = []
      layout[name].push(entry)
    })
  }

  readonly property string actionStatusText: {
    var a = svc.action
    if (a.status === "idle") return ""
    var name = ""
    for (var i = 0; i < svc.devices.length; i++)
      if (svc.devices[i].id === a.deviceId) name = svc.devices[i].name
    if (a.status === "running") {
      if (a.kind === "ring") return "Ringing " + name + "…"
      if (a.kind === "ping") return "Pinging " + name + "…"
      if (a.kind === "sharetext") return "Sending text…"
      return "Sending clipboard…"
    }
    if (a.kind === "files-no-sshfs") return "Install sshfs to browse files"
    if (a.status === "failed") return "Action failed"
    if (a.kind === "clipboard") return "Clipboard sent"
    if (a.kind === "sharetext") return "Text sent"
    return "Done"
  }

  function setPreferred(id) {
    root.settings = Object.assign({}, root.settings, { preferredDevice: id })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function copyInstallCommand() {
    Quickshell.execDetached(["wl-copy", "omarchy-pkg-add kdeconnect"])
  }

  // ---- two-step unpair confirmation ----
  property string unpairArmedId: ""
  Timer {
    id: unpairDisarm
    interval: 3000
    onTriggered: root.unpairArmedId = ""
  }
  function requestUnpair(id) {
    if (unpairArmedId === id) {
      unpairArmedId = ""
      unpairDisarm.stop()
      svc.unpair(id)
    } else {
      unpairArmedId = id
      unpairDisarm.restart()
    }
  }

  // ---- keyboard cursor ----
  // Sections in visual order; horizontal groups navigate with left/right,
  // the device list with up/down. Up/down also crosses section boundaries.
  property bool cursorActive: false
  property string focusSection: ""
  property int cursorIndex: 0

  readonly property var navSections: {
    var s = []
    if (incomingRequest) s.push({ name: "pairing", count: 2, horizontal: true })
    if (actionDefs.length > 0) s.push({ name: "actions", count: actionDefs.length, horizontal: true })
    if (backendReady && svc.devices.length > 0) s.push({ name: "devices", count: svc.devices.length, horizontal: false })
    return s
  }

  function _sectionIndex() {
    for (var i = 0; i < navSections.length; i++)
      if (navSections[i].name === focusSection) return i
    return -1
  }

  function moveCursor(dx, dy) {
    if (navSections.length === 0) return
    if (!cursorActive || _sectionIndex() === -1) {
      cursorActive = true
      focusSection = navSections[0].name
      cursorIndex = 0
      return
    }
    var si = _sectionIndex()
    var sec = navSections[si]
    if (sec.horizontal && dx !== 0) {
      cursorIndex = Math.max(0, Math.min(sec.count - 1, cursorIndex + dx))
      return
    }
    var step = dy !== 0 ? dy : (sec.horizontal ? 0 : dx)
    if (step === 0) return
    if (!sec.horizontal) {
      var next = cursorIndex + step
      if (next >= 0 && next < sec.count) { cursorIndex = next; return }
    }
    var nsi = si + (step > 0 ? 1 : -1)
    if (nsi < 0 || nsi >= navSections.length) return
    focusSection = navSections[nsi].name
    cursorIndex = step > 0 ? 0 : navSections[nsi].count - 1
    if (navSections[nsi].horizontal) cursorIndex = 0
  }

  function activateCursor() {
    if (!cursorActive) return
    if (focusSection === "pairing" && incomingRequest) {
      if (cursorIndex === 0) svc.cancelPairing(incomingRequest.id)
      else svc.acceptPairing(incomingRequest.id)
    } else if (focusSection === "actions" && cursorIndex < actionDefs.length) {
      runAction(actionDefs[cursorIndex].key)
    } else if (focusSection === "devices" && cursorIndex < svc.devices.length) {
      var d = svc.devices[cursorIndex]
      if (d.pairable) svc.requestPairing(d.id)
      else if (d.paired) setPreferred(d.id)
    }
  }

  function deleteCursor() {
    if (cursorActive && focusSection === "devices" && cursorIndex < svc.devices.length) {
      var d = svc.devices[cursorIndex]
      if (d.paired) requestUnpair(d.id)
    }
  }

  onOpenedChanged: {
    if (opened) {
      svc.refresh()
      cursorActive = false
      focusSection = ""
      cursorIndex = 0
      unpairArmedId = ""
      shareOpen = false
      settingsOpen = false
    }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    slotSize: Style.bar.iconSlot * (root.wideBar ? 2 : 1)
    active: root.incomingRequest !== null
    dimmed: !root.primaryConnected && root.incomingRequest === null
    tooltipText: root.barTooltip
    onPressed: function (b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: shareField.activeFocus
      onMoveRequested: function (dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerText.implicitHeight, refreshBtn.implicitHeight)

          PanelSectionHeader {
            id: headerText
            text: "OMARCHY CONNECT"
            foreground: root.fg
            fontFamily: root.ff
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          PanelActionButton {
            id: settingsBtn
            iconText: "\u{f0493}"
            tooltipText: "Display settings"
            foreground: root.fg
            fontFamily: root.ff
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.settingsOpen = !root.settingsOpen
          }

          PanelActionButton {
            id: refreshBtn
            iconText: "\u{f0450}"
            tooltipText: "Search for devices"
            foreground: root.fg
            fontFamily: root.ff
            anchors.right: settingsBtn.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            onClicked: svc.rediscover()
          }
        }

        // ---------- incoming pairing request (most prominent) ----------
        Column {
          visible: root.incomingRequest !== null
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "PAIRING REQUEST"
            foreground: root.urgentColor
            fontFamily: root.ff
          }

          Text {
            width: parent.width
            text: root.incomingRequest ? root.incomingRequest.name + " wants to pair." : ""
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Text {
            width: parent.width
            text: "Verify this code on both devices:"
            color: root.fg
            opacity: 0.6
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            text: root.incomingRequest ? Model.formatVerificationKey(root.incomingRequest.verificationKey) : ""
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.display
            font.bold: true
            font.letterSpacing: 2
            horizontalAlignment: Text.AlignHCenter
          }

          Row {
            id: pairingRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: pairingRow.cellWidth
              text: "Reject"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.ff
              bordered: true
              hasCursor: root.cursorActive && root.focusSection === "pairing" && root.cursorIndex === 0
              onClicked: if (root.incomingRequest) svc.cancelPairing(root.incomingRequest.id)
              onHovered: function (h) {
                if (h) { root.cursorActive = true; root.focusSection = "pairing"; root.cursorIndex = 0 }
              }
            }

            Button {
              width: pairingRow.cellWidth
              text: "Accept"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.ff
              bordered: true
              active: true
              hasCursor: root.cursorActive && root.focusSection === "pairing" && root.cursorIndex === 1
              onClicked: if (root.incomingRequest) svc.acceptPairing(root.incomingRequest.id)
              onHovered: function (h) {
                if (h) { root.cursorActive = true; root.focusSection = "pairing"; root.cursorIndex = 1 }
              }
            }
          }

          PanelSeparator { foreground: root.fg }
        }

        // ---------- backend failure states ----------
        Column {
          visible: svc.backendState === "not-installed"
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "KDE Connect is not installed.\n\nOmarchy Connect uses KDE Connect for secure device communication."
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Button {
            width: parent.width
            iconText: "\u{f014d}"
            text: "Copy:  omarchy-pkg-add kdeconnect"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.ff
            bordered: true
            onClicked: root.copyInstallCommand()
          }
        }

        Column {
          visible: svc.backendState === "no-daemon"
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "The KDE Connect daemon is not running."
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Button {
            width: parent.width
            text: "Start KDE Connect"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.ff
            bordered: true
            onClicked: svc.rediscover()
          }
        }

        // ---------- no devices ----------
        Column {
          visible: root.backendReady && svc.devices.length === 0
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "No devices found.\n\nMake sure both devices are on the same network and have KDE Connect open."
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Button {
            width: parent.width
            iconText: "\u{f0450}"
            text: "Scan again"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.ff
            bordered: true
            onClicked: svc.rediscover()
          }

          Text {
            width: parent.width
            text: "KDE Connect discovers devices over TCP/UDP ports 1714–1764; a local firewall can block discovery."
            color: root.fg
            opacity: 0.5
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }

        // ---------- primary device hero ----------
        Item {
          visible: root.primary !== null
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            text: root.primary ? Model.deviceGlyph(root.primary.type) : ""
            color: root.fg
            opacity: root.primaryConnected ? 1.0 : 0.5
            font.family: root.ff
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.primary ? root.primary.name : ""
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.primary ? Model.statusLine(root.primary).toUpperCase() : ""
              color: root.fg
              opacity: 0.6
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            visible: root.batteryShown
            text: root.batteryShown
              ? root.primary.battery.percentage + "%" + (root.primary.battery.charging ? " \u{f140b}" : "")
              : ""
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- battery meter ----------
        Item {
          visible: root.batteryShown
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: meterTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
          }

          Rectangle {
            anchors.left: meterTrack.left
            anchors.verticalCenter: meterTrack.verticalCenter
            height: meterTrack.height
            radius: meterTrack.radius
            color: root.fg
            width: root.batteryShown
              ? Math.max(meterTrack.height, meterTrack.width * root.primary.battery.percentage / 100)
              : 0

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          }
        }

        // ---------- outgoing pairing ----------
        Column {
          visible: root.outgoingRequest !== null
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: root.outgoingRequest ? ("PAIRING WITH " + root.outgoingRequest.name).toUpperCase() : ""
            foreground: root.fg
            fontFamily: root.ff
          }

          Text {
            width: parent.width
            text: "Verify that both devices display:"
            color: root.fg
            opacity: 0.6
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            text: root.outgoingRequest ? Model.formatVerificationKey(root.outgoingRequest.verificationKey) : ""
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.display
            font.bold: true
            font.letterSpacing: 2
            horizontalAlignment: Text.AlignHCenter
          }

          Button {
            width: parent.width
            text: "Cancel"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.ff
            bordered: true
            onClicked: if (root.outgoingRequest) svc.cancelPairing(root.outgoingRequest.id)
          }
        }

        // ---------- actions ----------
        // Up to 3 per row; more actions wrap onto extra rows with equal cell
        // widths instead of squeezing the labels.
        Grid {
          id: actionsRow
          visible: root.actionDefs.length > 0
          width: parent.width
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(6)
          columns: Math.max(1, Math.min(3, root.actionDefs.length))
          readonly property real cellWidth: (width - columnSpacing * (columns - 1)) / columns

          Repeater {
            model: root.actionDefs
            Button {
              required property var modelData
              required property int index
              width: actionsRow.cellWidth
              iconText: modelData.icon
              iconSize: Style.font.title
              text: modelData.label
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.ff
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              hasCursor: root.cursorActive && root.focusSection === "actions" && root.cursorIndex === index
              onClicked: root.runAction(modelData.key)
              onHovered: function (h) {
                if (h) { root.cursorActive = true; root.focusSection = "actions"; root.cursorIndex = index }
              }
            }
          }
        }

        // ---------- share text input ----------
        Row {
          visible: root.shareOpen && root.primaryConnected
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: shareField
            width: parent.width - sendBtn.width - parent.spacing
            placeholderText: "Text or URL to send"
            foreground: root.fg
            font.family: root.ff
            onAccepted: root.sendShareText()
            Keys.onEscapePressed: {
              root.shareOpen = false
              keyCatcher.forceActiveFocus()
            }
          }

          PanelActionButton {
            id: sendBtn
            iconText: "\u{f048a}"
            tooltipText: "Send"
            foreground: root.fg
            fontFamily: root.ff
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.sendShareText()
          }
        }

        Text {
          visible: root.actionStatusText !== ""
          width: parent.width
          text: root.actionStatusText
          color: svc.action.status === "failed" ? root.urgentColor : root.fg
          opacity: svc.action.status === "failed" ? 1.0 : 0.6
          font.family: root.ff
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }

        // ---------- device list ----------
        Column {
          visible: root.backendReady && svc.devices.length > 0
          width: parent.width
          spacing: Style.space(6)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: "DEVICES"
            foreground: root.fg
            fontFamily: root.ff
          }

          Repeater {
            model: svc.devices
            DeviceRow {
              required property var modelData
              required property int index
              dev: modelData
              rowIndex: index
              width: parent.width
            }
          }
        }

        // ---------- display settings ----------
        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(6)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: "DISPLAY"
            foreground: root.fg
            fontFamily: root.ff
          }

          Toggle {
            width: parent.width
            label: "Battery percentage in bar"
            checked: root.showPercentage
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.togglePercentage()
          }

          Repeater {
            model: root.allActions
            Toggle {
              required property var modelData
              width: parent.width
              label: modelData.settingsLabel || modelData.label
              checked: root.hiddenActions.indexOf(modelData.key) === -1
              foreground: root.fg
              fontFamily: root.ff
              onClicked: root.toggleHiddenAction(modelData.key)
            }
          }

          Toggle {
            width: parent.width
            label: "Notify on received file"
            description: "Popup with a thumbnail when a transfer lands"
            checked: root.notifyOnReceive
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.setNotifyOnReceive(!root.notifyOnReceive)
          }

          Toggle {
            width: parent.width
            label: "KDE system pairing popup"
            description: "Off: only this panel shows pairing requests"
            checked: !root.suppressPairingPopup
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.setSuppressPairingPopup(!root.suppressPairingPopup)
          }

          Toggle {
            width: parent.width
            label: "kdeconnect:// link handler"
            description: "Let KDE Connect's Explore button open your file manager"
            checked: root.installUrlHandler
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.setInstallUrlHandler(!root.installUrlHandler)
          }

          PanelSectionHeader {
            text: "BAR POSITION"
            foreground: root.fg
            fontFamily: root.ff
          }

          ButtonGroup {
            options: [
              { value: "left", label: "Left" },
              { value: "center", label: "Center" },
              { value: "right", label: "Right" }
            ]
            value: root.barSection
            foreground: root.fg
            fontFamily: root.ff
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function (value) { root.moveToSection(value) }
          }
        }
      }
    }
  }

  component DeviceRow: CursorSurface {
    id: row
    property var dev
    property int rowIndex

    readonly property bool rowSelected: root.cursorActive && root.focusSection === "devices" && root.cursorIndex === rowIndex
    readonly property bool showUnpair: dev.paired && (rowMouse.containsMouse || rowSelected)
    readonly property bool armed: root.unpairArmedId === dev.id

    hasCursor: rowSelected
    current: dev.id === svc.primaryDeviceId
    foreground: root.fg
    implicitHeight: rowContent.implicitHeight + Style.space(12)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "devices"
        root.cursorIndex = row.rowIndex
      }
      onClicked: {
        if (row.dev.pairable) svc.requestPairing(row.dev.id)
        else if (row.dev.paired) root.setPreferred(row.dev.id)
      }
    }

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: unpairBtn.visible ? unpairBtn.left : parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Text {
        text: Model.deviceGlyph(row.dev.type)
        color: root.fg
        opacity: row.dev.connected ? 1.0 : 0.5
        font.family: root.ff
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        // Untrusted display string: rendered as plain elided text only.
        text: row.dev.name
        color: root.fg
        opacity: row.dev.connected ? 1.0 : 0.7
        font.family: root.ff
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: Math.max(0, rowContent.width - x - statusText.implicitWidth - Style.space(20))
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: statusText
        text: {
          if (row.dev.connected && row.dev.battery.available) return row.dev.battery.percentage + "%"
          if (row.dev.connected) return "Connected"
          if (row.dev.pairable) return "Available"
          return "Offline"
        }
        color: root.fg
        opacity: 0.6
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelActionButton {
      id: unpairBtn
      visible: row.showUnpair
      iconText: row.armed ? "\u{f012c}" : "\u{f0159}"
      tooltipText: row.armed ? "Press again to unpair" : "Unpair"
      foreground: row.armed ? root.urgentColor : root.fg
      hoverColor: root.urgentColor
      fontFamily: root.ff
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.requestUnpair(row.dev.id)
    }
  }
}
