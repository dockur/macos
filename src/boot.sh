#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${SMM:=""}"             # Enable SMM
: "${LOGO:=""}"            # Enable logo
: "${CLEAR:=""}"           # Clear NVRAM
: "${PICKER:="N"}"         # Show picker

BOOT_DESC=""
BOOT_OPTS=""
OVMF="/usr/share/OVMF"

selectOvmfFiles() {

  # OVMF variable templates contain resolution-specific GOP settings.
  # Keep their persistent filenames separate when HEIGHT changes.
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

prepareUefiRom() {

  if [ -e "$DEST.rom" ] && [ ! -f "$DEST.rom" ]; then
    error "UEFI boot path \"$DEST.rom\" is not a regular file!"
    exit 44
  fi

  # Reuse the prepared firmware across restarts; CLEAR deliberately removes
  # it when the logo or firmware state needs to be regenerated.
  [ -s "$DEST.rom" ] && return 0

  local rom="$OVMF/$ROM"
  [ ! -s "$rom" ] && error "UEFI boot file ($rom) not found!" && exit 44

  local logo="/var/www/img/${PROCESS,,}.bmp"
  [ ! -s "$logo" ] && logo="/var/www/img/qemu.bmp"

  if ! disabled "$LOGO" && [ ! -s "$logo" ]; then
    LOGO="N"
    warn "boot logo file ($logo) not found!"
  fi

  # Publish through a temporary file so a failed logo patch cannot replace
  # the last usable firmware image.
  rm -f "$DEST.tmp"

  if ! disabled "$LOGO" &&
     ! /run/boot-logo "$logo" "$rom" --output "$DEST.tmp" -q; then
    warn "failed to add custom logo ($logo) to UEFI firmware!"
    rm -f "$DEST.tmp"
  fi

  if [[ ! -f "$DEST.tmp" ]] && ! cp "$rom" "$DEST.tmp"; then
    rm -f "$DEST.tmp"
    error "Failed to copy UEFI boot file to $DEST.tmp" && exit 44
  fi

  if ! mv "$DEST.tmp" "$DEST.rom"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI boot file to $DEST.rom" && exit 44
  fi

  setOwner "$DEST.rom" || warn "failed to set the owner for \"$DEST.rom\" !"

  return 0
}

prepareUefiVars() {

  if [ -e "$DEST.vars" ] && [ ! -f "$DEST.vars" ]; then
    error "UEFI vars path \"$DEST.vars\" is not a regular file!"
    exit 44
  fi

  # The writable NVRAM store carries firmware and OpenCore boot state across
  # restarts, so initialize it only when no persistent copy exists.
  [ -s "$DEST.vars" ] && return 0

  local vars="$OVMF/$VARS"
  [ ! -s "$vars" ] && error "UEFI vars file ($vars) not found!" && exit 45

  # Build the initial variable store atomically for the same reason as the
  # firmware code image above.
  rm -f "$DEST.tmp"

  if ! cp "$vars" "$DEST.tmp"; then
    rm -f "$DEST.tmp"
    error "Failed to copy UEFI vars file to $DEST.tmp" && exit 45
  fi

  if ! mv "$DEST.tmp" "$DEST.vars"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI vars file to $DEST.vars" && exit 45
  fi

  setOwner "$DEST.vars" || warn "failed to set the owner for \"$DEST.vars\" !"

  return 0
}

clearNvram() {

  if enabled "${CLEAR:-}"; then
    # Clear NVRAM (helps to fix corruptions)
    rm -f "$DEST.rom" "$DEST.vars"
  fi

  return 0
}

addOvmfOptions() {

  # OVMF code is immutable, while the separate variable store must remain
  # writable for boot entries and runtime firmware settings.
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

  # The bundled image supplies OpenCore binaries, but its config is replaced
  # with the project template containing this VM's generated identity.
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

  local brom plist

  PLIST="/assets/config.plist"
  [ -f "/custom.plist" ] && PLIST="/custom.plist"

  cp "$PLIST" "$CFG"

  # Update machine details
  # OpenCore stores ROM as six raw MAC bytes in plist data rather than as a
  # colon-delimited string.
  ROM="${MAC//[^[:alnum:]]/}"
  ROM="${ROM,,}"
  brom=$(echo "$ROM" | xxd -r -p | base64)
  local resolution="${WIDTH}x${HEIGHT}@32"
  local generic="/plist/dict/key[.='PlatformInfo']/following-sibling::dict[1]/key[.='Generic']/following-sibling::dict[1]"
  local output="/plist/dict/key[.='UEFI']/following-sibling::dict[1]/key[.='Output']/following-sibling::dict[1]"
  local boot="/plist/dict/key[.='Misc']/following-sibling::dict[1]/key[.='Boot']/following-sibling::dict[1]"

  xmlstarlet ed -P -L \
    -u "$generic/key[.='ROM']/following-sibling::data[1]" -v "$brom" \
    -u "$generic/key[.='SystemProductName']/following-sibling::string[1]" -v "$MODEL" \
    -u "$generic/key[.='SystemSerialNumber']/following-sibling::string[1]" -v "$SN" \
    -u "$generic/key[.='MLB']/following-sibling::string[1]" -v "$MLB" \
    -u "$generic/key[.='SystemUUID']/following-sibling::string[1]" -v "$UUID" \
    -u "$output/key[.='Resolution']/following-sibling::string[1]" -v "$resolution" \
    "$CFG"

  # Show boot picker if requested
  # Showing the picker also exposes auxiliary entries and extends the timeout
  # so recovery and maintenance choices remain selectable.
  if enabled "$PICKER"; then
    xmlstarlet ed -P -L \
      -r "$boot/key[.='ShowPicker']/following-sibling::*[1]" -v true \
      -r "$boot/key[.='HideAuxiliary']/following-sibling::*[1]" -v false \
      -u "$boot/key[.='Timeout']/following-sibling::integer[1]" -v 60 \
      -u "$boot/key[.='PickerMode']/following-sibling::string[1]" -v Builtin \
      "$CFG"
  fi

  return 0
}

checkGeneratedIdentity() {

  if [[ ! "$SN" =~ ^[A-Z0-9]{11,12}$ ]]; then
    error "Generated serial has unexpected format: $SN" && exit 12
  fi

  if [[ ! "$MLB" =~ ^[A-Z0-9]{13,17}$ ]]; then
    error "Generated board serial has unexpected format: $MLB" && exit 12
  fi

  if [[ ! "$UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    error "Generated UUID has unexpected format: $UUID" && exit 12
  fi

  if [[ ! "$ROM" =~ ^[0-9a-f]{12}$ ]]; then
    error "Generated ROM has unexpected format: $ROM" && exit 12
  fi

  return 0
}

checkOpenCoreConfig() {

  if [ ! -s "$CFG" ]; then
    error "OpenCore config.plist is missing or empty!" && exit 12
  fi

  info "Validating OpenCore config..."

  # Parse the completed plist and verify typed values; successful text
  # substitutions alone do not prove the generated config is valid.
  local path='/plist/dict/key[.="PlatformInfo"]/following-sibling::dict[1]/key[.="Generic"]/following-sibling::dict[1]'
  local values model serial board uuid rom_type rom

  if ! xmlstarlet val -q "$CFG" 2>/dev/null; then
    error "OpenCore config.plist does not contain the generated machine identity!" && exit 12
  fi

  if ! values=$(xmlstarlet sel -T -t \
      -v "$path/key[.='SystemProductName']/following-sibling::*[1]" -n \
      -v "$path/key[.='SystemSerialNumber']/following-sibling::*[1]" -n \
      -v "$path/key[.='MLB']/following-sibling::*[1]" -n \
      -v "$path/key[.='SystemUUID']/following-sibling::*[1]" -n \
      -v "name($path/key[.='ROM']/following-sibling::*[1])" -n \
      -v "$path/key[.='ROM']/following-sibling::*[1]" \
      "$CFG" 2>/dev/null); then
    error "OpenCore config.plist does not contain the generated machine identity!" && exit 12
  fi

  {
    IFS= read -r model
    IFS= read -r serial
    IFS= read -r board
    IFS= read -r uuid
    IFS= read -r rom_type
    IFS= read -r rom
  } <<< "$values"

  rom=$(printf '%s' "$rom" | tr -d '[:space:]')

  if [ "$model" != "$MODEL" ] ||
     [ "$serial" != "$SN" ] ||
     [ "$board" != "$MLB" ] ||
     [ "$uuid" != "$UUID" ] ||
     [ "$rom_type" != "data" ] ||
     [ "$rom" != "$(printf '%s' "$ROM" | xxd -r -p | base64 | tr -d '[:space:]')" ]; then
    error "OpenCore config.plist does not contain the generated machine identity!" && exit 12
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

buildOpenCoreImage() {

  local size_mb=256
  local cluster_size=4
  local start_sector=2048
  local sector_size=512
  local first_lba=34

  msg="Creating OpenCore boot disk"
  info "$msg..." && html "$msg..."

  # Construct a fixed-size GPT disk containing one FAT32 EFI System
  # Partition, which firmware can boot without a loop device.
  local image_size=$(( size_mb*1024*1024 ))
  local partition_offset=$(( start_sector*sector_size ))
  local usable_size=$(( image_size-(first_lba*sector_size) ))
  local last_lba=$(( usable_size/sector_size ))
  local sector_count=$(( last_lba-(start_sector-1) ))

  if ! truncate -s "$image_size" "$IMG"; then
    rm -f "$IMG"
    error "Could not allocate space to create image $IMG." && exit 11
  fi

  local partition_file="/tmp/partition.fdisk"

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

  # Point mtools directly at the partition offset so the image can be
  # formatted and populated inside an unprivileged container.
  sfdisk -q "$IMG" < "$partition_file"
  echo "drive c: file=\"$IMG\" partition=0 offset=$partition_offset" > /etc/mtools.conf

  mformat -F -M "$sector_size" -c "$cluster_size" -T "$sector_count" -v "EFI" "C:"

  msg="Copying OpenCore files to boot disk"
  info "$msg..." && html "$msg..."

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

  local opencore config vmhide
  local plist="/assets/config.plist"

  [ -f "/custom.plist" ] && plist="/custom.plist"

  opencore=$(sha256sum /opencore.iso | awk '{print $1}') || return 1
  config=$(sha256sum "$plist" | awk '{print $1}') || return 1
  vmhide=$(sha256sum /vmh.zip | awk '{print $1}') || return 1

  # Hash every generated setting and source file that changes OpenCore contents;
  # an unchanged signature allows the persistent boot image to be reused safely.
  {
    echo "MODEL=$MODEL"
    echo "SN=$SN"
    echo "MLB=$MLB"
    echo "UUID=$UUID"
    echo "MAC=$MAC"
    echo "WIDTH=$WIDTH"
    echo "HEIGHT=$HEIGHT"
    echo "PICKER=$PICKER"
    echo "OPENCORE=$opencore"
    echo "PLIST=$config"
    echo "VMHIDE=$vmhide"
  } | sha256sum | awk '{print $1}'

  return 0
}

prepareOpenCoreImage() {

  local target="$STORAGE/boot.img"
  local current previous signature

  signature=$(stateFile "sig" "boot") || exit 11
  current=$(openCoreSignature)
  previous=$(readState "sig" "boot") || exit 11

  # Rebuild when generated settings or any source used to build OpenCore
  # differs from the stored boot-image signature.
  if [ -s "$target" ] && [ "$previous" = "$current" ]; then
    IMG="$target"
    return 0
  fi

  if [ -s "$target" ]; then
    msg="Rebuilding OpenCore boot image due to configuration changes..."
  else
    msg="Building OpenCore boot image"
  fi

  info "$msg..." && html "$msg..."

  FILE="OpenCore.img"
  IMG="/tmp/$FILE"
  rm -f "$IMG"

  extractOpenCore
  checkOpenCoreFiles
  configureOpenCorePlist
  checkGeneratedIdentity
  checkOpenCoreConfig
  addVmHideKext
  checkOpenCoreFiles
  buildOpenCoreImage
  checkOpenCoreImage
  printMachineDetails

  msg="Saving OpenCore boot image"
  info "$msg..." && html "$msg..."

  # Publish the completed image first and record its signature only afterward,
  # preventing a failed build from being treated as current.
  if ! mv -f "$IMG" "$target"; then
    rm -f "$IMG" "$signature"
    error "Failed to move OpenCore image to $target" && exit 11
  fi

  if [ ! -s "$target" ]; then
    rm -f "$target" "$signature"
    error "OpenCore image is missing after moving to $target" && exit 11
  fi

  IMG="$target"

  if ! writeState "sig" "$current" "boot"; then
    error "Failed to write OpenCore image signature to $signature" && exit 11
  fi

  return 0
}

msg="Configuring boot..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

selectOvmfFiles
clearNvram

BOOT_OPTS+=" -rtc base=utc"
BOOT_OPTS+=" -smbios type=2"

# Disable firmware sleep states and bridge hotplug behavior that macOS does
# not handle reliably on the emulated ICH9 platform.
BOOT_OPTS+=" -global ICH9-LPC.disable_s3=1"
BOOT_OPTS+=" -global ICH9-LPC.disable_s4=1"
BOOT_OPTS+=" -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"

# Decode the Apple SMC key at runtime rather than storing it as plain text.
osk=$(echo "bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap" | tr 'A-Za-z' 'N-ZA-Mn-za-m')
BOOT_OPTS+=" -device isa-applesmc,osk=$osk"

# OVMF
prepareUefiRom
prepareUefiVars
addOvmfOptions

prepareOpenCoreImage

setOwner "$IMG" || error "Failed to set the owner for \"$IMG\" !"

BOOT_DRIVE_ID="OpenCore"

# OpenCore is immutable at runtime; persistent boot choices live in OVMF
# NVRAM, so attach the generated boot disk read-only.
DISK_OPTS+=" -device virtio-blk-pci,drive=${BOOT_DRIVE_ID},bus=pcie.0,addr=0x5,bootindex=$BOOT_INDEX"
DISK_OPTS+=" -drive file=$IMG,id=$BOOT_DRIVE_ID,format=raw,cache=unsafe,readonly=on,if=none"

return 0
