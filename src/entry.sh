#!/usr/bin/env bash
set -Eeuo pipefail

: "${DISK_TYPE:="ide"}"
: "${USB:="qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0"}"

APP="OSX"
SUPPORT="https://github.com/dockur/osx/"

cd /run

. reset.sh      # Initialize system
. disk.sh       # Initialize disks
. install.sh    # Get the osx images
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. config.sh     # Configure arguments

trap - ERR

version=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1 | awk '{ print $NF }')
info "Booting ${APP}${BOOT_DESC} using QEMU v$version..."

exec qemu-system-x86_64 ${ARGS:+ $ARGS}
