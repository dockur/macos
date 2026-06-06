#!/usr/bin/env bash
set -Eeuo pipefail

: "${APP:="macOS"}"
: "${VGA:="vmware"}"
: "${SHUTDOWN:="Y"}"
: "${TIMEOUT:="115"}"
: "${PLATFORM:="x64"}"
: "${DISK_TYPE:="blk"}"
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
. cpu.sh        # Configure CPU model
. proc.sh       # Initialize processor
. power.sh      # Configure shutdown
. memory.sh     # Check available memory
. balloon.sh    # Initialize ballooning
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

cmd=(qemu-system-x86_64)
version=$("${cmd[@]}" --version | awk 'NR==1 { print $4 }')
info "Booting ${APP}${BOOT_DESC} using QEMU v$version..."

pipe="$QEMU_DIR/qemu.pipe"
rm -f "$pipe" && mkfifo "$pipe"

sed -u \
  -e 's/\x1B\[[=0-9;]*[a-z]//gi' \
  -e 's/\x1B\x63//g' \
  -e 's/\x1B\[[=?]7l//g' \
  -e '/^$/d' \
  -e 's/\x44\x53\x73//g' \
  -e 's/failed to load Boot/skipped Boot/g' \
  <"$pipe" &

if [[ "$SHUTDOWN" != [Yy1]* ]]; then
  exec "${cmd[@]}" ${ARGS:+ $ARGS} >"$pipe"
fi

"${cmd[@]}" ${ARGS:+ $ARGS} >"$pipe" &

rc=0
wait $! || rc=$?
[ -f "$QEMU_END" ] && exit "$rc"

sleep 1 & wait $!
finish "$rc"
