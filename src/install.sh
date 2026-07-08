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
  local url="$2"
  local token="$3"
  local expected=""
  local actual=""

  if ! expected=$(curl --disable -fsSI \
      -H "Host: oscdn.apple.com" \
      -H "Connection: close" \
      -A "InternetRecovery/1.0" \
      -H "Cookie: AssetToken=${token}" \
      "$url" \
      | awk 'tolower($1) == "content-length:" {gsub("\r","",$2); print $2; exit}'); then
    warn "Could not verify recovery image size."
    return 0
  fi

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

  if ! qemu-img info "$file" >/dev/null; then
    error "Downloaded recovery image is not a valid disk image!"
    return 1
  fi

  if ! qemu-img check "$file" >/dev/null; then
    error "Downloaded recovery image failed integrity check!"
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
  local mlb="00000000000000000"
  local rc progress

  local msg="Downloading macOS ${version^}"
  info "$msg recovery image..." && html "$msg..."

  appleSession=$(curl --disable --max-time 30 -v -H "Host: osrecovery.apple.com" \
                      -H "Connection: close" \
                      -A "InternetRecovery/1.0" https://osrecovery.apple.com/ 2>&1 | tr ';' '\n' | awk -F'session=|;' '/session=/ {print $2; exit}' || :)

  if [ -z "$appleSession" ]; then
    error "Failed to obtain Apple recovery session."
    return 1
  fi

  info=$(curl --disable --max-time 60 -s -X POST -H "Host: osrecovery.apple.com" \
                           -H "Connection: close" \
                           -A "InternetRecovery/1.0" \
                           -b "session=\"${appleSession}\"" \
                           -H "Content-Type: text/plain" \
                           -d $'cid='"$(getRandom 16)"$'\nsn='"${mlb}"$'\nbid='"${board}"$'\nk='"$(getRandom 64)"$'\nfg='"$(getRandom 64)"$'\nos='"${type}" \
                           https://osrecovery.apple.com/InstallationPayload/RecoveryImage | tr ' ' '\n')

  downloadLink=$(echo "$info" | grep 'oscdn' | grep 'dmg' | head -n 1 || :)
  downloadSession=$(echo "$info" | grep 'expires' | grep 'dmg' | head -n 1 || :)

  if [ -z "$downloadLink" ] || [ -z "$downloadSession" ]; then

    local code="99"
    msg="Failed to connect to the Apple servers, reason:"

    curl --silent --max-time 10 --output /dev/null --fail -H "Host: osrecovery.apple.com" -H "Connection: close" -A "InternetRecovery/1.0" https://osrecovery.apple.com/ || {
      code="$?"
    }

    case "${code,,}" in
      "6" ) error "$msg could not resolve host!" ;;
      "7" ) error "$msg no internet connection available!" ;;
      "28" ) error "$msg connection timed out!" ;;
      "99" )
        [ -n "$info" ] && echo "$info" && echo
        error "$msg unknown error" ;;
      *) error "$msg $code" ;;
    esac

    return 1
  fi

  # Check if running with interactive TTY or redirected to docker log
  if [ -t 1 ]; then
    progress="--progress=bar:noscroll"
  else
    progress="--progress=dot:giga"
  fi

  rm -f "$dest"
  /run/progress.sh "$dest" "0" "$msg ([P])..." &

  { wget "$downloadLink" -O "$dest" -q --header "Host: oscdn.apple.com" --header "Connection: close" --header "User-Agent: InternetRecovery/1.0" --header "Cookie: AssetToken=${downloadSession}" --timeout=30 --no-http-keep-alive --show-progress "$progress"; rc=$?; } || :

  fKill "progress.sh"

  if (( rc == 0 )) && [ -f "$dest" ]; then

    if ! checkDownloadSize "$dest" "$downloadLink" "$downloadSession"; then
      rm -f "$dest"
      return 1
    fi

    if ! checkDmgImage "$dest"; then
      rm -f "$dest"
      return 1
    fi

    html "Download finished successfully..."
    return 0
  fi

  msg="Failed to download $downloadLink"
  (( rc == 3 )) && error "$msg , cannot write file (disk full?)" && return 1
  (( rc == 4 )) && error "$msg , network failure!" && return 1
  (( rc == 8 )) && error "$msg , server issued an error response!" && return 1

  error "$msg , reason: $rc"
  return 1
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
  find "$STORAGE" -maxdepth 1 -type f \( -iname 'data.*' -or -iname 'macos.*' \) -delete

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

  local file="$STORAGE/$PROCESS.id"

  [ -n "$UUID" ] && return 0
  [ -s "$file" ] && UUID=$(<"$file")
  UUID="${UUID//[![:print:]]/}"
  [ -n "$UUID" ] && return 0

  if ! UUID=$(cat /proc/sys/kernel/random/uuid 2> /dev/null || uuidgen --random); then
    return 1
  fi

  UUID="${UUID^^}"
  UUID="${UUID//[![:print:]]/}"

  if [ -z "$UUID" ]; then
    return 1
  fi

  if ! echo "$UUID" > "$file"; then
    return 1
  fi

  ! setOwner "$file" && error "Failed to set the owner for \"$file\" !"

  return 0
}

generateAddress() {

  local file="$STORAGE/$PROCESS.mac"

  [ -n "$MAC" ] && return 0
  [ -s "$file" ] && MAC=$(<"$file")
  MAC="${MAC//[![:print:]]/}"
  [ -n "$MAC" ] && return 0

  # Generate Apple MAC address based on UUID value
  MAC=$(echo "$UUID" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/00:16:cb:\3:\4:\5/')
  MAC="${MAC^^}"

  if ! echo "$MAC" > "$file"; then
    return 1
  fi
  
  ! setOwner "$file" && error "Failed to set the owner for \"$file\" !"

  return 0
}

generateSerial() {

  local file="$STORAGE/$PROCESS.sn"
  local file2="$STORAGE/$PROCESS.mlb"

  [ -n "$SN" ] && [ -n "$MLB" ] && return 0
  [ -s "$file" ] && SN=$(<"$file")
  [ -s "$file2" ] && MLB=$(<"$file2")
  SN="${SN//[![:print:]]/}"
  MLB="${MLB//[![:print:]]/}"
  [ -n "$SN" ] && [ -n "$MLB" ] && return 0

  # Generate unique serial numbers for machine
  SN=$(/usr/local/bin/macserial --num 1 --model "${MODEL}" 2>/dev/null)

  SN="${SN##*$'\n'}"
  [[ "$SN" != *" | "* ]] && error "$SN" && return 1

  MLB=${SN#*|}
  MLB="${MLB#"${MLB%%[![:space:]]*}"}"
  SN="${SN%%|*}"
  SN="${SN%"${SN##*[![:space:]]}"}"

  if ! echo "$SN" > "$file"; then
    return 1
  fi

  if ! echo "$MLB" > "$file2"; then
    return 1
  fi

  ! setOwner "$file" && error "Failed to set the owner for \"$file\" !"
  ! setOwner "$file2" && error "Failed to set the owner for \"$file2\" !"

  return 0
}

VERSION=$(strip "$VERSION")

if [ -z "$VERSION" ]; then

  VERSION="14"
  warn "no value specified for the VERSION variable, defaulting to \"${VERSION}\"."

fi

if [ ! -f "$BASE_IMG" ] || [ ! -s "$BASE_IMG" ]; then

  STORAGE="$STORAGE/${VERSION,,}"
  BASE_IMG="$STORAGE/base.dmg"

  if [ ! -f "$BASE_IMG" ] || [ ! -s "$BASE_IMG" ]; then
    ! install "$VERSION" "$BASE_IMG" && exit 34
    ! setOwner "$BASE_IMG" && error "Failed to set the owner for \"$BASE_IMG\" !"
  fi

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

DISK_OPTS="-device virtio-blk-pci,drive=${BASE_IMG_ID},bus=pcie.0,addr=0x6"
DISK_OPTS+=" -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=dmg,cache=unsafe,readonly=on,if=none"

return 0
