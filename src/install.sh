#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${VERSION:="ventura"}"  # OSX Version

BASE_FILE="BaseSystem"
BASE_IMG_ID="InstallMedia"
BASE_IMG="$STORAGE/$BASE_FILE.img"
BASE_DMG="$STORAGE/$BASE_FILE.dmg"
BASE_TMP="$STORAGE/$BASE_FILE.tmp"
BASE_CHK="$STORAGE/$BASE_FILE.chunklist"

downloadImage() {

  rm -f "$BASE_DMG"
  rm -f "$BASE_IMG"
  rm -f "$BASE_TMP"

  local msg="Downloading macOS ($VERSION) image"
  info "$msg..." && html "$msg..."

  /run/progress.sh "$BASE_TMP" "" "$msg ([P])..." &

  if ! /run/fetch-macOS-v2.py --action download -s "$VERSION" -n "$BASE_FILE" -o "$STORAGE"; then
    error "Failed to fetch macOS ($VERSION)!"
    fKill "progress.sh"
    return 1
  fi

  fKill "progress.sh"
  
  if [ ! -f "$BASE_DMG" ] || [ ! -s "$BASE_DMG" ]; then
    error "Failed to find $BASE_DMG, aborting..."
    return 1
  fi

  msg="Converting base image format..."
  info "$msg" && html "$msg"

  if ! dmg2img -i "$BASE_DMG" "$BASE_TMP"; then
    error "Failed to convert base image format!"
    return 1
  fi

  rm -f "$BASE_CHK"
  rm -f "$BASE_DMG"
  mv "$BASE_TMP" "$BASE_IMG"

  echo "$VERSION" > "$STORAGE/$PROCESS.version"
}

if [ ! -f "$BASE_IMG" ] || [ ! -s "$BASE_IMG" ]; then
  if ! downloadImage; then
    rm -f "$STORAGE/$BASE_FILE.*"
    exit 34
  fi
fi

STORED_VERSION=$(cat "$STORAGE/$PROCESS.version")

if [ "$VERSION" != "$STORED_VERSION" ]; then
  info "Different version detected, switching base image from $STORED_VERSION to $VERSION"
  if ! downloadImage; then
    rm -f "$STORAGE/$BASE_FILE.*"
    exit 34
  fi
fi

DISK_OPTS="$DISK_OPTS -device virtio-blk-pci,drive=${BASE_IMG_ID},scsi=off,bus=pcie.0,addr=0x6,iothread=io2"
DISK_OPTS="$DISK_OPTS -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=raw,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD,detect-zeroes=off,if=none"

return 0
