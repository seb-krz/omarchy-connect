import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns all KDE Connect state: lifecycle, snapshot orchestration, debounced
// event reconciliation, primary-device selection. UI reads properties and
// calls the public methods; it never sees D-Bus output.
Item {
  id: root

  // ---- public state ----
  property bool cliInstalled: false
  // KDE Connect's remote-filesystem plugin needs the sshfs binary; the
  // kdeconnect package ships it only as an optional dependency.
  property bool sshfsInstalled: false
  // Opt-in setting (pushed by the panel): install or remove the
  // kdeconnect:// desktop integration. Off by default, so nothing outside the
  // plugin folder is written until the user asks for it. The Files action
  // below uses the bundled handler directly and does not need this.
  property bool urlHandlerEnabled: false
  property string backendState: Model.BackendState.Unknown
  property bool refreshing: false
  property var devices: []
  property string preferredDeviceId: ""
  property string lastActiveDeviceId: ""
  readonly property string primaryDeviceId: Model.selectPrimaryId(devices, preferredDeviceId, lastActiveDeviceId)
  readonly property var primaryDevice: {
    for (var i = 0; i < devices.length; i++)
      if (devices[i].id === primaryDeviceId) return devices[i]
    return null
  }
  readonly property bool monitorActive: dbus.monitorActive
  property double lastRefreshMs: 0

  signal stateUpdated()
  signal refreshed()
  // A file finished landing on disk. path/name are device-controlled display
  // strings: never executed, never used to build a command.
  signal fileReceived(string path, string name)

  function debugJson() {
    return Model.snapshotSummary(backendState, devices)
  }

  // ---- refresh orchestration ----
  property bool _pendingRefresh: false
  property var _monitorFilter: Model.makeMonitorFilter()

  readonly property var _busctl: ["busctl", "--user", "--timeout=3"]

  function _daemonCall(member, extra) {
    return _busctl.concat(["call", "org.kde.kdeconnect", "/modules/kdeconnect",
      "org.kde.kdeconnect.daemon", member]).concat(extra || []).concat(["--json=short"])
  }

  function _devicePath(id) { return "/modules/kdeconnect/devices/" + id }

  function _getAll(path, iface) {
    return _busctl.concat(["call", "org.kde.kdeconnect", path,
      "org.freedesktop.DBus.Properties", "GetAll", "s", iface, "--json=short"])
  }

  function _deviceCall(id, member, extra) {
    return _busctl.concat(["call", "org.kde.kdeconnect", _devicePath(id),
      "org.kde.kdeconnect.device", member]).concat(extra || []).concat(["--json=short"])
  }

  // KDE Connect opens its own configured destination; nothing is passed in.
  function openReceivedFolder(id) {
    if (!id) return
    dbus.call(_busctl.concat(["call", "org.kde.kdeconnect", _devicePath(id) + "/share",
      "org.kde.kdeconnect.device.share", "openDestinationFolder"]))
  }

  function refresh() {
    if (refreshing) { _pendingRefresh = true; return }
    refreshing = true
    dbus.call(_daemonCall("devices", ["bb", "false", "false"]), function (out) {
      var ids = Model.parseDeviceIds(out)
      if (ids === null) {
        _applyBackendDown()
        return
      }
      _collectDevices(ids, [])
    })
  }

  function _collectDevices(ids, acc) {
    if (ids.length === 0) { _applySnapshot(acc); return }
    var id = ids[0]
    var rest = ids.slice(1)
    dbus.call(_getAll(_devicePath(id), "org.kde.kdeconnect.device"), function (propsOut) {
      var props = Model.parseProperties(propsOut)
      if (props === null) {
        // Device vanished mid-snapshot — skip it, keep the rest.
        _collectDevices(rest, acc)
        return
      }
      dbus.call(_deviceCall(id, "loadedPlugins"), function (loadedOut) {
        var loaded = Model.parseStringList(loadedOut)
        var hasBattery = loaded !== null && loaded.indexOf("kdeconnect_battery") !== -1
        if (!hasBattery) {
          acc.push(Model.normalizeDevice(id, props, loaded, null))
          _collectDevices(rest, acc)
          return
        }
        dbus.call(_getAll(_devicePath(id) + "/battery", "org.kde.kdeconnect.device.battery"), function (batOut) {
          // Battery failure must never fail the device (optional capability).
          acc.push(Model.normalizeDevice(id, props, loaded, Model.parseProperties(batOut)))
          _collectDevices(rest, acc)
        })
      })
    })
  }

  function _applySnapshot(list) {
    var ordered = Model.orderDevices(list)
    // Track "most recently active": a device that just became connected.
    for (var i = 0; i < ordered.length; i++) {
      var now = ordered[i]
      if (!now.connected) continue
      var was = null
      for (var j = 0; j < devices.length; j++)
        if (devices[j].id === now.id) { was = devices[j]; break }
      if (!was || !was.connected) lastActiveDeviceId = now.id
    }
    var changed = !Model.snapshotEquals(ordered, devices)
    if (changed) devices = ordered
    if (backendState !== Model.BackendState.Ready) {
      backendState = Model.BackendState.Ready
      changed = true
    }
    lastRefreshMs = Date.now()
    if (changed) stateUpdated()
    _endRefresh()
  }

  function _applyBackendDown() {
    var next = cliInstalled ? Model.BackendState.NoDaemon : Model.BackendState.NotInstalled
    var changed = backendState !== next || devices.length > 0
    backendState = next
    if (devices.length > 0) devices = []
    if (changed) stateUpdated()
    _endRefresh()
  }

  function _endRefresh() {
    refreshing = false
    refreshed()
    if (_pendingRefresh) {
      _pendingRefresh = false
      Qt.callLater(refresh)
    }
  }

  // ---- actions ----
  // One action at a time; UI shows transient status then auto-clears.
  property var action: ({ kind: "", deviceId: "", status: "idle" })

  function ring(id) { _cliAction("ring", id, ["kdeconnect-cli", "--ring", "--device", id]) }
  function ping(id) { _cliAction("ping", id, ["kdeconnect-cli", "--ping", "--device", id]) }
  function sendClipboard(id) { _cliAction("clipboard", id, ["kdeconnect-cli", "--send-clipboard", "--device", id]) }
  // text is user input passed as a single argv element — never a shell string.
  function shareText(id, text) { _cliAction("sharetext", id, ["kdeconnect-cli", "--share-text", text, "--device", id]) }

  // Open the device's storage in the file manager. This calls the same
  // bundled handler that is registered for the kdeconnect:// scheme, so the
  // panel action and KDE Connect's own "Explore device" button stay in
  // lockstep. The handler resolves the device id over D-Bus — no IP here.
  //
  // sshfs is only an optional dependency and can be installed after the shell
  // has started, so the startup probe is not trusted here: re-check it live on
  // click before deciding whether to open or to ask for it.
  property string _pendingFilesId: ""

  function openFiles(id) {
    if (!id) return
    _pendingFilesId = id
    sshfsProbe.running = true
  }

  function rediscover() {
    dbus.call(_daemonCall("forceOnNetworkChange"), function () { refresh() })
  }

  // Pairing goes straight to the device D-Bus interface.
  function requestPairing(id) { _pairCall(id, "requestPairing") }
  function acceptPairing(id) { _pairCall(id, "acceptPairing") }
  function cancelPairing(id) { _pairCall(id, "cancelPairing") }
  function unpair(id) { _pairCall(id, "unpair") }

  function _pairCall(id, member) {
    dbus.call(_deviceCall(id, member), function () { refresh() })
  }

  function _cliAction(kind, id, argv) {
    if (action.status === "running") return
    action = { kind: kind, deviceId: id, status: "running" }
    actionTimeout.restart()
    actionProc.command = argv
    actionProc.running = true
  }

  Process {
    id: actionProc
    onExited: function (exitCode) {
      actionTimeout.stop()
      root.action = Object.assign({}, root.action, { status: exitCode === 0 ? "success" : "failed" })
      actionClear.restart()
      root.refresh()
    }
  }

  // A hung action is killed rather than leaving a busy UI; kill path flows
  // through onExited with a nonzero code → "failed".
  Timer {
    id: actionTimeout
    interval: 10000
    onTriggered: actionProc.running = false
  }

  Timer {
    id: actionClear
    interval: 2500
    onTriggered: root.action = { kind: "", deviceId: "", status: "idle" }
  }

  // ---- event-driven invalidation ----
  Connections {
    target: dbus
    function onMonitorLine(line) {
      if (root._monitorFilter.feed(line)) debounceTimer.restart()
      var share = root._monitorFilter.takeShare()
      if (share) root.fileReceived(share, Model.baseName(share))
    }
    function onMonitorActiveChanged() {
      // Fresh parser state per monitor process; lines don't span restarts.
      if (dbus.monitorActive) root._monitorFilter = Model.makeMonitorFilter()
    }
  }

  Timer {
    id: debounceTimer
    interval: 200
    onTriggered: root.refresh()
  }

  // Slow reconciliation: recovery only, not normal operation.
  Timer {
    interval: 45000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: whichCli
    command: ["which", "kdeconnect-cli"]
    onExited: function (exitCode) {
      root.cliInstalled = exitCode === 0
      root.refresh()
    }
  }

  Process {
    id: whichSshfs
    command: ["which", "sshfs"]
    onExited: function (exitCode) { root.sshfsInstalled = exitCode === 0 }
  }

  // On-click sshfs check, separate from the startup probe so a click can never
  // race it. If sshfs appeared since startup, the action opens; otherwise the
  // panel reports the missing optional dependency rather than failing silently.
  Process {
    id: sshfsProbe
    command: ["which", "sshfs"]
    onExited: function (exitCode) {
      root.sshfsInstalled = exitCode === 0
      var id = root._pendingFilesId
      root._pendingFilesId = ""
      if (exitCode !== 0) {
        root.action = { kind: "files-no-sshfs", deviceId: id, status: "failed" }
        actionClear.restart()
        return
      }
      if (id) Quickshell.execDetached([integration.handlerPath, "kdeconnect://" + id + "/"])
    }
  }

  // ---- received-file announcement ----
  // KDE Connect never announces a finished incoming transfer on a non-Plasma
  // desktop: notifyrc has no fileReceived event, and the KJob it raises needs
  // KDE's job-tracker protocol, which Quattro does not implement. It also
  // preserves the sender's mtime, so the file does not even sort to the top of
  // the download folder. This service does the announcing — once per session,
  // which is the whole reason it is a service and not per-bar state.
  //
  // The name is device-controlled: it is only ever a single argv element and a
  // display string, never part of a command. The click carries no device data
  // at all — its --exec is a fixed literal plus a slot integer minted here.
  property bool notifyEnabled: true
  readonly property var imageExtensions: ["jpg", "jpeg", "png", "gif", "webp",
    "heic", "heif", "avif", "bmp", "tif", "tiff"]
  readonly property int thumbSlots: 8
  property int thumbSlot: 0
  property var pendingNotify: null
  property var receivedBySlot: ({})
  // Straight into the runtime dir, which always exists and is cleared at
  // logout — no directory to create, and nothing to clean up.
  readonly property string thumbDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"

  function isImageName(name) {
    var i = String(name).lastIndexOf(".")
    if (i === -1) return false
    return root.imageExtensions.indexOf(String(name).substring(i + 1).toLowerCase()) !== -1
  }

  function openReceivedSlot(slot) {
    var n = parseInt(String(slot), 10)
    if (!isFinite(n) || n < 0 || n >= root.thumbSlots) return
    var path = root.receivedBySlot[n]
    if (!path) return
    // gio, not xdg-open: xdg-open silently fails to launch a handler from the
    // shell's context on Quattro (verified against a registered imv.desktop
    // and a name with no spaces). glib is already a hard dependency of
    // kdeconnect, so this adds nothing. The path is one argv element.
    Quickshell.execDetached(["gio", "open", path])
  }

  function sendReceivedNotification(name, image, slot) {
    // 10s: omarchy clamps to min(30000, max(8000, requested)) for normal urgency.
    var argv = ["omarchy-notification-send", "--app-name", "omarchy-connect",
      "-g", "\u{f01da}", "-u", "normal", "-t", "10000"]
    if (image) argv = argv.concat(["--image", image])
    argv = argv.concat(["File received", name])
    // --exec must come last and be given as separate words: the script takes
    // everything after it as the click argv, and the shell runs that argv
    // directly (Util.execArgv, no shell), so the slot integer is one element.
    argv = argv.concat(["--exec", "omarchy-shell", "seb-krz.omarchy-connect"])
    argv = argv.concat(slot >= 0 ? ["openReceived", String(slot)] : ["openReceivedFolder"])
    notifyProc.command = argv
    notifyProc.running = true
  }

  onFileReceived: function (path, name) {
    if (!root.notifyEnabled) return
    root.thumbSlot = (root.thumbSlot + 1) % root.thumbSlots
    var slot = root.thumbSlot
    var map = {}
    for (var k in root.receivedBySlot) map[k] = root.receivedBySlot[k]
    map[slot] = path
    root.receivedBySlot = map

    if (!root.isImageName(name)) {
      root.sendReceivedNotification(name, "", slot)
      return
    }
    // Quattro's Qt build has no HEIF decoder, and phone photos are HEIC, so
    // the popup gets a transcoded thumbnail rather than the original.
    var dst = root.thumbDir + "/omarchy-connect-thumb-" + slot + ".png"
    root.pendingNotify = { name: name, image: dst, slot: slot }
    thumbProc.running = false
    thumbProc.command = ["magick", path + "[0]", "-auto-orient",
      "-thumbnail", "256x256", "-strip", dst]
    thumbProc.running = true
    thumbTimer.restart()
  }

  Process { id: notifyProc }

  Process {
    id: thumbProc
    // Any failure — no ImageMagick, an unreadable file, a multi-frame image
    // that wrote elsewhere — degrades to a notification with no thumbnail.
    onExited: function (exitCode) {
      thumbTimer.stop()
      var p = root.pendingNotify
      root.pendingNotify = null
      if (!p) return
      root.sendReceivedNotification(p.name, exitCode === 0 ? p.image : "", p.slot)
    }
  }

  // A transcode that stalls must not leave the arrival unannounced.
  Timer {
    id: thumbTimer
    interval: 8000
    onTriggered: thumbProc.running = false
  }

  Integration { id: integration }

  // Only an actual setting change — or the first sync after a shell start with
  // the setting already on — installs/uninstalls the integration.
  onUrlHandlerEnabledChanged: {
    if (urlHandlerEnabled) integration.install()
    else integration.uninstall()
  }

  Dbus { id: dbus }

  Component.onCompleted: {
    whichCli.running = true
    whichSshfs.running = true
    dbus.startMonitor()
  }
}
