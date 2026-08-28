#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${SN:=""}"                # Device serial
: "${MLB:=""}"               # Board serial
: "${MAC:=""}"               # MAC address
: "${UUID:=""}"              # Unique ID
: "${VERSION:=""}"           # OSX Version
: "${WIDTH:="1920"}"         # Horizontal
: "${HEIGHT:="1080"}"        # Vertical
: "${MODEL:="iMacPro1,1"}"   # Device model

# Sanitize variables
SN=$(strip "$SN")
MLB=$(strip "$MLB")
MAC=$(strip "$MAC")
UUID=$(strip "$UUID")
MODEL=$(strip "$MODEL")
WIDTH=$(strip "$WIDTH")
HEIGHT=$(strip "$HEIGHT")

BASE_IMG="$STORAGE/setup.dmg"

# Fixed setup values for the unattended-install proof. These are intentionally
# not environment variables yet; locale settings will be implemented only
# after the basic zero-click path has been proven.
SETUP_USERNAME="admin"
SETUP_PASSWORD="admin"
SETUP_AUTOLOGIN="Y"
SETUP_LANGUAGE="en-US"
SETUP_REGION="US"
SETUP_KEYBOARD="U.S."
SETUP_TIMEZONE="Etc/UTC"

function getRandom() {

  local length="${1}"
  local result=""
  local chars=("0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "A" "B" "C" "D" "E" "F")

  # Apple recovery requests require opaque hexadecimal nonce fields; they
  # are session tokens rather than persistent machine identity.
  for ((i=0; i<length; i++)); do
      result+="${chars[$((RANDOM % 16))]}"
  done

  echo "$result"
  return 0
}

checkDownloadSize() {

  local file="$1"
  local expected="$2"
  local actual

  if [ -z "$expected" ]; then
    warn "Could not determine expected recovery image size."
    return 0
  fi

  if ! actual=$(stat -c%s -- "$file" 2>/dev/null); then
    error "Failed to determine downloaded recovery image size."
    return 1
  fi

  if (( actual != expected )); then
    error "Downloaded recovery image is incomplete: got $(formatBytes "$actual"), expected $(formatBytes "$expected")."
    return 1
  fi

  return 0
}

function download() {

  local info
  local dest="$1"
  local board="$2"
  local version="$3"
  local connections="${4:-1}"
  local type="latest"
  local appleSession
  local downloadLink
  local downloadSession
  local log expected
  local mlb="00000000000000000"
  local reason response

  local msg="Downloading macOS ${version^}"
  info "$msg recovery image..." && html "$msg..."

  # The initial request exists only to obtain Apple's recovery-session cookie
  # from the verbose response headers.
  appleSession=$(curl --disable --max-time 30 -v -H "Host: osrecovery.apple.com" \
                      -H "Connection: close" \
                      -A "InternetRecovery/1.0" https://osrecovery.apple.com/ 2>&1 | tr ';' '\n' | awk -F'session=|;' '/session=/ {print $2; exit}' || :)

  if [ -z "$appleSession" ]; then
    error "Failed to obtain Apple recovery session."
    return 1
  fi

  log=$(mktemp)
  response=$(mktemp)

  # Submit the board identifier and fresh request nonces while capturing both
  # Apple's text response and curl's diagnostic output separately.
  if curl --disable --max-time 60 --silent --show-error --fail-with-body \
      --request POST \
      --header "Host: osrecovery.apple.com" \
      --header "Connection: close" \
      --user-agent "InternetRecovery/1.0" \
      --cookie "session=\"${appleSession}\"" \
      --header "Content-Type: text/plain" \
      --data $'cid='"$(getRandom 16)"$'\nsn='"${mlb}"$'\nbid='"${board}"$'\nk='"$(getRandom 64)"$'\nfg='"$(getRandom 64)"$'\nos='"${type}" \
      --output "$response" \
      https://osrecovery.apple.com/InstallationPayload/RecoveryImage \
      2>"$log"; then
    local code=0
  else
    local code=$?
  fi

  # Apple's response is space-delimited key/value text. Splitting it into
  # records makes the image URL and expiring asset token selectable below.
  info=$(tr ' ' '\n' < "$response")
  reason=$(sed -En 's/^curl: \([0-9]+\) //p' "$log" | tail -n 1)

  rm -f "$response" "$log"

  if (( code != 0 )); then

    msg="Failed to connect to the Apple servers"

    if [ -n "$reason" ]; then
      error "$msg: ${reason%.}."
    else
      error "$msg with exit status $code."
    fi

    return 1
  fi

  # The recovery response supplies the CDN URL and its expiring token as
  # separate records; both are required for the authenticated download.
  downloadLink=$(echo "$info" | grep 'oscdn' | grep 'dmg' | head -n 1 || :)
  downloadSession=$(echo "$info" | grep 'expires' | grep 'dmg' | head -n 1 || :)

  if [ -z "$downloadLink" ] || [ -z "$downloadSession" ]; then

    [ -n "$info" ] && echo "$info" && echo
    error "The Apple servers returned an unexpected response."

    return 1
  fi

  # Content-Length is optional validation metadata. The DMG format checks
  # below remain authoritative when the CDN omits it.
  expected=$(curl --disable -fsSI \
    -H "Host: oscdn.apple.com" \
    -H "Connection: close" \
    -A "InternetRecovery/1.0" \
    -H "Cookie: AssetToken=${downloadSession}" \
    "$downloadLink" \
    | awk 'tolower($1) == "content-length:" {gsub("\r","",$2); print $2; exit}' || :)

  # Each attempt uses a newly issued Apple download session, so do not
  # resume a partial download created with an older session.
  rm -f -- "$dest" "$dest.aria2"

  if downloadToFile \
      "$downloadLink" \
      "$dest" \
      "$msg" \
      "${expected:-0}" \
      "$connections" \
      "N" \
      --header "Host: oscdn.apple.com" \
      --header "Connection: close" \
      --user-agent "InternetRecovery/1.0" \
      --header "Cookie: AssetToken=${downloadSession}"; then
    local rc=0
  else
    local rc=$?
  fi

  if (( rc != 0 )); then
    rm -f -- "$dest" "$dest.aria2"
    return "$rc"
  fi

  if ! checkDownloadSize "$dest" "$expected"; then
    rm -f -- "$dest" "$dest.aria2"
    return 1
  fi

  if ! checkDmgImage "$dest"; then
    rm -f -- "$dest" "$dest.aria2"
    return 1
  fi

  return 0
}

install() {

  local version="$1"
  local dest="$2"

  local file="$STORAGE/tmp/recovery.dmg"

  # Apple recovery catalogs are selected by board identifier, so each macOS
  # generation maps to a model known to receive that release.
  case "${version,,}" in
    "tahoe" | "26"* | "16"* )
      local board="Mac-CFF7D910A743CAAF" ;;
    "sequoia" | "15"* )
      local board="Mac-937A206F2EE63C01" ;;
    "sonoma" | "14"* )
      local board="Mac-827FAC58A8FDFA22" ;;
    "ventura" | "13"* )
      local board="Mac-4B682C642B45593E" ;;
    "monterey" | "12"* )
      local board="Mac-B809C3757DA9BB8D" ;;
    "bigsur" | "big-sur" | "11"* )
      local board="Mac-2BD1B31983FE1663" ;;
    "catalina" | "10"* )
      local board="Mac-00BE6ED71E35EB86" ;;
    *)
      error "Unknown VERSION specified, value \"${version}\" is not recognized!"
      return 1 ;;
  esac

  rm -f "$dest" "$dest.tmp"

  if ! makeDir "$STORAGE"; then
    error "Failed to create directory \"$STORAGE\" !"
    return 1
  fi

  if ! makeDir "$STORAGE/tmp"; then
    error "Failed to create directory \"$STORAGE/tmp\" !"
    return 1
  fi

  # New recovery media invalidates cached firmware state that may still point
  # at an older installer or incompatible boot entry.
  find "$STORAGE" -maxdepth 1 -type f \( -iname '*.rom' -or -iname '*.vars' \) -delete

  rm -f -- "$file" "$file.aria2"

  # Try a multi-connection recovery download first.
  if download "$file" "$board" "$version" "${CONNECTIONS:-1}"; then
    local rc=0
  else
    local rc=$?
  fi

  if (( rc != 0 )); then

    # Status 2 represents deterministic download validation failure, so a
    # second transport attempt cannot recover it.
    if (( rc == 2 )); then
      rm -f -- "$file" "$file.aria2"
      exit 60
    fi

    delay 5

    # Obtain a fresh Apple session and retry with single-connection Wget.
    if ! download "$file" "$board" "$version" "1"; then
      rm -f -- "$file" "$file.aria2"
      exit 60
    fi

  fi

  if ! prepareAutomatedRecovery "$file" "$dest"; then
    rm -f -- "$file" "$file.aria2"
    return 1
  fi

  rm -f -- "$file" "$file.aria2"
  return 0
}

generateID() {

  # Machine identity must remain stable across restarts because OpenCore,
  # macOS activation, and the generated network identity all depend on it.
  restoreState UUID "id" || return 1

  [ -n "$UUID" ] && return 0

  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen --random) || return 1
  UUID="${UUID^^}"
  UUID="${UUID//[![:print:]]/}"

  [ -z "$UUID" ] && return 1

  writeState "id" "$UUID" || return 1

  return 0
}

generateAddress() {

  restoreState MAC "mac" || return 1

  [ -n "$MAC" ] && return 0

  # Derive a stable address from the UUID while retaining the Apple-assigned
  # 00:16:CB prefix expected by the generated OpenCore identity.
  # Generate Apple MAC address based on UUID value
  MAC=$(echo "$UUID" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/00:16:cb:\3:\4:\5/')
  MAC="${MAC^^}"

  writeState "mac" "$MAC" || return 1

  return 0
}

generateSerial() {

  local generated generatedSN generatedMLB

  restoreState SN "sn" || return 1
  restoreState MLB "mlb" || return 1

  [ -n "$SN" ] && [ -n "$MLB" ] && return 0

  # Generate a serial pair and use only the values that are still missing,
  # preserving any serial or board serial supplied by the user or restored from state.
  generated=$(/usr/local/bin/macserial --num 1 --model "${MODEL}" 2>/dev/null)

  generated="${generated##*$'\n'}"
  [[ "$generated" != *" | "* ]] && error "$generated" && return 1

  generatedMLB=${generated#*|}
  generatedMLB="${generatedMLB#"${generatedMLB%%[![:space:]]*}"}"
  generatedSN="${generated%%|*}"
  generatedSN="${generatedSN%"${generatedSN##*[![:space:]]}"}"

  [ -n "$SN" ] || SN="$generatedSN"
  [ -n "$MLB" ] || MLB="$generatedMLB"

  writeState "sn" "$SN" || return 1
  writeState "mlb" "$MLB" || return 1

  return 0
}

VERSION=$(strip "$VERSION")

if [ -z "$VERSION" ]; then

  VERSION="14"
  warn "no value specified for the VERSION variable, defaulting to \"${VERSION}\"."

fi

# Use version-specific storage so each macOS version has its own folder.
# Switching VERSION selects the corresponding existing installation without
# overwriting existing disks or redownloading the installation media again.
if [ ! -s "$BASE_IMG" ] && ! hasDisk; then
  STORAGE="$STORAGE/${VERSION,,}"
  BASE_IMG="$STORAGE/setup.dmg"
fi

# Recovery media is required only while the primary disk is absent or blank.
if [ ! -s "$BASE_IMG" ] && ! hasData; then
  install "$VERSION" "$BASE_IMG" || exit 34
  setOwner "$BASE_IMG" || warn "failed to set the owner for \"$BASE_IMG\" !"
fi

if ! generateID; then
  error "Failed to generate UUID!" && exit 35
fi

if ! generateSerial; then
  error "Failed to generate serial number!" && exit 36
fi

if ! generateAddress; then
  error "Failed to generate MAC address!" && exit 37
fi

INSTALL_STATE_DIR="$QEMU_DIR/installstate"
rm -rf "$INSTALL_STATE_DIR"

if [ -s "$BASE_IMG" ]; then

  if ! makeDir "$STORAGE/tmp"; then
    error "Failed to create temporary installation directory."
    exit 34
  fi

  if ! prepareInstallationState "$INSTALL_STATE_DIR"; then
    exit 34
  fi

fi

# All installation preparation is complete at this point. Nothing below needs
# persistent scratch data, so never carry version-specific tmp files into QEMU.
if ! rm -rf "$STORAGE/tmp"; then
  error "Failed to remove temporary installation files."
  exit 34
fi

DISK_OPTS=""

# OpenCore uses PCI 0x5. The generic disk layer attaches setup.dmg at 0x6,
# while the state/log share is pinned at 0x7 and managed disks use 0xA-0xF.
if [ -s "$BASE_IMG" ]; then
  DISK_OPTS="-fsdev local,id=installstatefs,path=$INSTALL_STATE_DIR,security_model=none"
  DISK_OPTS+=" -device virtio-9p-pci,id=installstate9p,fsdev=installstatefs,mount_tag=installstate,bus=pcie.0,addr=0x7"
fi

return 0
