#!/usr/bin/env bash
# Run with: bash tests/open-handler.test.sh
#
# Covers bin/kdeconnect-open's mount handling, in particular the stale
# fuse.sshfs self-heal: a connection that dropped leaves a dead mount behind,
# and the daemon's next sshfs run fails with the opaque "sshfs finished with
# exit code 1" unless the leftover is reaped first.
#
# The handler is driven end to end with stubbed busctl/fusermount3/gio and a
# synthetic mount table, so nothing real is mounted, unmounted or opened.
# Zero dependencies.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
handler="$root/bin/kdeconnect-open"

DEVICE=154bb4a6e1dc497d9ca12ea461d625d5
MOUNT_POINT="/run/user/1000/$DEVICE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
mkdir -p "$stub"
export STUB_CALLS="$tmp/calls"
export STUB_MOUNT_POINT="$MOUNT_POINT"

# ---- stubs ---------------------------------------------------------------

write_stub() {
  local name="$1"
  cat > "$stub/$name"
  chmod +x "$stub/$name"
}

write_stub busctl <<'STUB'
#!/usr/bin/env bash
method=""
for arg in "$@"; do
  case "$arg" in
    mountPoint|isMounted|mountAndWait|getMountError|getDirectories) method="$arg" ;;
  esac
done
echo "BUSCTL $method" >> "$STUB_CALLS"
case "$method" in
  mountPoint)     printf '{"type":"s","data":["%s"]}\n' "$STUB_MOUNT_POINT" ;;
  isMounted)      printf '{"type":"b","data":[%s]}\n' "$STUB_IS_MOUNTED" ;;
  mountAndWait)   printf '{"type":"b","data":[true]}\n' ;;
  getMountError)  printf '{"type":"s","data":["stub mount error"]}\n' ;;
  getDirectories) printf '{"type":"a{sv}","data":[{"%s/storage/emulated/0":{"type":"s","data":["stub storage"]}}]}\n' "$STUB_MOUNT_POINT" ;;
esac
STUB

write_stub fusermount3 <<'STUB'
#!/usr/bin/env bash
echo "FUSERMOUNT3 $*" >> "$STUB_CALLS"
STUB

write_stub gio <<'STUB'
#!/usr/bin/env bash
echo "GIO $*" >> "$STUB_CALLS"
STUB

# The handler only probes for sshfs; it never runs it itself.
write_stub sshfs <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# The sub-path probe runs under timeout(1); log it and answer as the test says
# (0 = directory exists, 124 = the probe timed out on a dead endpoint).
write_stub timeout <<'STUB'
#!/usr/bin/env bash
echo "TIMEOUT $*" >> "$STUB_CALLS"
exit "${STUB_DIR_PROBE:-0}"
STUB

# Failures notify; keep the tests quiet and side-effect free.
write_stub notify-send <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
write_stub omarchy-notification-send <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

PATH="$stub:$PATH"
export PATH

# ---- helpers -------------------------------------------------------------

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# The mount table the daemon would have left behind: the same sshfs mount the
# daemon creates (kdeconnect@<ip>:/ <mount-point> fuse.sshfs ...).
sshfs_line() {
  echo "kdeconnect@192.168.1.175:/ $MOUNT_POINT fuse.sshfs rw,nosuid,nodev,relatime,user_id=1000,group_id=1000 0 0"
}

# run <is-mounted-truth> <mount-table-content> [sub-path]
run() {
  : > "$STUB_CALLS"
  printf '%s' "$2" > "$tmp/mounts"
  export STUB_IS_MOUNTED="$1"
  export OMARCHY_CONNECT_MOUNTS="$tmp/mounts"
  if ! "$handler" "kdeconnect://$DEVICE/${3:-}" >"$tmp/out" 2>"$tmp/err"; then
    fail "handler exited non-zero: $(cat "$tmp/err")"
  fi
}

calls() { cat "$STUB_CALLS"; }

# assert_order <first> <second>: first must be logged before second.
assert_order() {
  awk -v a="$1" -v b="$2" '
    index($0, a) { fa = NR }
    index($0, b) { fb = NR }
    END { exit !(fa && fb && fa < fb) }
  ' "$STUB_CALLS" || fail "expected $1 before $2 in: $(calls)"
}

# ---- 1. a stale mount is reaped before the daemon mounts -----------------

run false "$(sshfs_line)
"
grep -qF "FUSERMOUNT3 -uz $MOUNT_POINT" "$STUB_CALLS" \
  || fail "stale mount was not unmounted first: $(calls)"
assert_order FUSERMOUNT3 "BUSCTL mountAndWait"
grep -qF "GIO open $MOUNT_POINT/storage/emulated/0" "$STUB_CALLS" \
  || fail "storage was not opened after the self-heal: $(calls)"
echo "ok 1 - stale fuse.sshfs mount reaped before mounting"

# ---- 2. a live mount is never unmounted ----------------------------------

run true "$(sshfs_line)
"
if grep -q FUSERMOUNT3 "$STUB_CALLS"; then
  fail "live mount was unmounted: $(calls)"
fi
grep -qF "BUSCTL mountAndWait" "$STUB_CALLS" \
  || fail "daemon was not asked to mount: $(calls)"
echo "ok 2 - live mount left alone"

# ---- 3. nothing in the mount table, nothing to reap ----------------------

run false ""
if grep -q FUSERMOUNT3 "$STUB_CALLS"; then
  fail "unmounted something that was not mounted: $(calls)"
fi
echo "ok 3 - no entry, no unmount"

# ---- 4. only this device's own fuse.sshfs point is touched ---------------

run false "kdeconnect@192.168.1.175:/ /run/user/1000/anotherdev fuse.sshfs rw 0 0
server:/ $MOUNT_POINT nfs4 rw 0 0
"
if grep -q FUSERMOUNT3 "$STUB_CALLS"; then
  fail "touched a mount it does not own: $(calls)"
fi
echo "ok 4 - other mounts and other filesystems are left alone"

# ---- 5. a sub-path probe that stalls is bounded and falls back -----------

STUB_DIR_PROBE=124 run true "$(sshfs_line)
" Download
grep -qF "TIMEOUT 5 test -d $MOUNT_POINT/storage/emulated/0/Download" "$STUB_CALLS" \
  || fail "sub-path probe was not bounded by timeout: $(calls)"
grep -qF "GIO open $MOUNT_POINT/Download" "$STUB_CALLS" \
  || fail "stalled probe did not fall back to the raw mount: $(calls)"
echo "ok 5 - stalled sub-path probe times out and falls back"

# ---- 6. an existing sub-path opens inside the storage --------------------

STUB_DIR_PROBE=0 run true "$(sshfs_line)
" Download
grep -qF "GIO open $MOUNT_POINT/storage/emulated/0/Download" "$STUB_CALLS" \
  || fail "existing sub-path was not opened inside the storage: $(calls)"
echo "ok 6 - existing sub-path opens inside the storage"

echo "all open-handler tests passed"
