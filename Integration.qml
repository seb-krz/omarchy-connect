import QtQuick
import Quickshell.Io

// Desktop integration, driven by the opt-in "kdeconnect:// link handler"
// setting (default off). KDE Connect's own "Explore device" button opens a
// kdeconnect://<device-id>/ URL and expects a KIO file manager to translate
// the virtual root. Omarchy's default file manager has no KIO, so that URL
// has no handler at all and the button silently does nothing.
//
// When the user switches the setting on, this component installs
// bin/kdeconnect-open as the kdeconnect:// handler (via bin/kdeconnect-install)
// and removes it again when switched off. It never runs on its own, and a
// failure never affects the panel. The panel's Files action calls the bundled
// handler directly, so it does not depend on this integration.
Item {
  id: root

  // Directory this plugin was loaded from, without a trailing slash. Used to
  // reach the bundled scripts regardless of where the plugin was installed.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    try { url = decodeURIComponent(url) } catch (e) { url = url }
    while (url.length > 1 && url.charAt(url.length - 1) === "/")
      url = url.substring(0, url.length - 1)
    return url
  }

  readonly property string handlerPath: pluginDir + "/bin/kdeconnect-open"

  // True once the last install/uninstall finished successfully.
  property bool installed: false

  property string pendingAction: ""
  property string _queued: ""

  function install() { _want("install") }
  function uninstall() { _want("uninstall") }

  // One run at a time; a toggle that lands mid-run is applied after it, so the
  // final state always matches the setting.
  function _want(action) {
    if (installer.running) { _queued = action; return }
    _start(action)
  }

  function _start(action) {
    pendingAction = action
    installer.command = [root.pluginDir + "/bin/kdeconnect-install", action]
    installTimeout.restart()
    installer.running = true
  }

  Process {
    id: installer
    // Missing interpreter, no xdg-mime, a hanging xdg-mime, ... must not
    // leave the process busy forever or surface in the UI.
    onExited: function (exitCode) {
      installTimeout.stop()
      if (exitCode === 0) root.installed = root.pendingAction === "install"
      root.pendingAction = ""
      var next = root._queued
      root._queued = ""
      if (next) root._start(next)
    }
  }

  Timer {
    id: installTimeout
    interval: 15000
    onTriggered: installer.running = false
  }
}
