#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${SECURE:="off"}"       # Secure boot
: "${BOOT_MODE:="macos"}"  # Boot mode

BOOT_DESC=""
BOOT_OPTS=""
OVMF="/usr/share/OVMF"

msg="Configuring boot..."
html "$msg"
[[ "$DEBUG" == [Yy1]* ]] && echo "$msg"

case "${HEIGHT,,}" in
  "1080" )
    DEST="$PROCESS"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1920x1080.fd"
    ;;
  "768" )
    DEST="${PROCESS}_hd"
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS-1024x768.fd"
    ;;
  *)
    ROM="OVMF_CODE.fd"
    VARS="OVMF_VARS.fd"
    DEST="${PROCESS}_${HEIGHT}"
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

if [ ! -s "$DEST.rom" ]; then
  [ ! -s "$OVMF/$ROM" ] && error "UEFI boot file ($OVMF/$ROM) not found!" && exit 44

  logo="/var/www/img/${PROCESS,,}.ffs"
  [ ! -s "$logo" ] && logo="/var/www/img/qemu.ffs"
  [ ! -s "$logo" ] && LOGO="N"

  if [[ "${LOGO:-}" == [Nn]* ]]; then
    cp "$OVMF/$ROM" "$DEST.tmp"
  else
    if ! /run/utk.bin "$OVMF/$ROM" replace_ffs LogoDXE "$logo" save "$DEST.tmp"; then
      warn "failed to add custom logo to BIOS!"
      cp "$OVMF/$ROM" "$DEST.tmp"
    fi
  fi
  mv "$DEST.tmp" "$DEST.rom"
  ! setOwner "$DEST.rom" && error "Failed to set the owner for \"$DEST.rom\" !"
fi

if [ ! -s "$DEST.vars" ]; then
  [ ! -s "$OVMF/$VARS" ] && error "UEFI vars file ($OVMF/$VARS) not found!" && exit 45
  cp "$OVMF/$VARS" "$DEST.tmp"
  mv "$DEST.tmp" "$DEST.vars"
  ! setOwner "$DEST.vars" && error "Failed to set the owner for \"$DEST.vars\" !"
fi

BOOT_OPTS+=" -drive if=pflash,format=raw,readonly=on,file=$DEST.rom"
BOOT_OPTS+=" -drive if=pflash,format=raw,file=$DEST.vars"

IMG="$STORAGE/boot.img"

if [ ! -f "$IMG" ]; then

  FILE="OpenCore.img"
  IMG="/tmp/$FILE"
  rm -f "$IMG"

  # OpenCoreBoot
  ISO="/opencore.iso"
  OUT="/tmp/extract"

  rm -rf "$OUT"
  mkdir -p "$OUT"

  msg="Building OpenCore boot image"
  info "$msg..." && html "$msg..."

  # Extract image file
  if [ ! -s "$ISO" ]; then
    error "Could not find image file \"$ISO\"." && exit 10
  fi

  if ! 7z x "$ISO" -o"$OUT" > /dev/null; then
    error "Failed to extract archive!" && exit 11
  fi

  # Overwrite extracted OpenCore config with our own
  CFG="$(find "$OUT" -type f -path '*/EFI/OC/config.plist' -print -quit)"
  [ -z "${CFG:-}" ] && error "Could not locate extracted OpenCore config.plist under \"$OUT\"." && exit 12

  EFI_DIR="${CFG%/OC/config.plist}"
  PLIST="/assets/config.plist"
  [ -f "/custom.plist" ] && PLIST="/custom.plist"

  cp "$PLIST" "$CFG"

  # Replace placeholders with machine details
  ROM="${MAC//[^[:alnum:]]/}"
  ROM="${ROM,,}"
  BROM=$(echo "$ROM" | xxd -r -p | base64)
  RESOLUTION="${WIDTH}x${HEIGHT}@32"

  sed -r -i -e 's|<data>ESIzRFVm</data>|<data>'"${BROM}"'</data>|g' "$CFG"
  sed -r -i -e 's|<string>iMac19,1</string>|<string>'"${MODEL}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>W00000000001</string>|<string>'"${SN}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>M0000000000000001</string>|<string>'"${MLB}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>1920x1080@32</string>|<string>'"${RESOLUTION}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>00000000-0000-0000-0000-000000000000</string>|<string>'"${UUID}"'</string>|g' "$CFG"

  # Add kext to disable VM detection
  kexts="$EFI_DIR/OC/Kexts"

  if ! 7z x /vmh.zip -o"$OUT/kext" > /dev/null; then
    error "Failed to extract kext archive!" && exit 11
  fi

  mv "$OUT/kext/VMHide.kext" "$kexts"
  rm -rf "$OUT/kext"

  # Build image

  MB=256
  CLUSTER=4
  START=2048
  SECTOR=512
  FIRST_LBA=34

  SIZE=$(( MB*1024*1024 ))
  OFFSET=$(( START*SECTOR ))
  TOTAL=$(( SIZE-(FIRST_LBA*SECTOR) ))
  LAST_LBA=$(( TOTAL/SECTOR ))
  COUNT=$(( LAST_LBA-(START-1) ))

  if ! truncate -s "$SIZE" "$IMG"; then
    rm -f "$IMG"
    error "Could not allocate space to create image $IMG ." && exit 11
  fi

  PART="/tmp/partition.fdisk"

  {       echo "label: gpt"
          echo "label-id: 1ACB1E00-3B8F-4B2A-86A4-D99ED21DCAEB"
          echo "device: $FILE"
          echo "unit: sectors"
          echo "first-lba: $FIRST_LBA"
          echo "last-lba: $LAST_LBA"
          echo "sector-size: $SECTOR"
          echo ""
          echo "${FILE}1 : start=$START, size=$COUNT, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=05157F6E-0AE8-4D1A-BEA5-AC172453D02C, name=\"primary\""

  } > "$PART"

  sfdisk -q "$IMG" < "$PART"
  echo "drive c: file=\"$IMG\" partition=0 offset=$OFFSET" > /etc/mtools.conf

  mformat -F -M "$SECTOR" -c "$CLUSTER" -T "$COUNT" -v "EFI" "C:"
  mcopy -bspmQ "$EFI_DIR" "C:"

  rm -rf "$OUT"

  info ""
  info "Model: $MODEL"
  info "Rom: $ROM"
  info "Serial: $SN"
  info "Board: $MLB"
  info ""

fi

! setOwner "$IMG" && error "Failed to set the owner for \"$IMG\" !"

BOOT_DRIVE_ID="OpenCore"

DISK_OPTS+=" -device virtio-blk-pci,drive=${BOOT_DRIVE_ID},bus=pcie.0,addr=0x5,bootindex=$BOOT_INDEX"
DISK_OPTS+=" -drive file=$IMG,id=$BOOT_DRIVE_ID,format=raw,cache=unsafe,readonly=on,if=none"

return 0
