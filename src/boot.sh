#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${BOOT_MODE:="full"}"  # Boot mode

BOOT_DESC=""
BOOT_OPTS=""
BOOT_DRIVE_ID="OpenCoreBoot"
BOOT_DRIVE="/images/OpenCore.qcow2"

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

BOOT_OPTS="$BOOT_OPTS -smbios type=2"
BOOT_OPTS="$BOOT_OPTS -rtc base=utc,base=localtime"
BOOT_OPTS="$BOOT_OPTS -global ICH9-LPC.disable_s3=1"
BOOT_OPTS="$BOOT_OPTS -global ICH9-LPC.disable_s4=1"
BOOT_OPTS="$BOOT_OPTS -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"

osk=$(echo "bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap" | tr 'A-Za-z' 'N-ZA-Mn-za-m')
BOOT_OPTS="$BOOT_OPTS -device isa-applesmc,osk=$osk"

# OVMF
BOOT_OPTS="$BOOT_OPTS -drive if=pflash,format=raw,readonly=on,file=$OVMF/$ROM"
BOOT_OPTS="$BOOT_OPTS -drive if=pflash,format=raw,file=$OVMF/$VARS"

# OpenCoreBoot
DISK_OPTS="$DISK_OPTS -device virtio-blk-pci,drive=${BOOT_DRIVE_ID},scsi=off,bus=pcie.0,addr=0x5,iothread=io2,bootindex=1"
DISK_OPTS="$DISK_OPTS -drive file=$BOOT_DRIVE,id=$BOOT_DRIVE_ID,format=qcow2,cache=$DISK_CACHE,aio=$DISK_IO,readonly=on,if=none"

CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')
CPU_FLAGS="vendor=GenuineIntel,vmware-cpuid-freq=on"

if [[ "$CPU_VENDOR" != "GenuineIntel" ]]; then
  CPU_MODEL="Haswell-noTSX"
fi
  
USB="nec-usb-xhci,id=xhci"
USB="$USB -device usb-kbd,bus=xhci.0"
USB="$USB -global nec-usb-xhci.msi=off"

return 0
