#!/bin/bash
set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

LABEL="com.dockur.macos.firstboot"
BASE="/Library/Application Support/macos-unattended"
ADMIN_PACKAGE="$BASE/admin.pkg"
DAEMON="/Library/LaunchDaemons/$LABEL.plist"
USER_DIR="/private/var/db/dslocal/nodes/Default/users"
ADMIN_PLIST="/private/var/db/dslocal/nodes/Default/groups/admin.plist"
LOG="/var/log/macos-unattended-firstboot.log"

log() {
  printf '%s\n' "[firstboot] $1" >> "$LOG" 2>/dev/null || :
}

fail() {
  log "ERROR: $1"
  exit 1
}

log "first-boot account setup started"

[ -s "$ADMIN_PACKAGE" ] || fail "prebuilt account package is missing"
[ -x /usr/sbin/installer ] || fail "installer is not available"

count=0
while (( count < 300 )); do
  if [ -d "$USER_DIR" ] && [ -f "$ADMIN_PLIST" ]; then
    break
  fi
  count=$((count + 1))
  sleep 1
done

[ -d "$USER_DIR" ] || fail "local user database did not become available"
[ -f "$ADMIN_PLIST" ] || fail "admin group database did not become available"

log "local user database is available; installing prebuilt account package"

if ! /usr/sbin/installer -pkg "$ADMIN_PACKAGE" -target / -verboseR >> "$LOG" 2>&1; then
  fail "prebuilt account package installation failed"
fi

log "prebuilt account package installed successfully"

if ! /bin/rm -f "$DAEMON"; then
  fail "failed to remove first-boot LaunchDaemon"
fi

if ! /bin/rm -rf "$BASE"; then
  fail "failed to remove first-boot staging directory"
fi

log "first-boot account setup completed"
exit 0
