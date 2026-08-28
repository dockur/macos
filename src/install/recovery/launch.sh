#!/bin/bash
set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

LOCAL_LOG="/var/log/launch.log"
STATE_DIR="/Volumes/installstate"
STATE_LOG="$STATE_DIR/install.log"
APPLE_INSTALL_LOG="$STATE_DIR/apple.log"
INSTALL_INFO_SNAPSHOT="$STATE_DIR/InstallInfo.plist"
INSTALLERS_SNAPSHOT="$STATE_DIR/installers.txt"
STATE_LOG_LIMIT=$((1 * 1024 * 1024))
APPLE_INSTALL_LOG_LIMIT=$((4 * 1024 * 1024))
STARTED="$STATE_DIR/started"
TARGET_VOLUME="/Volumes/Macintosh HD"
ADMIN_PACKAGE="$STATE_DIR/admin.pkg"
SETUP_PACKAGE="$STATE_DIR/skipsetup.pkg"
MIN_TARGET_SIZE=$((16 * 1024 * 1024 * 1024))

INJECTION_READY="$STATE_DIR/injection.ready"
INJECTION_DONE="$STATE_DIR/injection.done"
INJECTION_FAILED="$STATE_DIR/injection.failed"

exec >> "$LOCAL_LOG" 2>&1

echo "[log] unattended installation starting"

mount_state_share() {

  local count=0

  while (( count < 120 )); do

    if [ -d "$STATE_DIR" ]; then
      return 0
    fi

    /sbin/mount_9p installstate >/dev/null 2>&1 || :

    [ -d "$STATE_DIR" ] && return 0

    count=$((count + 1))
    sleep 1
  done

  return 1
}

snapshot_log() {

  local source="$1"
  local dest="$2"
  local limit="$3"

  [ -f "$source" ] || return 0
  /usr/bin/tail -c "$limit" "$source" > "$dest" 2>/dev/null || :
  return 0
}

mirror_log() {

  local source="$1"
  local dest="$2"
  local limit="$3"

  while :; do
    snapshot_log "$source" "$dest" "$limit"
    sleep 2
  done
}

fail() {

  local message="$1"

  echo "[log] ERROR: $message"
  if [ -d "$STATE_DIR" ]; then
    snapshot_log "$LOCAL_LOG" "$STATE_LOG" "$STATE_LOG_LIMIT"
    snapshot_log "/var/log/install.log" "$APPLE_INSTALL_LOG" "$APPLE_INSTALL_LOG_LIMIT"
    rm -f "$STARTED"
  fi
  exec /usr/libexec/recoveryosd
  exit 1
}

select_target_disk() {

  local disk info size
  local best=""
  local best_size=0

  while IFS= read -r disk; do

    [ -n "$disk" ] || continue

    info=$(/usr/sbin/diskutil info "/dev/$disk" 2>/dev/null || :)
    [ -n "$info" ] || continue

    if printf '%s\n' "$info" |
       /usr/bin/grep -Eq '^[[:space:]]*(Media|Device) Read-Only:[[:space:]]*Yes'; then
      continue
    fi

    size=$(printf '%s\n' "$info" |
      /usr/bin/sed -nE 's/^[[:space:]]*Disk Size:.*\(([0-9]+) Bytes\).*/\1/p' |
      /usr/bin/head -n 1)

    [[ "$size" =~ ^[0-9]+$ ]] || continue
    (( size >= MIN_TARGET_SIZE )) || continue

    echo "[log] candidate target /dev/$disk ($size bytes)" >&2

    if (( size > best_size )); then
      best="$disk"
      best_size="$size"
    fi

  done < <(
    /usr/sbin/diskutil list physical 2>/dev/null |
      /usr/bin/sed -nE 's#^/dev/(disk[0-9]+).*#\1#p'
  )

  [ -n "$best" ] || return 1
  printf '/dev/%s\n' "$best"
}

find_startosinstall() {

  local file

  for file in \
    /Volumes/*/Install\ macOS*.app/Contents/Resources/startosinstall \
    /Volumes/*/Install\ OS\ X*.app/Contents/Resources/startosinstall \
    /Volumes/*/Install\ Mac\ OS\ X*.app/Contents/Resources/startosinstall \
    /Install\ macOS*.app/Contents/Resources/startosinstall \
    /Install\ OS\ X*.app/Contents/Resources/startosinstall \
    /Install\ Mac\ OS\ X*.app/Contents/Resources/startosinstall \
    /Applications/Install\ macOS*.app/Contents/Resources/startosinstall \
    /Applications/Install\ OS\ X*.app/Contents/Resources/startosinstall \
    /Applications/Install\ Mac\ OS\ X*.app/Contents/Resources/startosinstall; do

    if [ -x "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done

  return 1
}

inject_packages() {

  local install_data="$TARGET_VOLUME/macOS Install Data"
  local plist="$install_data/InstallInfo.plist"
  local admin_rel="UnwrappedInstallers/unattended-admin/admin.pkg"
  local setup_rel="UnwrappedInstallers/unattended-setup/skipsetup.pkg"
  local admin_dest="$install_data/$admin_rel"
  local setup_dest="$install_data/$setup_rel"
  local count=0

  echo "[log] prepare phase completed; injecting unattended packages directly"

  while (( count < 60 )); do
    [ -f "$plist" ] && break
    count=$((count + 1))
    sleep 1
  done

  if [ ! -f "$plist" ]; then
    echo "[log] ERROR: $plist did not appear after prepare phase"
    return 1
  fi

  if ! /usr/bin/plutil -lint "$plist" >/dev/null 2>&1; then
    echo "[log] ERROR: InstallInfo.plist is invalid before injection"
    return 1
  fi

  if ! /bin/mkdir -p "${admin_dest%/*}" "${setup_dest%/*}"; then
    echo "[log] ERROR: failed to create UnwrappedInstallers directories"
    return 1
  fi

  if ! /bin/cp -f "$ADMIN_PACKAGE" "$admin_dest" ||
     ! /bin/cp -f "$SETUP_PACKAGE" "$setup_dest"; then
    echo "[log] ERROR: failed to copy unattended packages into macOS Install Data"
    return 1
  fi

  /usr/sbin/chown 0:0 "$admin_dest" "$setup_dest" 2>/dev/null || :
  /bin/chmod 0644 "$admin_dest" "$setup_dest" || return 1

  if [ ! -s "$admin_dest" ] || ! /usr/bin/cmp -s "$ADMIN_PACKAGE" "$admin_dest"; then
    echo "[log] ERROR: injected admin.pkg failed byte-for-byte validation"
    return 1
  fi

  if [ ! -s "$setup_dest" ] || ! /usr/bin/cmp -s "$SETUP_PACKAGE" "$setup_dest"; then
    echo "[log] ERROR: injected skipsetup.pkg failed byte-for-byte validation"
    return 1
  fi

  if ! /usr/libexec/PlistBuddy -c "Print :'Additional Installers'" "$plist" >/dev/null 2>&1; then
    if ! /usr/libexec/PlistBuddy -c "Add :'Additional Installers' array" "$plist"; then
      echo "[log] ERROR: failed to create Additional Installers array"
      return 1
    fi
  fi

  if ! /usr/libexec/PlistBuddy -c "Add :'Additional Installers': string '$admin_rel'" "$plist" ||
     ! /usr/libexec/PlistBuddy -c "Add :'Additional Installers': string '$setup_rel'" "$plist"; then
    echo "[log] ERROR: failed to add unattended package paths to InstallInfo.plist"
    return 1
  fi

  if ! /usr/bin/plutil -lint "$plist" >/dev/null 2>&1; then
    echo "[log] ERROR: InstallInfo.plist is invalid after injection"
    return 1
  fi

  echo "[log] Additional Installers after direct injection:"
  /usr/libexec/PlistBuddy -c "Print :'Additional Installers'" "$plist" || return 1

  if ! /bin/cp -f "$plist" "$INSTALL_INFO_SNAPSHOT"; then
    echo "[log] ERROR: failed to save injected InstallInfo.plist snapshot"
    return 1
  fi

  {
    echo "$admin_rel"
    echo "$setup_rel"
    /bin/ls -ln "$admin_dest" "$setup_dest"
  } > "$INSTALLERS_SNAPSHOT" 2>/dev/null || :

  echo "[log] direct package injection completed"
  return 0
}

run_injector() {

  trap '
    if inject_packages; then
      : > "$INJECTION_DONE"
    else
      : > "$INJECTION_FAILED"
    fi
    exit 0
  ' USR1

  : > "$INJECTION_READY"

  while :; do
    sleep 60
  done
}

if ! mount_state_share; then
  fail "failed to mount installation state share"
fi

if ! : > "$STATE_DIR/.write-test" 2>/dev/null; then
  fail "installation state share is not writable"
fi
rm -f "$STATE_DIR/.write-test"

snapshot_log "$LOCAL_LOG" "$STATE_LOG" "$STATE_LOG_LIMIT"
mirror_log "$LOCAL_LOG" "$STATE_LOG" "$STATE_LOG_LIMIT" &

echo "[log] installation state share mounted"

if [ -e "$STARTED" ]; then
  echo "[log] installation was already started; refusing to erase the target disk again"
  exec /usr/libexec/recoveryosd
  exit 1
fi

[ -s "$ADMIN_PACKAGE" ] || fail "account package is missing"
[ -s "$SETUP_PACKAGE" ] || fail "Setup Assistant package is missing"
[ -x /usr/libexec/PlistBuddy ] || fail "PlistBuddy is not available in Recovery"

STARTOSINSTALL=""
count=0
while (( count < 120 )); do
  STARTOSINSTALL=$(find_startosinstall || :)
  [ -n "$STARTOSINSTALL" ] && break
  count=$((count + 1))
  sleep 1
done

[ -n "$STARTOSINSTALL" ] || fail "startosinstall was not found in the recovery image"

echo "[log] using $STARTOSINSTALL"

USAGE=$("$STARTOSINSTALL" --usage 2>&1 || :)
[ -n "$USAGE" ] || fail "startosinstall did not return usage information"

printf '%s\n' "$USAGE" | /usr/bin/grep -q -- '--rebootdelay' ||
  fail "startosinstall does not support --rebootdelay"

printf '%s\n' "$USAGE" | /usr/bin/grep -q -- '--pidtosignal' ||
  fail "startosinstall does not support --pidtosignal"

echo "[log] direct package injection preflight passed"

TARGET_DISK=""
count=0
while (( count < 120 )); do
  TARGET_DISK=$(select_target_disk || :)
  [ -n "$TARGET_DISK" ] && break
  count=$((count + 1))
  sleep 1
done

[ -n "$TARGET_DISK" ] || fail "no writable installation disk of at least 16 GiB was found"

echo "[log] selected $TARGET_DISK"

# Everything needed for the unattended install has passed validation. Only now
# create the guard and perform the destructive target erase.
: > "$STARTED" || fail "failed to create installation guard"

if ! /usr/sbin/diskutil eraseDisk APFS "Macintosh HD" GPT "$TARGET_DISK"; then
  fail "failed to erase $TARGET_DISK as APFS"
fi

count=0
while (( count < 60 )); do
  [ -d "$TARGET_VOLUME" ] && break
  count=$((count + 1))
  sleep 1
done

[ -d "$TARGET_VOLUME" ] || fail "target APFS volume did not mount"

rm -f \
  "$INJECTION_READY" \
  "$INJECTION_DONE" \
  "$INJECTION_FAILED" \
  "$INSTALL_INFO_SNAPSHOT" \
  "$INSTALLERS_SNAPSHOT"

# startosinstall normally owns the Additional Installers staging operation.
# For this test it prepares macOS without --installpackage. At the end of the
# prepare phase it signals our helper, which writes the known-good product
# packages and their paths into macOS Install Data itself before reboot.
run_injector &
INJECTOR_PID=$!

count=0
while (( count < 10 )); do
  [ -e "$INJECTION_READY" ] && break
  count=$((count + 1))
  sleep 1
done

[ -e "$INJECTION_READY" ] || {
  /bin/kill "$INJECTOR_PID" 2>/dev/null || :
  fail "package injector failed to initialize"
}

ARGS=(
  --volume "$TARGET_VOLUME"
  --agreetolicense
  --nointeraction
  --rebootdelay 300
  --pidtosignal "$INJECTOR_PID"
)

echo "[log] starting online macOS installation on $TARGET_VOLUME"
echo "[log] packages will be injected directly after startosinstall prepare phase"

# Keep Apple's installer diagnostics visible from the host while Recovery is
# occupied by startosinstall. Both host-visible logs are rolling snapshots so
# the 9p-backed shared-memory state can never grow without bound.
if [ -f /var/log/install.log ]; then
  snapshot_log "/var/log/install.log" "$APPLE_INSTALL_LOG" "$APPLE_INSTALL_LOG_LIMIT"
  mirror_log "/var/log/install.log" "$APPLE_INSTALL_LOG" "$APPLE_INSTALL_LOG_LIMIT" &
  echo "[log] mirroring Apple install log to $APPLE_INSTALL_LOG"
else
  echo "[log] Apple install log is not available"
fi

"$STARTOSINSTALL" "${ARGS[@]}" &
STARTOSINSTALL_PID=$!

while /bin/kill -0 "$STARTOSINSTALL_PID" 2>/dev/null; do

  if [ -e "$INJECTION_DONE" ]; then
    echo "[log] package injection succeeded; releasing startosinstall reboot delay"
    /bin/kill -USR1 "$STARTOSINSTALL_PID" 2>/dev/null || :
    break
  fi

  if [ -e "$INJECTION_FAILED" ]; then
    echo "[log] ERROR: direct package injection failed; cancelling prepared install"
    /bin/kill "$STARTOSINSTALL_PID" 2>/dev/null || :
    wait "$STARTOSINSTALL_PID" 2>/dev/null || :
    /bin/kill "$INJECTOR_PID" 2>/dev/null || :
    fail "direct package injection failed"
  fi

  sleep 1
done

wait "$STARTOSINSTALL_PID"
rc=$?

/bin/kill "$INJECTOR_PID" 2>/dev/null || :

if (( rc != 0 )); then
  rm -f "$STARTED"
  echo "[log] ERROR: startosinstall exited with status $rc"
  snapshot_log "$LOCAL_LOG" "$STATE_LOG" "$STATE_LOG_LIMIT"
  snapshot_log "/var/log/install.log" "$APPLE_INSTALL_LOG" "$APPLE_INSTALL_LOG_LIMIT"
  printf '%s\n' "$USAGE"
  exec /usr/libexec/recoveryosd
  exit "$rc"
fi

echo "[log] startosinstall completed its prepare phase; waiting for reboot"

while :; do
  sleep 60
done
