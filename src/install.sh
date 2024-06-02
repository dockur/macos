#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${VERSION:="ventura"}"  # OSX Version

BASE_IMG_ID="InstallMedia"
BASE_IMG="$STORAGE/BaseSystem.img"

downloadImage() {

  local msg="Downloading $APP $VERSION image..."
  info "$msg" && html "$msg"

  if ! /run/fetch-macOS-v2.py -s "$VERSION"; then
    error "Failed to fetch MacOS $VERSION!"
    return 1
  fi

  msg="Converting base image format..."
  info "$msg" && html "$msg"

  if ! dmg2img -i BaseSystem.dmg "$BASE_IMG"; then
    error "Failed to convert base image format!"
    return 1
  fi

  rm -f BaseSystem.dmg

  echo "$VERSION" > "$STORAGE/$PROCESS.version"
}

if [ ! -f "$BASE_IMG" ]; then
  ! downloadImage && exit 34
fi

STORED_VERSION=$(cat "$STORAGE/$PROCESS.version")

if [ "$VERSION" != "$STORED_VERSION" ]; then
  info "Different version detected, switching base image from $STORED_VERSION to $VERSION"
  rm -f "$BASE_IMG"
  ! downloadImage && exit 34
fi

DISK_OPTS="$DISK_OPTS -device virtio-blk-pci,drive=${BASE_IMG_ID},scsi=off,bus=pcie.0,addr=0x6,iothread=io2"
DISK_OPTS="$DISK_OPTS -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=raw,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD,detect-zeroes=on,if=none"

return 0
