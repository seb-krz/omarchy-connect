#!/usr/bin/env bash
# Run with: bash tests/url-handler-registration.test.sh
#
# Covers how bin/kdeconnect-install treats mimeapps.list when the integration
# is removed: only our own association goes, and a mimeapps.list that is a
# symlink (dotfile managers) stays one.
#
# Everything runs against throwaway XDG directories, so the real
# ~/.config/mimeapps.list is never read or written. Zero dependencies.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$root/bin/kdeconnect-install"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cfg" "$tmp/data" "$tmp/bin" "$tmp/dotfiles"
export XDG_CONFIG_HOME="$tmp/cfg" XDG_DATA_HOME="$tmp/data" XDG_BIN_HOME="$tmp/bin"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

list="$tmp/cfg/mimeapps.list"

# ---- 1. a symlinked mimeapps.list stays a symlink; only our line goes ----

cat > "$tmp/dotfiles/mimeapps.list" <<'LIST'
[Default Applications]
text/plain=nvim.desktop
x-scheme-handler/kdeconnect=kdeconnect-url-handler.desktop
LIST
ln -s "$tmp/dotfiles/mimeapps.list" "$list"

"$installer" uninstall >/dev/null

[ -L "$list" ] || fail "symlinked mimeapps.list was replaced by a regular file"
if grep -q '^x-scheme-handler/kdeconnect=' "$list"; then
  fail "our own association survived uninstall: $(cat "$list")"
fi
grep -qx 'text/plain=nvim.desktop' "$list" \
  || fail "an unrelated association was lost: $(cat "$list")"
[ ! -e "$list.omarchy-connect.tmp" ] || fail "temporary file left behind"
echo "ok 1 - symlink kept, only our association removed"

# ---- 2. another handler's association survives uninstall -----------------

rm -f "$list"
cat > "$list" <<'LIST'
[Default Applications]
x-scheme-handler/kdeconnect=org.kde.dolphin.desktop
LIST

"$installer" uninstall >/dev/null

grep -qx 'x-scheme-handler/kdeconnect=org.kde.dolphin.desktop' "$list" \
  || fail "a foreign association was removed: $(cat "$list")"
echo "ok 2 - foreign association left alone"

echo "all url-handler registration tests passed"
