#!/usr/bin/env bash
set -Eeuo pipefail

: "${APP:="macOS"}"
: "${VGA:="vmware"}"
: "${DISK_TYPE:="blk"}"
: "${PLATFORM:="x64"}"
: "${SUPPORT:="https://github.com/dockur/macos"}"

cd /run

. start.sh      # Startup hook
. utils.sh      # Load functions
. reset.sh      # Initialize system
. server.sh     # Start webserver
. install.sh    # Get the OSX images
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. power.sh      # Configure shutdown
. memory.sh     # Check available memory
. balloon.sh    # Initialize ballooning
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

version=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1 | awk '{ print $NF }')
info "Booting ${APP}${BOOT_DESC} using QEMU v$version..."

[[ "$SHUTDOWN" != [Yy1]* ]] && exec qemu-system-x86_64 ${ARGS:+ $ARGS}

if [ ! -t 1 ] || [ ! -c /dev/tty ]; then
  qemu-system-x86_64 ${ARGS:+ $ARGS} &
else
  qemu-system-x86_64 ${ARGS:+ $ARGS} </dev/tty >/dev/tty &
fi

rc=0
wait $! || rc=$?
[ -f "$QEMU_END" ] && exit "$rc"

sleep 1 & wait $!
finish "$rc"
