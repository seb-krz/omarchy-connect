// Run with: node tests/model.test.js
// Fixtures are real busctl output captured from a live kdeconnectd (see
// tests/fixtures/). No framework — zero-dependency assert only.
var assert = require("assert")
var fs = require("fs")
var path = require("path")
var M = require("../Model.js")

function fixture(name) {
  return fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
}

// ---- parsing real fixtures ----

var ids = M.parseDeviceIds(fixture("devices.json"))
assert.deepStrictEqual(ids, ["40d6dd619e324d6a9af645c76a2349df"])

var props = M.parseProperties(fixture("device-getall.json"))
assert.strictEqual(props.name, "motorola edge 50 ultra")
assert.strictEqual(props.isPaired, true)
assert.strictEqual(props.isReachable, false)
assert.ok(Array.isArray(props.supportedPlugins))

var loaded = M.parseStringList(fixture("loaded-plugins.json"))
assert.deepStrictEqual(loaded, [])

// ---- malformed input never throws ----

;["", "not json", "{}", '{"data":42}', '{"type":"as"}', "null"].forEach(function (bad) {
  assert.strictEqual(M.parseCallResult(bad), null)
  assert.strictEqual(M.parseProperties(bad), null)
  assert.strictEqual(M.parseDeviceIds(bad), null)
})

// ---- normalization ----

var dev = M.normalizeDevice("40d6dd619e324d6a9af645c76a2349df", props, loaded, null)
assert.strictEqual(dev.connected, false)
assert.strictEqual(dev.paired, true)
assert.strictEqual(dev.pairable, false)
assert.strictEqual(dev.battery.available, false)
assert.strictEqual(dev.caps.ring, false) // capability requires loaded, not just supported

var reachableProps = Object.assign({}, props, { isReachable: true })
var allLoaded = ["kdeconnect_battery", "kdeconnect_findmyphone", "kdeconnect_ping",
  "kdeconnect_clipboard", "kdeconnect_share", "kdeconnect_remotecommands"]
var dev2 = M.normalizeDevice("id2", reachableProps, allLoaded, { charge: 82, isCharging: true })
assert.strictEqual(dev2.connected, true)
assert.deepStrictEqual(dev2.battery, { available: true, percentage: 82, charging: true })
assert.ok(dev2.caps.ring && dev2.caps.ping && dev2.caps.clipboard && dev2.caps.share)

// battery object present but unreported charge (-1) → unavailable
var dev3 = M.normalizeDevice("id3", reachableProps, allLoaded, { charge: -1, isCharging: false })
assert.strictEqual(dev3.battery.available, false)

// normalize survives null/garbage props entirely
var devBad = M.normalizeDevice("x", null, null, null)
assert.strictEqual(devBad.name, "Unknown device")
assert.strictEqual(devBad.connected, false)

// ---- remote filesystem (sftp) capability ----

// Capability requires the plugin to be loaded, not merely supported.
var devSftp = M.normalizeDevice("id4", reachableProps, ["kdeconnect_sftp"], null)
assert.strictEqual(devSftp.caps.sftp, true)
assert.strictEqual(devSftp.caps.ring, false)

// ---- ordering ----

function mini(id, name, connected, paired, reachable) {
  return M.normalizeDevice(id, { name: name, isPaired: paired, isReachable: reachable }, [], null)
}
var ordered = M.orderDevices([
  mini("c", "Zeta offline", false, true, false),
  mini("a", "Beta nearby", false, false, true),
  mini("b", "Alpha connected", true, true, true)
])
assert.deepStrictEqual(ordered.map(function (d) { return d.id }), ["b", "a", "c"])

// ---- primary selection precedence ----

var devs = M.orderDevices([
  mini("conn1", "A", true, true, true),
  mini("conn2", "B", true, true, true),
  mini("off1", "C", false, true, false),
  mini("disc1", "D", false, false, true)
])
assert.strictEqual(M.selectPrimaryId(devs, "conn2", ""), "conn2")   // preferred reachable wins
assert.strictEqual(M.selectPrimaryId(devs, "", "conn2"), "conn2")   // last active next
assert.strictEqual(M.selectPrimaryId(devs, "", ""), "conn1")        // any connected
function byId(id) { return devs.filter(function (d) { return d.id === id })[0] }
assert.strictEqual(M.selectPrimaryId([byId("off1"), byId("disc1")], "off1", ""), "off1") // preferred offline
assert.strictEqual(M.selectPrimaryId([byId("disc1")], "", ""), "disc1")   // discovered unpaired
assert.strictEqual(M.selectPrimaryId([], "x", "y"), "")

// ---- snapshot equality ----

assert.ok(M.snapshotEquals([dev], [M.normalizeDevice(dev.id, props, loaded, null)]))
assert.ok(!M.snapshotEquals([dev], [dev2]))

// ---- monitor filter against real captured stream ----

// The fixture contains ONLY self-inflicted traffic: our own method calls and
// the NameOwnerChanged of our own busctl connection. None of it may be dirty.
var filter = M.makeMonitorFilter()
var dirtyCount = 0
fixture("monitor-sample.txt").split("\n").forEach(function (line) {
  if (filter.feed(line)) dirtyCount++
})
assert.strictEqual(dirtyCount, 0)

// Synthetic daemon signal → dirty
var f2 = M.makeMonitorFilter()
assert.strictEqual(f2.feed("‣ Type=signal  Endian=l  Flags=1 ..."), false)
assert.strictEqual(f2.feed("  Sender=:1.30  Path=/modules/kdeconnect/devices/x  Interface=org.kde.kdeconnect.device  Member=reachableChanged"), true)

// PropertiesChanged on a kdeconnect path → dirty
var f3 = M.makeMonitorFilter()
f3.feed("‣ Type=signal ...")
assert.strictEqual(f3.feed("  Sender=:1.30  Path=/modules/kdeconnect/devices/x/battery  Interface=org.freedesktop.DBus.Properties  Member=PropertiesChanged"), true)

// PropertiesChanged elsewhere → clean
var f4 = M.makeMonitorFilter()
f4.feed("‣ Type=signal ...")
assert.strictEqual(f4.feed("  Sender=:1.9  Path=/org/other  Interface=org.freedesktop.DBus.Properties  Member=PropertiesChanged"), false)

// method_call on kdeconnect interface (our own snapshot) → clean
var f5 = M.makeMonitorFilter()
f5.feed("‣ Type=method_call ...")
assert.strictEqual(f5.feed("  Sender=:1.99  Path=/modules/kdeconnect  Interface=org.kde.kdeconnect.daemon  Member=devices"), false)

// NameOwnerChanged for the daemon name → dirty; for others → clean
var f6 = M.makeMonitorFilter()
f6.feed("‣ Type=signal ...")
assert.strictEqual(f6.feed("  Sender=org.freedesktop.DBus  Path=/org/freedesktop/DBus  Interface=org.freedesktop.DBus  Member=NameOwnerChanged"), false)
assert.strictEqual(f6.feed('          STRING "org.kde.kdeconnect";'), true)
var f7 = M.makeMonitorFilter()
f7.feed("‣ Type=signal ...")
f7.feed("  Sender=org.freedesktop.DBus  Path=/org/freedesktop/DBus  Interface=org.freedesktop.DBus  Member=NameOwnerChanged")
assert.strictEqual(f7.feed('          STRING ":1.113";'), false)

// ---- shareReceived capture (fixture is real busctl output) ----

var f8 = M.makeMonitorFilter()
var dirty8 = 0
fixture("share-received.txt").split("\n").forEach(function (line) {
  if (f8.feed(line)) dirty8++
})
assert.strictEqual(f8.takeShare(), "/home/riclib/Downloads/IMG_2557.heic")
// Reading it a second time yields nothing: a share is announced exactly once.
assert.strictEqual(f8.takeShare(), null)
// The arrival also invalidates state, so it still triggers a reconcile.
assert.ok(dirty8 > 0)

// Percent-encoding is undone; a name is a display string, never a path to build on.
assert.strictEqual(
  M.parseShareUrl('          STRING "file:///home/x/My%20Photo%20%231.png";'),
  "/home/x/My Photo #1.png")
// A text share carries no file:// URL and must not be announced as a file.
assert.strictEqual(M.parseShareUrl('          STRING "some shared text";'), null)
assert.strictEqual(M.parseShareUrl('  MESSAGE "s" {'), null)

// A share never leaks across signals: a new Type= line clears the wait.
var f9 = M.makeMonitorFilter()
f9.feed("\u2023 Type=signal ...")
f9.feed("  Sender=:1.1  Path=/modules/kdeconnect/devices/x/share  Interface=org.kde.kdeconnect.device.share  Member=shareReceived")
f9.feed("\u2023 Type=signal ...")
assert.strictEqual(f9.feed('          STRING "file:///tmp/should-not-be-captured";'), false)
assert.strictEqual(f9.takeShare(), null)

assert.strictEqual(M.baseName("/home/riclib/Downloads/IMG_2557.heic"), "IMG_2557.heic")
assert.strictEqual(M.baseName("bare.png"), "bare.png")

console.log("all model tests passed")

// ---- presentation helpers ----
assert.strictEqual(M.deviceGlyph("smartphone"), M.deviceGlyph("phone"))
assert.notStrictEqual(M.deviceGlyph("laptop"), M.deviceGlyph("smartphone"))
assert.strictEqual(M.deviceGlyph("weird-future-type"), M.deviceGlyph("smartphone"))
assert.strictEqual(M.providerLabel(["LanLinkProvider"]), "LAN")
assert.strictEqual(M.providerLabel(["BluetoothLinkProvider"]), "Bluetooth")
assert.strictEqual(M.providerLabel([]), "")
assert.strictEqual(M.formatVerificationKey("82C4DD3C"), "82C4 DD3C")
assert.strictEqual(M.formatVerificationKey(""), "")
var connectedDev = M.normalizeDevice("x", { name: "P", isPaired: true, isReachable: true, activeProviderNames: ["LanLinkProvider"] }, [], null)
assert.strictEqual(M.statusLine(connectedDev), "Connected via LAN")
assert.strictEqual(M.statusLine(mini("y", "Y", false, true, false)), "Offline")
assert.strictEqual(M.statusLine(mini("z", "Z", false, false, true)), "Available nearby")
console.log("presentation tests passed")

// ---- battery fixture from live device ----
var batProps = M.parseProperties(fixture("battery-getall.json"))
assert.strictEqual(batProps.charge, 84)
assert.strictEqual(batProps.isCharging, false)
var loadedConn = M.parseStringList(fixture("loaded-plugins-connected.json"))
assert.ok(loadedConn.indexOf("kdeconnect_battery") !== -1)
var liveDev = M.normalizeDevice("x", { isPaired: true, isReachable: true, name: "n" }, loadedConn, batProps)
assert.deepStrictEqual(liveDev.battery, { available: true, percentage: 84, charging: false })
assert.ok(liveDev.caps.ping && liveDev.caps.ring && liveDev.caps.clipboard)
console.log("battery fixture tests passed")

// ---- notifyrc pairing-popup override ----
// Regression cases from marketplace review: never lose a user's own
// pre-existing Action value; restore the exact original on disable.
assert.deepStrictEqual(M.notifyrcGetPairingAction(""), { hadSection: false, action: null })
assert.deepStrictEqual(M.notifyrcGetPairingAction("[Event/pairingRequest]\nSound=hi\n"), { hadSection: true, action: null })
assert.deepStrictEqual(M.notifyrcGetPairingAction("[Event/pairingRequest]\nAction=Popup|Sound\n"), { hadSection: true, action: "Popup|Sound" })
assert.deepStrictEqual(M.notifyrcGetPairingAction("[Event/pairingRequest]\nAction=None\n"), { hadSection: true, action: "None" })

// suppress from empty file, then remove → file back to empty
var sup = M.notifyrcSetPairingAction("", "")
assert.strictEqual(M.notifyrcPairingPopupSuppressed(sup), true)
assert.strictEqual(M.notifyrcSetPairingAction(sup, null).indexOf("[Event/pairingRequest]"), -1)

// custom Action round-trip: save → suppress → restore EXACT original
var custom = "[Event/other]\nAction=Popup\n[Event/pairingRequest]\nAction=Popup|Sound\nSound=hi\n"
var saved = M.notifyrcGetPairingAction(custom)
assert.strictEqual(saved.action, "Popup|Sound")
var sup2 = M.notifyrcSetPairingAction(custom, "")
assert.strictEqual(M.notifyrcPairingPopupSuppressed(sup2), true)
assert.ok(sup2.indexOf("Sound=hi") !== -1 && sup2.indexOf("[Event/other]\nAction=Popup") !== -1)
var restored = M.notifyrcSetPairingAction(sup2, saved.action)
assert.strictEqual(restored, custom.replace(/\n$/, "") + (custom.endsWith("\n") ? "\n" : ""))

// section-without-Action round-trip: suppress adds line, restore(null) removes it, section kept
var noAction = "[Event/pairingRequest]\nSound=hi\n"
var saved2 = M.notifyrcGetPairingAction(noAction)
assert.strictEqual(saved2.action, null)
var sup3 = M.notifyrcSetPairingAction(noAction, "")
assert.strictEqual(M.notifyrcPairingPopupSuppressed(sup3), true)
var restored2 = M.notifyrcSetPairingAction(sup3, saved2.action)
assert.ok(restored2.indexOf("Sound=hi") !== -1 && !/Action\s*=/.test(restored2))
assert.ok(restored2.indexOf("[Event/pairingRequest]") !== -1)

// Action=None counts as suppressed (pre-existing user suppression detectable)
assert.strictEqual(M.notifyrcPairingPopupSuppressed("[Event/pairingRequest]\nAction=None\n"), true)
console.log("notifyrc tests passed")
