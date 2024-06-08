#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${VERSION:="sonoma"}"  # OSX Version

TMP="$STORAGE/tmp"
BASE_IMG_ID="InstallMedia"
BASE_IMG="$STORAGE/base.dmg"

downloadImage() {

  local board
  local version="$1"
  local file="BaseSystem"
  local path="$TMP/$file.dmg"

  case "${version,,}" in
    "sonoma" | "14"* )
      board="Mac-A61BADE1FDAD7B05" ;;
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

  local msg="Downloading macOS ($version) image"
  info "$msg..." && html "$msg..."

  rm -rf "$TMP"
  mkdir -p "$TMP"

  /run/progress.sh "$path" "" "$msg ([P])..." &

  if ! /run/fetch-macOS-v2.py --action download -b "$board" -n "$file" -o "$TMP"; then
    error "Failed to fetch macOS \"$version\" with board id \"$board\"!"
    fKill "progress.sh"
    return 1
  fi

  fKill "progress.sh"

  if [ ! -f "$path" ] || [ ! -s "$path" ]; then
    error "Failed to find file \"$path\" !"
    return 1
  fi

  echo "$version" > "$STORAGE/$PROCESS.version"

  mv "$path" "$BASE_IMG"
  rm -rf "$TMP"

  return 0
}

if [ ! -f "$BASE_IMG" ] || [ ! -s "$BASE_IMG" ]; then
  if ! downloadImage "$VERSION"; then
    rm -rf "$TMP"
    exit 34
  fi
fi

STORED_VERSION=$(cat "$STORAGE/$PROCESS.version")

if [ "$VERSION" != "$STORED_VERSION" ]; then
  info "Different version detected, switching base image from $STORED_VERSION to $VERSION"
  if ! downloadImage "$VERSION"; then
    rm -rf "$TMP"
    exit 34
  fi
fi

DISK_OPTS="-device virtio-blk-pci,drive=${BASE_IMG_ID},scsi=off,bus=pcie.0,addr=0x6,iothread=io2"
DISK_OPTS+=" -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=dmg,cache=unsafe,readonly=on,if=none"

return 0
