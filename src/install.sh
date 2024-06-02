#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${VERSION:="ventura"}"  # OSX Version

BASE_IMG="$STORAGE/BaseSystem.img"
BASE_IMG_ID="InstallMedia"
BASE_IMG_BUS="ide.4"

downloadImage() {

  local msg="Downloading $APP $VERSION image..."
  info "$msg" && html "$msg"

  /run/fetch-macOS-v2.py -s "$VERSION"

  msg="Converting image format..."
  info "$msg" && html "$msg"

  dmg2img -i BaseSystem.dmg "$BASE_IMG"
  rm -f BaseSystem.dmg

  echo "$VERSION" > "$STORAGE/$PROCESS.version"
}

if [ ! -f "$BASE_IMG" ]; then
  downloadImage
fi

STORED_VERSION=$(cat "$STORAGE/$PROCESS.version")

if [ "$VERSION" != "$STORED_VERSION" ]; then
  info "Different version detected switching base image from $STORED_VERSION to $VERSION"
  rm -f "$BASE_IMG"
  downloadImage
fi

DISK_OPTS="$DISK_OPTS -device ide-hd,drive=$BASE_IMG_ID,bus=$BASE_IMG_BUS,rotation_rate=1"
DISK_OPTS="$DISK_OPTS -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=raw,cache=writeback,aio=threads,discard=on,detect-zeroes=on,if=none"

return 0
