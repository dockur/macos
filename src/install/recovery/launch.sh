#!/bin/bash
set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

LOCAL_LOG="/var/log/launch.log"
STATE_DIR="/Volumes/installstate"
STATE_LOG="$STATE_DIR/install.log"
APPLE_INSTALL_LOG="$STATE_DIR/apple.log"
STATE_LOG_LIMIT=$((1 * 1024 * 1024))
APPLE_INSTALL_LOG_LIMIT=$((4 * 1024 * 1024))
STARTED="$STATE_DIR/started"
TARGET_VOLUME="/Volumes/Macintosh HD"
ADMIN_PACKAGE="$STATE_DIR/admin.pkg"
SETUP_PACKAGE="$STATE_DIR/skipsetup.pkg"
FIRSTBOOT_SCRIPT="$STATE_DIR/firstboot.sh"
FIRSTBOOT_PLIST="$STATE_DIR/com.dockur.macos.firstboot.plist"
MIN_TARGET_SIZE=$((16 * 1024 * 1024 * 1024))

BOOTSTRAP_READY="$STATE_DIR/bootstrap.ready"
BOOTSTRAP_DONE="$STATE_DIR/bootstrap.done"
BOOTSTRAP_FAILED="$STATE_DIR/bootstrap.failed"

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

install_bootstrap() {

  local support_dir="$TARGET_VOLUME/Library/Application Support/macos-unattended"
  local daemon_dir="$TARGET_VOLUME/Library/LaunchDaemons"
  local staged_admin="$support_dir/admin.pkg"
  local staged_script="$support_dir/firstboot.sh"
  local staged_plist="$daemon_dir/com.dockur.macos.firstboot.plist"

  echo "[log] prepare phase completed; installing unattended bootstrap"

  if ! /usr/sbin/installer \
      -pkg "$SETUP_PACKAGE" \
      -target "$TARGET_VOLUME" \
      -verboseR; then
    echo "[log] ERROR: failed to install prebuilt Setup Assistant package"
    return 1
  fi

  echo "[log] prebuilt Setup Assistant package installed successfully"

  if ! /bin/mkdir -p "$support_dir" "$daemon_dir"; then
    echo "[log] ERROR: failed to create first-boot staging directories"
    return 1
  fi

  if ! /bin/cp -f "$ADMIN_PACKAGE" "$staged_admin" ||
     ! /bin/cp -f "$FIRSTBOOT_SCRIPT" "$staged_script" ||
     ! /bin/cp -f "$FIRSTBOOT_PLIST" "$staged_plist"; then
    echo "[log] ERROR: failed to stage first-boot files"
    return 1
  fi

  /usr/sbin/chown 0:0 "$staged_admin" "$staged_script" "$staged_plist" 2>/dev/null || :

  if ! /bin/chmod 0644 "$staged_admin" "$staged_plist" ||
     ! /bin/chmod 0755 "$staged_script"; then
    echo "[log] ERROR: failed to set first-boot file permissions"
    return 1
  fi

  if ! /usr/bin/cmp -s "$ADMIN_PACKAGE" "$staged_admin" ||
     ! /usr/bin/cmp -s "$FIRSTBOOT_SCRIPT" "$staged_script" ||
     ! /usr/bin/cmp -s "$FIRSTBOOT_PLIST" "$staged_plist"; then
    echo "[log] ERROR: staged first-boot files failed byte-for-byte validation"
    return 1
  fi

  if ! /usr/bin/plutil -lint "$staged_plist" >/dev/null 2>&1; then
    echo "[log] ERROR: staged first-boot LaunchDaemon plist is invalid"
    return 1
  fi

  echo "[log] unattended bootstrap installed successfully"
  return 0
}

run_bootstrapper() {

  trap '
    if install_bootstrap; then
      : > "$BOOTSTRAP_DONE"
    else
      : > "$BOOTSTRAP_FAILED"
    fi
    exit 0
  ' USR1

  : > "$BOOTSTRAP_READY"

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
[ -s "$FIRSTBOOT_SCRIPT" ] || fail "first-boot script is missing"
[ -s "$FIRSTBOOT_PLIST" ] || fail "first-boot LaunchDaemon plist is missing"
[ -x /usr/sbin/installer ] || fail "installer is not available in Recovery"
/usr/bin/plutil -lint "$FIRSTBOOT_PLIST" >/dev/null 2>&1 ||
  fail "first-boot LaunchDaemon plist is invalid"

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

echo "[log] unattended bootstrap preflight passed"

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
  "$BOOTSTRAP_READY" \
  "$BOOTSTRAP_DONE" \
  "$BOOTSTRAP_FAILED"

# startosinstall prepares macOS without --installpackage. At the end of the
# prepare phase it signals our helper while the target is still mounted. The
# helper installs the known-good Setup Assistant package directly and stages
# the known-good account package for a LaunchDaemon to run on first real boot.
run_bootstrapper &
BOOTSTRAPPER_PID=$!

count=0
while (( count < 10 )); do
  [ -e "$BOOTSTRAP_READY" ] && break
  count=$((count + 1))
  sleep 1
done

[ -e "$BOOTSTRAP_READY" ] || {
  /bin/kill "$BOOTSTRAPPER_PID" 2>/dev/null || :
  fail "bootstrap helper failed to initialize"
}

ARGS=(
  --volume "$TARGET_VOLUME"
  --agreetolicense
  --nointeraction
  --rebootdelay 300
  --pidtosignal "$BOOTSTRAPPER_PID"
)

echo "[log] starting online macOS installation on $TARGET_VOLUME"
echo "[log] bootstrap will be installed directly after startosinstall prepare phase"

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

  if [ -e "$BOOTSTRAP_DONE" ]; then
    echo "[log] bootstrap installation succeeded; releasing startosinstall reboot delay"
    /bin/kill -USR1 "$STARTOSINSTALL_PID" 2>/dev/null || :
    break
  fi

  if [ -e "$BOOTSTRAP_FAILED" ]; then
    echo "[log] ERROR: bootstrap installation failed; cancelling prepared install"
    /bin/kill "$STARTOSINSTALL_PID" 2>/dev/null || :
    wait "$STARTOSINSTALL_PID" 2>/dev/null || :
    /bin/kill "$BOOTSTRAPPER_PID" 2>/dev/null || :
    fail "bootstrap installation failed"
  fi

  sleep 1
done

wait "$STARTOSINSTALL_PID"
rc=$?

/bin/kill "$BOOTSTRAPPER_PID" 2>/dev/null || :

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
