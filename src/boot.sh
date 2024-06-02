#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${BOOT_MODE:="full"}"  # Boot mode

BOOT_DESC=""
BOOT_OPTS=""
BOOT_DRIVE="/images/OpenCore.qcow2"
BOOT_DRIVE_ID="OpenCoreBoot"
BOOT_DRIVE_BUS="ide.2"
SECURE="off"
OVMF="/usr/share/OVMF"

case "${BOOT_MODE,,}" in
  full)
    BOOT_DESC=" 1920x1080"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1920x1080.fd"
    ;;
  hd)
    BOOT_DESC=" 1024x768"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1024x768.fd"
    ;;
  default)
    BOOT_DESC=""
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS.fd"
    ;;
  *)
    error "Unknown BOOT_MODE, value \"${BOOT_MODE}\" is not recognized!"
    exit 33
    ;;
esac

BOOT_OPTS="$BOOT_OPTS -smbios type=2 -device vmware-svga,bus=pcie.0,addr=0x5 -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
BOOT_OPTS="$BOOT_OPTS -device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
# OVMF
BOOT_OPTS="$BOOT_OPTS -drive if=pflash,format=raw,readonly=on,file=$OVMF/$ROM"
BOOT_OPTS="$BOOT_OPTS -drive if=pflash,format=raw,file=$OVMF/$VARS"
# OpenCoreBoot
BOOT_OPTS="$BOOT_OPTS -device ide-hd,drive=$BOOT_DRIVE_ID,bus=$BOOT_DRIVE_BUS,rotation_rate=1,bootindex=1"
BOOT_OPTS="$BOOT_OPTS -drive file=$BOOT_DRIVE,id=$BOOT_DRIVE_ID,format=qcow2,cache=writeback,aio=threads,discard=on,detect-zeroes=on,if=none"

return 0
