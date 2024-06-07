#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${BOOT_MODE:="full"}"  # Boot mode

BOOT_DESC=""
BOOT_OPTS=""
BOOT_DRIVE_ID="OpenCoreBoot"
BOOT_DRIVE="/images/OpenCore.img"

SECURE="off"
OVMF="/usr/share/OVMF"

case "${BOOT_MODE,,}" in
  full)
    DEST="macos"
    BOOT_DESC=" 1920x1080"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1920x1080.fd"
    ;;
  hd)
    DEST="macos_hd"
    BOOT_DESC=" 1024x768"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1024x768.fd"
    ;;
  default)
    BOOT_DESC=""
    DEST="macos_default"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS.fd"
    ;;
  *)
    error "Unknown BOOT_MODE, value \"${BOOT_MODE}\" is not recognized!"
    exit 33
    ;;
esac

BOOT_OPTS+=" -smbios type=2"
BOOT_OPTS+=" -rtc base=utc,base=localtime"
BOOT_OPTS+=" -global ICH9-LPC.disable_s3=1"
BOOT_OPTS+=" -global ICH9-LPC.disable_s4=1"
BOOT_OPTS+=" -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"

osk=$(echo "bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap" | tr 'A-Za-z' 'N-ZA-Mn-za-m')
BOOT_OPTS+=" -device isa-applesmc,osk=$osk"

# OVMF
DEST="$STORAGE/$DEST"

if [ ! -s "$DEST.rom" ] || [ ! -f "$DEST.rom" ]; then
  [ ! -s "$OVMF/$ROM" ] || [ ! -f "$OVMF/$ROM" ] && error "UEFI boot file ($OVMF/$ROM) not found!" && exit 44
  cp "$OVMF/$ROM" "$DEST.rom"
fi

if [ ! -s "$DEST.vars" ] || [ ! -f "$DEST.vars" ]; then
  [ ! -s "$OVMF/$VARS" ] || [ ! -f "$OVMF/$VARS" ]&& error "UEFI vars file ($OVMF/$VARS) not found!" && exit 45
  cp "$OVMF/$VARS" "$DEST.vars"
fi

BOOT_OPTS+=" -drive if=pflash,format=raw,readonly=on,file=$DEST.rom"
BOOT_OPTS+=" -drive if=pflash,format=raw,file=$DEST.vars"

# OpenCoreBoot
DISK_OPTS+=" -device virtio-blk-pci,drive=${BOOT_DRIVE_ID},scsi=off,bus=pcie.0,addr=0x5,iothread=io2,bootindex=$BOOT_INDEX"
DISK_OPTS+=" -drive file=$BOOT_DRIVE,id=$BOOT_DRIVE_ID,format=raw,cache=$DISK_CACHE,aio=$DISK_IO,readonly=on,if=none"

CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')
CPU_FLAGS="vendor=GenuineIntel,vmware-cpuid-freq=on,-pdpe1gb"

if [[ "$CPU_VENDOR" != "GenuineIntel" ]]; then
  CPU_MODEL="Haswell-noTSX"
fi

USB="nec-usb-xhci,id=xhci"
USB+=" -device usb-kbd,bus=xhci.0"
USB+=" -global nec-usb-xhci.msi=off"

return 0
