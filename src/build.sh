#!/usr/bin/env bash
set -Eeuo pipefail

function msg() {
  local txt="$1"
  local bold="\x1b[1m"
  local normal="\x1b[0m"
  echo -e "${bold}### ${txt}${normal}"
}

function cleanup() {
  if test "$GUESTFISH_PID" != ""; then
    guestfish --remote -- exit >/dev/null 2>&1 || true
  fi
}

function fish() {
  echo "#" "$@"
  guestfish --remote -- "$@" || exit 1
}

rm -rf /images
msg "Mounting template ISO..."

trap 'cleanup' EXIT

export LIBGUESTFS_BACKEND=direct
# shellcheck disable=SC2046
eval $(guestfish --listen)
if test "$GUESTFISH_PID" = ""; then
  echo "ERROR: Starting Guestfish failed!"
  exit 1
fi

fish add "$1"
fish run
fish mount /dev/sda1 /
fish ls /EFI

msg "Overriding config..."

fish copy-in "$2" /EFI/OC/
fish umount-all

mkdir -p /images
mv "$1" /images/OpenCore.img

msg "Finished succesfully!"
