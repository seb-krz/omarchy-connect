#!/bin/bash
# Sync plugin files into the omarchy plugins dir. Writing real files there
# (not a symlink) lets the shell's inotify watcher trigger a full hot reload
# including the QML component cache clear.
set -e
src="$(cd "$(dirname "$0")" && pwd)"
dst="$HOME/.config/omarchy/plugins/seb-krz.omarchy-connect"
mkdir -p "$dst/bin" "$dst/resources"
cp "$src"/manifest.json "$src"/Panel.qml "$src"/Service.qml "$src"/Dbus.qml \
  "$src"/Integration.qml "$src"/Model.js "$src"/README.md "$src"/LICENSE "$dst"/
cp "$src"/bin/kdeconnect-open "$src"/bin/kdeconnect-install "$dst"/bin/
cp "$src"/resources/kdeconnect-url-handler.desktop "$dst"/resources/
chmod +x "$dst"/bin/kdeconnect-open "$dst"/bin/kdeconnect-install
