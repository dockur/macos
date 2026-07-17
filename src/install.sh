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

BASE_IMG_ID="InstallMedia"
BASE_IMG="$STORAGE/base.dmg"

function getRandom() {

  local length="${1}"
  local result=""
  local chars=("0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "A" "B" "C" "D" "E" "F")

  for ((i=0; i<length; i++)); do
      result+="${chars[$((RANDOM % 16))]}"
  done

  echo "$result"
  return 0
}

delay() {

  local i
  local delay="$1"
  local msg="Retrying failed download in X seconds..."

  info "${msg/X/$delay}"

  for i in $(seq "$delay" -1 1); do
    html "${msg/X/$i}"
    sleep 1
  done

  return 0
}

checkDownloadSize() {

  local file="$1"
  local expected="$2"
  local actual=""

  if [ -z "$expected" ]; then
    warn "Could not determine expected recovery image size."
    return 0
  fi

  actual=$(stat -c%s "$file")

  if [ "$actual" -ne "$expected" ]; then
    error "Downloaded recovery image is incomplete: got $(formatBytes "$actual"), expected $(formatBytes "$expected")."
    return 1
  fi

  return 0
}

function download() {

  local info=""
  local dest="$1"
  local board="$2"
  local version="$3"
  local type="latest"
  local appleSession=""
  local downloadLink=""
  local downloadSession=""
  local expected=""
  local mlb="00000000000000000"
  local reason="" response=""
  local rc=0 code log
  local progress=()
  local output=""

  local msg="Downloading macOS ${version^}"
  info "$msg recovery image..." && html "$msg..."

  appleSession=$(curl --disable --max-time 30 -v -H "Host: osrecovery.apple.com" \
                      -H "Connection: close" \
                      -A "InternetRecovery/1.0" https://osrecovery.apple.com/ 2>&1 | tr ';' '\n' | awk -F'session=|;' '/session=/ {print $2; exit}' || :)

  if [ -z "$appleSession" ]; then
    error "Failed to obtain Apple recovery session."
    return 1
  fi

  log=$(mktemp)
  response=$(mktemp)

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
    code=0
  else
    code=$?
  fi

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

  downloadLink=$(echo "$info" | grep 'oscdn' | grep 'dmg' | head -n 1 || :)
  downloadSession=$(echo "$info" | grep 'expires' | grep 'dmg' | head -n 1 || :)

  if [ -z "$downloadLink" ] || [ -z "$downloadSession" ]; then

    [ -n "$info" ] && echo "$info" && echo
    error "The Apple servers returned an unexpected response."

    return 1
  fi

  expected=$(curl --disable -fsSI \
    -H "Host: oscdn.apple.com" \
    -H "Connection: close" \
    -A "InternetRecovery/1.0" \
    -H "Cookie: AssetToken=${downloadSession}" \
    "$downloadLink" \
    | awk 'tolower($1) == "content-length:" {gsub("\r","",$2); print $2; exit}' || :)

  # Use Wget's progress bar in a terminal and progress.sh in container logs.
  if [ -t 1 ]; then
    progress=( --show-progress --progress=bar:noscroll )
  else
    output="log"
  fi

  rm -f "$dest"
  log=$(mktemp)

  /run/progress.sh "$dest" "${expected:-0}" "$msg ([P])..." "$output" &

  {
    LC_ALL=C wget "$downloadLink" -O "$dest" --no-verbose --timeout=30 \
      --no-http-keep-alive "${progress[@]}" --output-file="$log" \
      --header "Host: oscdn.apple.com" --header "Connection: close" \
      --header "User-Agent: InternetRecovery/1.0" --header "Cookie: AssetToken=${downloadSession}"
    rc=$?
  } || :

  fKill "progress.sh"

  if (( rc != 0 )); then
    reason=$(sed -n \
      -e 's/^wget: //p' \
      -e 's/^[0-9-]\{10\} [0-9:]\{8\} ERROR //p' \
      "$log" | tail -n 1)
  fi

  rm -f "$log"

  if (( rc == 0 )) && [ -f "$dest" ]; then

    if ! checkDownloadSize "$dest" "$expected"; then
      rm -f "$dest"
      return 1
    fi

    if ! checkDmgImage "$dest"; then
      rm -f "$dest"
      return 1
    fi

    return 0
  fi

  msg="Failed to download $downloadLink"

  if (( rc == 3 )); then
    error "$msg because the file could not be written (disk full?)."
  elif [ -n "$reason" ]; then
    error "$msg: ${reason%.}."
  else
    error "$msg with exit status $rc."
  fi

  return 1
}

checkDmgImage() {

  local file="$1"
  local size

  if [ ! -s "$file" ]; then
    error "Downloaded recovery image is missing or empty!"
    return 1
  fi

  size=$(stat -c%s "$file")

  if [ "$size" -lt 100000000 ]; then
    error "Downloaded recovery image is too small: $(formatBytes "$size")"
    return 1
  fi

  info "Checking recovery image format..."

  if ! qemu-img info "$file" >/dev/null; then
    error "Downloaded recovery image is not a valid disk image!"
    return 1
  fi

  return 0
}

install() {

  local board
  local version="$1"
  local dest="$2"

  case "${version,,}" in
    "tahoe" | "26"* | "16"* )
      board="Mac-CFF7D910A743CAAF" ;;
    "sequoia" | "15"* )
      board="Mac-937A206F2EE63C01" ;;
    "sonoma" | "14"* )
      board="Mac-827FAC58A8FDFA22" ;;
    "ventura" | "13"* )
      board="Mac-4B682C642B45593E" ;;
    "monterey" | "12"* )
      board="Mac-B809C3757DA9BB8D" ;;
    "bigsur" | "big-sur" | "11"* )
      board="Mac-2BD1B31983FE1663" ;;
    "catalina" | "10"* )
      board="Mac-00BE6ED71E35EB86" ;;
    *)
      error "Unknown VERSION specified, value \"${version}\" is not recognized!"
      return 1 ;;
  esac

  rm -f "$dest"

  if ! makeDir "$STORAGE"; then
    error "Failed to create directory \"$STORAGE\" !" && return 1
  fi

  find "$STORAGE" -maxdepth 1 -type f \( -iname '*.rom' -or -iname '*.vars' \) -delete

  if [ -f "/boot.dmg" ]; then
    if ! cp "/boot.dmg" "$dest"; then
      error "Failed to copy bundled recovery image to $dest."
      return 1
    fi

    if ! checkDmgImage "$dest"; then
      rm -f "$dest"
      return 1
    fi

    return 0
  fi

  local file="$STORAGE/boot.dmg"

  if ! download "$file" "$board" "$version"; then
    delay 5
    if ! download "$file" "$board" "$version"; then
      rm -f "$file"
      exit 60
    fi
  fi

  if ! mv -f "$file" "$dest"; then
    error "Failed to move recovery image to $dest."
    return 1
  fi

  return 0
}

generateID() {

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

  # Generate Apple MAC address based on UUID value
  MAC=$(echo "$UUID" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/00:16:cb:\3:\4:\5/')
  MAC="${MAC^^}"

  writeState "mac" "$MAC" || return 1

  return 0
}

generateSerial() {

  restoreState SN "sn" || return 1
  restoreState MLB "mlb" || return 1

  [ -n "$SN" ] && [ -n "$MLB" ] && return 0

  # Generate unique serial numbers for machine
  SN=$(/usr/local/bin/macserial --num 1 --model "${MODEL}" 2>/dev/null)

  SN="${SN##*$'\n'}"
  [[ "$SN" != *" | "* ]] && error "$SN" && return 1

  MLB=${SN#*|}
  MLB="${MLB#"${MLB%%[![:space:]]*}"}"
  SN="${SN%%|*}"
  SN="${SN%"${SN##*[![:space:]]}"}"

  writeState "sn" "$SN" || return 1
  writeState "mlb" "$MLB" || return 1

  return 0
}

VERSION=$(strip "$VERSION")

if [ -z "$VERSION" ]; then

  VERSION="14"
  warn "no value specified for the VERSION variable, defaulting to \"${VERSION}\"."

fi

# Keep the current storage location when a primary disk already exists.
if [ ! -s "$BASE_IMG" ] && ! hasDisk; then
  STORAGE="$STORAGE/${VERSION,,}"
  BASE_IMG="$STORAGE/base.dmg"
fi

# Recovery media is required only while the primary disk is absent or blank.
if [ ! -s "$BASE_IMG" ] && ! hasData; then
  ! install "$VERSION" "$BASE_IMG" && exit 34
  ! setOwner "$BASE_IMG" && warn "failed to set the owner for \"$BASE_IMG\" !"
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

DISK_OPTS=""

if [ -s "$BASE_IMG" ]; then
  DISK_OPTS="-device virtio-blk-pci,drive=${BASE_IMG_ID},bus=pcie.0,addr=0x6"
  DISK_OPTS+=" -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=dmg,cache=unsafe,readonly=on,if=none"
fi

return 0
