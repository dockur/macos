#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${SECURE:="off"}"       # Secure boot
: "${PICKER:="N"}"         # Show picker
: "${BOOT_MODE:="macos"}"  # Boot mode

BOOT_DESC=""
BOOT_OPTS=""
OVMF="/usr/share/OVMF"

selectOvmfFiles() {

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

  DEST="$STORAGE/$DEST"
  return 0
}

prepareOvmfRom() {

  if [ -s "$DEST.rom" ]; then
    return 0
  fi

  [ ! -s "$OVMF/$ROM" ] && error "UEFI boot file ($OVMF/$ROM) not found!" && exit 44

  local logo="/var/www/img/${PROCESS,,}.ffs"
  [ ! -s "$logo" ] && logo="/var/www/img/qemu.ffs"
  [ ! -s "$logo" ] && LOGO="N"

  rm -f "$DEST.tmp"

  if disabled "${LOGO:-}"; then
    if ! cp "$OVMF/$ROM" "$DEST.tmp"; then
      rm -f "$DEST.tmp"
      error "Failed to copy UEFI boot file to $DEST.tmp" && exit 44
    fi
  else
    if ! /run/utk.bin "$OVMF/$ROM" replace_ffs LogoDXE "$logo" save "$DEST.tmp"; then
      warn "failed to add custom logo to BIOS!"
      rm -f "$DEST.tmp"

      if ! cp "$OVMF/$ROM" "$DEST.tmp"; then
        rm -f "$DEST.tmp"
        error "Failed to copy UEFI boot file to $DEST.tmp" && exit 44
      fi
    fi
  fi

  if ! mv "$DEST.tmp" "$DEST.rom"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI boot file to $DEST.rom" && exit 44
  fi

  ! setOwner "$DEST.rom" && error "Failed to set the owner for \"$DEST.rom\" !"

  return 0
}

prepareOvmfVars() {

  if [ -s "$DEST.vars" ]; then
    return 0
  fi

  [ ! -s "$OVMF/$VARS" ] && error "UEFI vars file ($OVMF/$VARS) not found!" && exit 45

  rm -f "$DEST.tmp"

  if ! cp "$OVMF/$VARS" "$DEST.tmp"; then
    rm -f "$DEST.tmp"
    error "Failed to copy UEFI vars file to $DEST.tmp" && exit 45
  fi

  if ! mv "$DEST.tmp" "$DEST.vars"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI vars file to $DEST.vars" && exit 45
  fi

  ! setOwner "$DEST.vars" && error "Failed to set the owner for \"$DEST.vars\" !"

  return 0
}

addOvmfOptions() {

  BOOT_OPTS+=" -drive if=pflash,format=raw,readonly=on,file=$DEST.rom"
  BOOT_OPTS+=" -drive if=pflash,format=raw,file=$DEST.vars"

  return 0
}

extractOpenCore() {

  # OpenCoreBoot
  ISO="/opencore.iso"
  OUT="/tmp/extract"

  rm -rf "$OUT"
  mkdir -p "$OUT"

  msg="Extracting OpenCore boot image"
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

  return 0
}

checkOpenCoreFiles() {

  if [ ! -s "$EFI_DIR/BOOT/BOOTx64.efi" ]; then
    error "Missing OpenCore BOOTx64.efi!" && exit 12
  fi

  if [ ! -s "$EFI_DIR/OC/OpenCore.efi" ]; then
    error "Missing OpenCore.efi!" && exit 12
  fi

  if [ ! -s "$EFI_DIR/OC/config.plist" ]; then
    error "Missing OpenCore config.plist!" && exit 12
  fi

  if [ ! -d "$EFI_DIR/OC/Drivers" ]; then
    error "Missing OpenCore Drivers directory!" && exit 12
  fi

  if [ ! -d "$EFI_DIR/OC/Kexts" ]; then
    error "Missing OpenCore Kexts directory!" && exit 12
  fi

  return 0
}

configureOpenCorePlist() {

  local brom
  local plist
  local resolution

  PLIST="/assets/config.plist"
  [ -f "/custom.plist" ] && PLIST="/custom.plist"

  cp "$PLIST" "$CFG"

  # Replace placeholders with machine details
  ROM="${MAC//[^[:alnum:]]/}"
  ROM="${ROM,,}"
  brom=$(echo "$ROM" | xxd -r -p | base64)
  resolution="${WIDTH}x${HEIGHT}@32"

  sed -r -i -e 's|<data>ESIzRFVm</data>|<data>'"${brom}"'</data>|g' "$CFG"
  sed -r -i -e 's|<string>iMac19,1</string>|<string>'"${MODEL}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>W00000000001</string>|<string>'"${SN}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>M0000000000000001</string>|<string>'"${MLB}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>1920x1080@32</string>|<string>'"${resolution}"'</string>|g' "$CFG"
  sed -r -i -e 's|<string>00000000-0000-0000-0000-000000000000</string>|<string>'"${UUID}"'</string>|g' "$CFG"

  # Show boot picker if requested
  if enabled "$PICKER"; then
    sed -i '/<key>ShowPicker<\/key>/{n;s/<false\/>/<true\/>/}' "$CFG"
    sed -i '/<key>HideAuxiliary<\/key>/{n;s/<true\/>/<false\/>/}' "$CFG"
    sed -i '/<key>Timeout<\/key>/{n;s/<integer>[0-9]\+<\/integer>/<integer>10<\/integer>/}' "$CFG"
    sed -i '/<key>PickerMode<\/key>/{n;s/<string>External<\/string>/<string>Builtin<\/string>/}' "$CFG"
  fi

  return 0
}

checkOpenCoreConfig() {

  if [ ! -s "$CFG" ]; then
    error "OpenCore config.plist is missing or empty!" && exit 12
  fi

  if ! python3 - "$CFG" <<'EOF'
import plistlib
import sys

with open(sys.argv[1], "rb") as f:
    plistlib.load(f)
EOF
  then
    error "OpenCore config.plist is not valid XML/plist syntax!" && exit 12
  fi

  if grep -qE 'W00000000001|M0000000000000001|00000000-0000-0000-0000-000000000000|ESIzRFVm' "$CFG"; then
    error "OpenCore config still contains unreplaced placeholders!" && exit 12
  fi

  return 0
}

addVmHideKext() {

  # Add kext to disable VM detection
  local kexts="$EFI_DIR/OC/Kexts"

  if ! 7z x /vmh.zip -o"$OUT/kext" > /dev/null; then
    error "Failed to extract kext archive!" && exit 11
  fi

  mv "$OUT/kext/VMHide.kext" "$kexts"
  rm -rf "$OUT/kext"

  return 0
}

checkVmHideKext() {

  if [ ! -d "$EFI_DIR/OC/Kexts/VMHide.kext" ]; then
    error "Failed to add VMHide.kext to OpenCore image!" && exit 12
  fi

  if [ ! -s "$EFI_DIR/OC/Kexts/VMHide.kext/Contents/Info.plist" ]; then
    error "VMHide.kext is missing Contents/Info.plist!" && exit 12
  fi

  return 0
}

buildOpenCoreImage() {

  local size_mb=256
  local cluster_size=4
  local start_sector=2048
  local sector_size=512
  local first_lba=34

  local image_size
  local partition_offset
  local usable_size
  local last_lba
  local sector_count
  local partition_file

  image_size=$(( size_mb*1024*1024 ))
  partition_offset=$(( start_sector*sector_size ))
  usable_size=$(( image_size-(first_lba*sector_size) ))
  last_lba=$(( usable_size/sector_size ))
  sector_count=$(( last_lba-(start_sector-1) ))

  if ! truncate -s "$image_size" "$IMG"; then
    rm -f "$IMG"
    error "Could not allocate space to create image $IMG." && exit 11
  fi

  partition_file="/tmp/partition.fdisk"

  {
    echo "label: gpt"
    echo "label-id: 1ACB1E00-3B8F-4B2A-86A4-D99ED21DCAEB"
    echo "device: $FILE"
    echo "unit: sectors"
    echo "first-lba: $first_lba"
    echo "last-lba: $last_lba"
    echo "sector-size: $sector_size"
    echo ""
    echo "${FILE}1 : start=$start_sector, size=$sector_count, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=05157F6E-0AE8-4D1A-BEA5-AC172453D02C, name=\"primary\""
  } > "$partition_file"

  sfdisk -q "$IMG" < "$partition_file"
  echo "drive c: file=\"$IMG\" partition=0 offset=$partition_offset" > /etc/mtools.conf

  mformat -F -M "$sector_size" -c "$cluster_size" -T "$sector_count" -v "EFI" "C:"
  mcopy -bspmQ "$EFI_DIR" "C:"

  rm -rf "$OUT"

  return 0
}

checkOpenCoreImage() {

  if [ ! -s "$IMG" ]; then
    rm -f "$IMG"
    error "OpenCore image was not created or is empty!" && exit 11
  fi

  return 0
}

printMachineDetails() {

  info ""
  info "Model: $MODEL"
  info "Rom: $ROM"
  info "Serial: $SN"
  info "Board: $MLB"
  info ""

  return 0
}

openCoreSignature() {

  {
    echo "MODEL=$MODEL"
    echo "SN=$SN"
    echo "MLB=$MLB"
    echo "UUID=$UUID"
    echo "MAC=$MAC"
    echo "WIDTH=$WIDTH"
    echo "HEIGHT=$HEIGHT"
    echo "PICKER=$PICKER"
  } | sha256sum | awk '{print $1}'

  return 0
}

prepareOpenCoreImage() {

  local current=""
  local previous=""
  local target="$STORAGE/boot.img"
  local signature="$STORAGE/boot.sig"

  current=$(openCoreSignature)

  if [ -s "$signature" ]; then
    previous=$(<"$signature")
    previous="${previous//[![:print:]]/}"
  fi

  if [ -s "$target" ] && [ "$previous" = "$current" ]; then
    IMG="$target"
    return 0
  fi

  if [ -s "$target" ]; then
    info "Rebuilding OpenCore boot image due to configuration changes..."
  else
    msg="Building OpenCore boot image"
    info "$msg..." && html "$msg..."
  fi

  FILE="OpenCore.img"
  IMG="/tmp/$FILE"
  rm -f "$IMG"

  extractOpenCore
  checkOpenCoreFiles
  configureOpenCorePlist
  checkOpenCoreConfig
  addVmHideKext
  checkVmHideKext
  checkOpenCoreFiles
  buildOpenCoreImage
  checkOpenCoreImage
  printMachineDetails

  if ! mv -f "$IMG" "$target"; then
    rm -f "$IMG" "$signature"
    error "Failed to move OpenCore image to $target" && exit 11
  fi

  if [ ! -s "$target" ]; then
    rm -f "$target" "$signature"
    error "OpenCore image is missing after moving to $target" && exit 11
  fi

  IMG="$target"

  if ! echo "$current" > "$signature"; then
    error "Failed to write OpenCore image signature to $signature" && exit 11
  fi

  ! setOwner "$signature" && error "Failed to set the owner for \"$signature\" !"

  return 0
}

msg="Configuring boot..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

selectOvmfFiles

BOOT_OPTS+=" -smbios type=2"
BOOT_OPTS+=" -rtc base=utc,base=localtime"
BOOT_OPTS+=" -global ICH9-LPC.disable_s3=1"
BOOT_OPTS+=" -global ICH9-LPC.disable_s4=1"
BOOT_OPTS+=" -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"

osk=$(echo "bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap" | tr 'A-Za-z' 'N-ZA-Mn-za-m')
BOOT_OPTS+=" -device isa-applesmc,osk=$osk"

# OVMF
prepareOvmfRom
prepareOvmfVars
addOvmfOptions

prepareOpenCoreImage

! setOwner "$IMG" && error "Failed to set the owner for \"$IMG\" !"

BOOT_DRIVE_ID="OpenCore"

DISK_OPTS+=" -device virtio-blk-pci,drive=${BOOT_DRIVE_ID},bus=pcie.0,addr=0x5,bootindex=$BOOT_INDEX"
DISK_OPTS+=" -drive file=$IMG,id=$BOOT_DRIVE_ID,format=raw,cache=unsafe,readonly=on,if=none"

return 0
