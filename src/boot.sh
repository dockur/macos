#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${BOOT_MODE:="full"}"  # Boot mode

BOOT_DESC=""
BOOT_OPTS=""
SECURE="off"
OVMF="/usr/share/OVMF"

case "${BOOT_MODE,,}" in
  "full" )
    DEST="$PROCESS"
    BOOT_DESC=" 1920x1080"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1920x1080.fd"
    ;;
  "hd" )
    DEST="${PROCESS}_hd"
    BOOT_DESC=" 1024x768"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1024x768.fd"
    ;;
  "default" )
    BOOT_DESC=""
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS.fd"
    DEST="${PROCESS}_default"
    ;;
  *)
    error "Unknown BOOT_MODE, value \"${BOOT_MODE}\" is not recognized!" && exit 33
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
BOOT_DRIVE_ID="OpenCore"
BOOT_DRIVE="$STORAGE/boot.img"
BOOT_VERSION="$STORAGE/boot.version"
BOOT_FILE="/images/OpenCore.img.gz"
BOOT_SIZE=$(stat -c%s "$BOOT_FILE")

CURRENT_SIZE=""
if [ -f "$BOOT_VERSION" ]; then
  CURRENT_SIZE=$(<"$BOOT_VERSION")
fi

if [ "$CURRENT_SIZE" != "$BOOT_SIZE" ]; then
  rm -f "$BOOT_DRIVE" 2>/dev/null || true
fi

if [ ! -f "$BOOT_DRIVE" ] || [ ! -s "$BOOT_DRIVE" ]; then
  msg="Extracting boot image"
  info "$msg..." && html "$msg..."
  gzip -dkc "$BOOT_FILE" > "$BOOT_DRIVE"
  echo "$BOOT_SIZE" > "$BOOT_VERSION"
fi

DISK_OPTS+=" -device virtio-blk-pci,drive=${BOOT_DRIVE_ID},scsi=off,bus=pcie.0,addr=0x5,bootindex=$BOOT_INDEX"
DISK_OPTS+=" -drive file=$BOOT_DRIVE,id=$BOOT_DRIVE_ID,format=raw,cache=unsafe,readonly=on,if=none"

CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')
DEFAULT_FLAGS="vendor=GenuineIntel,vmware-cpuid-freq=on,-pdpe1gb"

if [[ "$CPU_VENDOR" != "GenuineIntel" ]] || [[ "${KVM:-}" == [Nn]* ]]; then
  [ -z "${CPU_MODEL:-}" ] && CPU_MODEL="Haswell-noTSX"
  DEFAULT_FLAGS+=",+pcid,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+xsave,+xsaveopt,+rdrand,check"
fi

if [ -z "${CPU_FLAGS:-}" ]; then
  CPU_FLAGS="$DEFAULT_FLAGS"
else
  CPU_FLAGS="$DEFAULT_FLAGS,$CPU_FLAGS"
fi

USB="nec-usb-xhci,id=xhci"
USB+=" -device usb-kbd,bus=xhci.0"
USB+=" -global nec-usb-xhci.msi=off"

return 0
