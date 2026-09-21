// Pure parsing/normalization logic. No Quickshell imports — unit-testable with node.
// All busctl JSON parsing lives here; QML never touches raw D-Bus output.

// ---------- busctl JSON parsing ----------

// busctl --json=short call output: {"type":"...","data":[<return values>]}
// Returns the array of return values, or null on any malformed input.
function parseCallResult(raw) {
  try {
    var obj = JSON.parse(String(raw))
    if (!obj || !Array.isArray(obj.data)) return null
    return obj.data
  } catch (e) {
    return null
  }
}

// GetAll returns a{sv}: data[0] is {propName: {type, data}}. Flattens to plain
// {propName: value}. Returns null on malformed input.
function parseProperties(raw) {
  var data = parseCallResult(raw)
  if (!data || typeof data[0] !== "object" || data[0] === null) return null
  var props = {}
  for (var key in data[0]) {
    var v = data[0][key]
    if (v && typeof v === "object" && "data" in v) props[key] = v.data
  }
  return props
}

// devices(bb) returns as: data[0] is the ID array.
function parseDeviceIds(raw) {
  var data = parseCallResult(raw)
  if (!data || !Array.isArray(data[0])) return null
  return data[0].filter(function (id) { return typeof id === "string" && id.length > 0 })
}

// loadedPlugins() returns as.
function parseStringList(raw) {
  return parseDeviceIds(raw)
}

// ---------- normalization ----------

function str(v, fallback) { return typeof v === "string" ? v : (fallback || "") }
function bool(v) { return v === true }
function arr(v) { return Array.isArray(v) ? v : [] }

var CAPABILITY_PLUGINS = {
  battery: "kdeconnect_battery",
  ring: "kdeconnect_findmyphone",
  ping: "kdeconnect_ping",
  clipboard: "kdeconnect_clipboard",
  share: "kdeconnect_share",
  sftp: "kdeconnect_sftp",
  remoteCommands: "kdeconnect_remotecommands"
}

// props: flattened org.kde.kdeconnect.device properties (parseProperties).
// loadedPlugins: string list or null (method can fail while unreachable).
// batteryProps: flattened battery-object properties or null (object absent
// unless the plugin is loaded — absence is normal, not an error).
function normalizeDevice(id, props, loadedPlugins, batteryProps) {
  var p = props || {}
  var loaded = arr(loadedPlugins)
  var reachable = bool(p.isReachable)
  var paired = bool(p.isPaired)

  var caps = {}
  for (var cap in CAPABILITY_PLUGINS) caps[cap] = loaded.indexOf(CAPABILITY_PLUGINS[cap]) !== -1

  var battery = { available: false, percentage: -1, charging: false }
  if (caps.battery && batteryProps) {
    // Installed KDE Connect exposes charge (i) and isCharging (b); charge is
    // -1 until the first report arrives.
    var charge = typeof batteryProps.charge === "number" ? batteryProps.charge : -1
    if (charge >= 0 && charge <= 100) {
      battery = { available: true, percentage: charge, charging: bool(batteryProps.isCharging) }
    }
  }

  return {
    id: String(id),
    name: str(p.name, "Unknown device"),
    type: str(p.type, "unknown"),
    reachable: reachable,
    paired: paired,
    connected: reachable && paired,
    pairable: reachable && !paired,
    pairRequested: bool(p.isPairRequested),
    pairRequestedByPeer: bool(p.isPairRequestedByPeer),
    pairState: typeof p.pairState === "number" ? p.pairState : 0,
    verificationKey: str(p.verificationKey),
    addresses: arr(p.reachableAddresses).map(String),
    providers: arr(p.activeProviderNames).map(String),
    loadedPlugins: loaded.map(String),
    supportedPlugins: arr(p.supportedPlugins).map(String),
    caps: caps,
    battery: battery,
    remoteCommands: []
  }
}

// Deterministic order: connected, then reachable-pairable, then paired-offline,
// then the rest; alphabetical within each group so rows never jitter.
function deviceRank(d) {
  if (d.connected) return 0
  if (d.pairable) return 1
  if (d.paired) return 2
  return 3
}

function orderDevices(devices) {
  return arr(devices).slice().sort(function (a, b) {
    var ra = deviceRank(a), rb = deviceRank(b)
    if (ra !== rb) return ra - rb
    var na = a.name.toLowerCase(), nb = b.name.toLowerCase()
    if (na !== nb) return na < nb ? -1 : 1
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  })
}

// Primary-device precedence (DesignDocument.md §7). devices must be ordered.
function selectPrimaryId(devices, preferredId, lastActiveId) {
  var ds = arr(devices)
  function find(pred) {
    for (var i = 0; i < ds.length; i++) if (pred(ds[i])) return ds[i].id
    return ""
  }
  return (
    find(function (d) { return d.id === preferredId && d.connected }) ||
    find(function (d) { return d.id === lastActiveId && d.connected }) ||
    find(function (d) { return d.connected }) ||
    find(function (d) { return d.id === preferredId && d.paired }) ||
    find(function (d) { return d.paired }) ||
    find(function (d) { return d.pairable }) ||
    ""
  )
}

// Normalized devices are built with fixed key order, so stringify is a
// reliable deep-equality check.
function snapshotEquals(a, b) {
  return JSON.stringify(a) === JSON.stringify(b)
}

// ---------- monitor filtering ----------

// busctl monitor output includes our own snapshot method calls and the
// NameOwnerChanged churn of every short-lived busctl connection. Treating any
// output as "dirty" would make each refresh trigger the next one forever.
// Only count as invalidation:
//   - signals on org.kde.kdeconnect.* interfaces;
//   - PropertiesChanged signals on /modules/kdeconnect paths;
//   - NameOwnerChanged whose name argument is the daemon (restart/exit).
// Monitor lines arrive as: a "‣ Type=..." header, then a detail line with
// Sender/Path/Interface/Member, then MESSAGE body lines.
// Destination path out of a shareReceived STRING argument line, or null.
// Anything that is not a plain file:// URL (a text share, a quoted name we
// cannot unambiguously delimit) yields null and is simply not announced.
function parseShareUrl(line) {
  var m = String(line).match(/STRING\s+"([^"]*)"/)
  if (!m || m[1].indexOf("file://") !== 0) return null
  var path = m[1].substring(7)
  try { path = decodeURIComponent(path) } catch (e) { return null }
  return path.length > 0 ? path : null
}

function baseName(path) {
  var p = String(path)
  var i = p.lastIndexOf("/")
  return i === -1 ? p : p.substring(i + 1)
}

function makeMonitorFilter() {
  return {
    inSignal: false,
    awaitingNameArg: false,
    awaitingShareArg: false,
    share: null,
    // Hands over a captured destination path once, then forgets it. Read
    // after every feed(); a share never survives into the next signal.
    takeShare: function () {
      var s = this.share
      this.share = null
      return s
    },
    // Returns true if this line means kdeconnect state may have changed.
    feed: function (line) {
      var l = String(line)
      if (l.indexOf("Type=") !== -1) {
        this.inSignal = l.indexOf("Type=signal") !== -1
        this.awaitingNameArg = false
        this.awaitingShareArg = false
        return false
      }
      if (this.awaitingShareArg) {
        // First STRING of shareReceived is the destination URL.
        if (l.indexOf("STRING") !== -1) {
          this.awaitingShareArg = false
          this.share = parseShareUrl(l)
        }
        return false
      }
      if (this.awaitingNameArg) {
        // First STRING of NameOwnerChanged is the affected bus name.
        if (l.indexOf("STRING") !== -1) {
          this.awaitingNameArg = false
          return l.indexOf('"org.kde.kdeconnect') !== -1
        }
        return false
      }
      if (!this.inSignal || l.indexOf("Interface=") === -1) return false
      if (l.indexOf("Member=shareReceived") !== -1) {
        this.awaitingShareArg = true
        return true
      }
      if (l.indexOf("Interface=org.kde.kdeconnect") !== -1) return true
      if (l.indexOf("Interface=org.freedesktop.DBus.Properties") !== -1)
        return l.indexOf("Path=/modules/kdeconnect") !== -1
      if (l.indexOf("Member=NameOwnerChanged") !== -1) {
        this.awaitingNameArg = true
        return false
      }
      return false
    }
  }
}

// ---------- presentation helpers ----------

var DEVICE_GLYPHS = {
  smartphone: "\u{f011c}", // 󰄜 cellphone
  phone: "\u{f011c}",
  // The landscape tablet glyph reads as a sideways phone at bar size, and
  // KDE Connect reports many phones as "tablet" — use the portrait glyph.
  tablet: "\u{f011c}",
  laptop: "\u{f0322}",     // 󰌢
  desktop: "\u{f07c0}",    // 󰟀
  tv: "\u{f0502}"          // 󰔂 television
}

function deviceGlyph(type) {
  return DEVICE_GLYPHS[type] || DEVICE_GLYPHS.smartphone
}

// "LanLinkProvider" → "LAN", "BluetoothLinkProvider" → "Bluetooth".
function providerLabel(providers) {
  var p = arr(providers)
  if (p.length === 0) return ""
  var name = String(p[0]).replace(/LinkProvider$/, "")
  return name.toLowerCase() === "lan" ? "LAN" : name
}

function statusLine(d) {
  if (!d) return ""
  if (d.connected) {
    var via = providerLabel(d.providers)
    return via ? "Connected via " + via : "Connected"
  }
  if (d.pairRequestedByPeer) return "Pairing request"
  if (d.pairRequested) return "Pairing…"
  if (d.pairable) return "Available nearby"
  if (d.paired) return "Offline"
  return "Unavailable"
}

// "82C4DD3C" → "82C4 DD3C" for readability; verification keys are short hex.
function formatVerificationKey(key) {
  var k = str(key).trim()
  return k.length === 8 ? k.slice(0, 4) + " " + k.slice(4) : k
}

// ---------- kdeconnect.notifyrc pairing-popup override ----------

// KNotification per-event user override: a [Event/pairingRequest] section
// with an empty Action= disables only the pairing popup (system default is
// Action=Popup in /usr/share/knotifications6/kdeconnect.notifyrc). These
// edit the user file textually, preserving unrelated content byte-for-byte.

var NOTIFYRC_SECTION = "[Event/pairingRequest]"

function _notifyrcSectionRange(lines) {
  var start = -1
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() === NOTIFYRC_SECTION) { start = i; break }
  }
  if (start === -1) return null
  var end = lines.length
  for (var j = start + 1; j < lines.length; j++) {
    if (lines[j].trim().charAt(0) === "[") { end = j; break }
  }
  return { start: start, end: end }
}

function notifyrcPairingPopupSuppressed(text) {
  var lines = String(text || "").split("\n")
  var range = _notifyrcSectionRange(lines)
  if (!range) return false
  for (var i = range.start + 1; i < range.end; i++) {
    var m = lines[i].match(/^Action\s*=\s*(.*)$/)
    if (m) {
      var v = m[1].trim()
      return v === "" || v.toLowerCase() === "none"
    }
  }
  return false
}

// Reads the current Action state of the pairingRequest section, so a caller
// can save it before overriding and restore the exact value later.
// Returns { hadSection: bool, action: string|null } — action is the raw
// value ("Popup|Sound", "", "None", ...), null when no Action line exists.
function notifyrcGetPairingAction(text) {
  var lines = String(text || "").split("\n")
  var range = _notifyrcSectionRange(lines)
  if (!range) return { hadSection: false, action: null }
  for (var i = range.start + 1; i < range.end; i++) {
    var m = lines[i].match(/^Action\s*=\s*(.*)$/)
    if (m) return { hadSection: true, action: m[1].trim() }
  }
  return { hadSection: true, action: null }
}

// Sets the pairingRequest Action to an exact value. action as a string
// ("" suppresses, "Popup|Sound" restores a custom value) writes/replaces the
// line, creating the section if needed. action === null removes the Action
// line, dropping the section only when nothing else remains in it. All other
// content is preserved byte-for-byte.
function notifyrcSetPairingAction(text, action) {
  var lines = String(text || "").split("\n")
  var range = _notifyrcSectionRange(lines)
  if (action !== null && action !== undefined) {
    var line = "Action=" + String(action)
    if (range) {
      for (var i = range.start + 1; i < range.end; i++) {
        if (/^Action\s*=/.test(lines[i])) {
          lines[i] = line
          return lines.join("\n")
        }
      }
      lines.splice(range.start + 1, 0, line)
      return lines.join("\n")
    }
    var out = lines.join("\n")
    if (out.length > 0 && !/\n$/.test(out)) out += "\n"
    return out + NOTIFYRC_SECTION + "\n" + line + "\n"
  }
  if (!range) return lines.join("\n")
  var kept = []
  var hasOther = false
  for (var k = range.start + 1; k < range.end; k++) {
    if (/^Action\s*=/.test(lines[k])) continue
    if (lines[k].trim() !== "") hasOther = true
    kept.push(lines[k])
  }
  var head = lines.slice(0, range.start)
  var tail = lines.slice(range.end)
  var mid = hasOther ? [lines[range.start]].concat(kept) : []
  return head.concat(mid).concat(tail).join("\n")
}

// ---------- backend state ----------

// Distinct failure states (DesignDocument.md §24); never collapse these.
var BackendState = {
  Unknown: "unknown",
  NotInstalled: "not-installed",
  NoDaemon: "no-daemon",
  Starting: "starting",
  Ready: "ready"
}

// ---------- debug ----------

function snapshotSummary(backendState, devices) {
  return JSON.stringify({
    backend: backendState,
    devices: arr(devices).map(function (d) {
      return {
        id: d.id, name: d.name, paired: d.paired, reachable: d.reachable,
        battery: d.battery.available ? d.battery.percentage : null,
        charging: d.battery.available ? d.battery.charging : null
      }
    })
  }, null, 2)
}

if (typeof module !== "undefined") {
  module.exports = {
    parseCallResult: parseCallResult,
    parseProperties: parseProperties,
    parseDeviceIds: parseDeviceIds,
    parseStringList: parseStringList,
    normalizeDevice: normalizeDevice,
    orderDevices: orderDevices,
    selectPrimaryId: selectPrimaryId,
    snapshotEquals: snapshotEquals,
    makeMonitorFilter: makeMonitorFilter,
    parseShareUrl: parseShareUrl,
    baseName: baseName,
    BackendState: BackendState,
    snapshotSummary: snapshotSummary,
    deviceGlyph: deviceGlyph,
    providerLabel: providerLabel,
    statusLine: statusLine,
    formatVerificationKey: formatVerificationKey,
    notifyrcPairingPopupSuppressed: notifyrcPairingPopupSuppressed,
    notifyrcGetPairingAction: notifyrcGetPairingAction,
    notifyrcSetPairingAction: notifyrcSetPairingAction
  }
}
