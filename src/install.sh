#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${VERSION:="sonoma"}"  # OSX Version

TMP="$STORAGE/tmp"
BASE_FILE="BaseSystem"
BASE_IMG_ID="InstallMedia"
BASE_IMG="$STORAGE/base.dmg"
BASE_TMP="$TMP/$BASE_FILE.dmg"

downloadImage() {

  rm -rf "$TMP"
  mkdir -p "$TMP"

  local msg="Downloading macOS ($VERSION) image"
  info "$msg..." && html "$msg..."

  /run/progress.sh "$BASE_TMP" "" "$msg ([P])..." &

  if ! /run/fetch-macOS-v2.py --action download -s "$VERSION" -n "$BASE_FILE" -o "$TMP"; then
    error "Failed to fetch macOS ($VERSION)!"
    fKill "progress.sh"
    return 1
  fi

  fKill "progress.sh"

  if [ ! -f "$BASE_TMP" ] || [ ! -s "$BASE_TMP" ]; then
    error "Failed to find file $BASE_TMP !"
    return 1
  fi

  echo "$VERSION" > "$STORAGE/$PROCESS.version"

  mv "$BASE_TMP" "$BASE_IMG"
  rm -rf "$TMP"

  return 0
}

if [ ! -f "$BASE_IMG" ] || [ ! -s "$BASE_IMG" ]; then
  if ! downloadImage; then
    rm -rf "$TMP"
    exit 34
  fi
fi

STORED_VERSION=$(cat "$STORAGE/$PROCESS.version")

if [ "$VERSION" != "$STORED_VERSION" ]; then
  info "Different version detected, switching base image from $STORED_VERSION to $VERSION"
  if ! downloadImage; then
    rm -rf "$TMP"
    exit 34
  fi
fi

DISK_OPTS="-device virtio-blk-pci,drive=${BASE_IMG_ID},scsi=off,bus=pcie.0,addr=0x6,iothread=io2,bootindex=9"
DISK_OPTS+=" -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=dmg,cache=unsafe,readonly=on,if=none"

return 0
