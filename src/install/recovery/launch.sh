#!/bin/bash
set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

LOCAL_LOG="/var/log/launch.log"
STATE_DIR="/Volumes/installstate"
STATE_LOG="$STATE_DIR/install.log"
STARTED="$STATE_DIR/started"
TARGET_VOLUME="/Volumes/Macintosh HD"
ADMIN_PACKAGE="$STATE_DIR/admin.pkg"
SETUP_PACKAGE="$STATE_DIR/skipsetup.pkg"
MIN_TARGET_SIZE=$((16 * 1024 * 1024 * 1024))

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

fail() {

  local message="$1"

  echo "[log] ERROR: $message"
  [ -d "$STATE_DIR" ] && rm -f "$STARTED"
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

if ! mount_state_share; then
  fail "failed to mount installation state share"
fi

if ! : > "$STATE_DIR/.write-test" 2>/dev/null; then
  fail "installation state share is not writable"
fi
rm -f "$STATE_DIR/.write-test"

cat "$LOCAL_LOG" >> "$STATE_LOG" 2>/dev/null || :
exec >> "$STATE_LOG" 2>&1

echo "[log] installation state share mounted"

if [ -e "$STARTED" ]; then
  echo "[log] installation was already started; refusing to erase the target disk again"
  exec /usr/libexec/recoveryosd
  exit 1
fi

[ -s "$ADMIN_PACKAGE" ] || fail "account package is missing"
[ -s "$SETUP_PACKAGE" ] || fail "Setup Assistant package is missing"

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

printf '%s\n' "$USAGE" | /usr/bin/grep -q -- '--installpackage' ||
  fail "startosinstall does not support --installpackage"

echo "[log] account and Setup Assistant packages passed preflight"

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

ARGS=(
  --volume "$TARGET_VOLUME"
  --agreetolicense
  --nointeraction
  --installpackage "$ADMIN_PACKAGE"
  --installpackage "$SETUP_PACKAGE"
)

echo "[log] starting online macOS installation on $TARGET_VOLUME"
echo "[log] scheduling account and Setup Assistant packages"

# Keep Apple's installer diagnostics visible from the host while Recovery is
# occupied by startosinstall. The stream is diagnostic only and dies naturally
# when Recovery reboots into the next installation stage.
APPLE_INSTALL_LOG="$STATE_DIR/apple.log"
if [ -f /var/log/install.log ]; then
  /usr/bin/tail -n 0 -f /var/log/install.log >> "$APPLE_INSTALL_LOG" 2>&1 &
  echo "[log] streaming Apple install log to $APPLE_INSTALL_LOG"
else
  echo "[log] Apple install log is not available"
fi

"$STARTOSINSTALL" "${ARGS[@]}"
rc=$?

if (( rc != 0 )); then
  rm -f "$STARTED"
  echo "[log] ERROR: startosinstall exited with status $rc"
  printf '%s\n' "$USAGE"
  exec /usr/libexec/recoveryosd
  exit "$rc"
fi

echo "[log] startosinstall completed its prepare phase; waiting for reboot"

while :; do
  sleep 60
done
