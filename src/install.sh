#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${SN:=""}"                # Device serial
: "${MLB:=""}"               # Board serial
: "${MAC:=""}"               # MAC address
: "${UUID:=""}"              # Unique ID
: "${VERSION:=""}"           # OSX Version
: "${WIDTH:="1920"}"         # Horizontal
: "${HEIGHT:="1080"}"        # Vertical
: "${MODEL:="iMacPro1,1"}"   # Device model

# Sanitize variables
SN=$(strip "$SN")
MLB=$(strip "$MLB")
MAC=$(strip "$MAC")
UUID=$(strip "$UUID")
MODEL=$(strip "$MODEL")
WIDTH=$(strip "$WIDTH")
HEIGHT=$(strip "$HEIGHT")

BASE_IMG_ID="InstallMedia"
BASE_IMG="$STORAGE/installer.img"

checkFreeSpace() {

  local dir="$1"
  local size="$2"

  local base space size_gb space_gb
  base=$(baseDir "$dir")

  if ! space=$(df --output=avail -B 1 "$dir" | tail -n 1); then
    error "Failed to check free space in $dir."
    return 1
  fi

  if [[ ! "$space" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
    error "Failed to determine available disk space for $dir."
    return 1
  fi

  space="${space//[[:space:]]/}"

  if (( size > space )); then

    size_gb=$(formatBytes "$size")
    space_gb=$(formatBytes "$space")

    error "Insufficient free disk space in $base, have $space_gb available but need at least $size_gb."
    return 1

  fi

  return 0
}

isXarArchive() {

  local file="$1"

  [ -f "$file" ] || return 1
  cmp -s -n 4 <(printf 'xar!') "$file"
}

isBxDiff50() {

  local file="$1"

  [ -f "$file" ] || return 1
  cmp -s -n 8 <(printf 'BXDIFF50') "$file"
}

bxdiffValue() {

  local file="$1"
  local offset="$2"

  od -An -v -j "$offset" -N 8 -tu8 "$file" 2>/dev/null |
    tr -d '[:space:]'
}

archiveEntrySize() {

  local archive="$1"
  local entry="$2"
  local forced="${3:-}"
  local type=()

  if [ -n "$forced" ]; then
    type=("-t$forced")
  elif isXarArchive "$archive"; then
    type=(-txar)
  fi

  7z l "${type[@]}" -slt "$archive" 2>/dev/null |
    awk -v target="$entry" '
      /^Path = / {
        path=substr($0, 8)
        next
      }
      /^Size = / && path == target {
        size=substr($0, 8)
        if (size ~ /^[0-9]+$/) {
          print size
          exit
        }
      }
    '

  return 0
}

archiveExpandedSize() {

  local archive="$1"
  local forced="${2:-}"
  local type=()

  if [ -n "$forced" ]; then
    type=("-t$forced")
  elif isXarArchive "$archive"; then
    type=(-txar)
  fi

  7z l "${type[@]}" -slt "$archive" 2>/dev/null |
    awk '
      /^----------$/ {
        entries=1
        next
      }
      entries && /^Size = [0-9]+$/ {
        total += substr($0, 8)
      }
      END {
        printf "%.0f\n", total
      }
    '

  return 0
}

getInstallationMajor() {

  local version="$1"

  case "${version,,}" in
    "tahoe" | "26"* | "16"* ) echo "26" ;;
    "sequoia" | "15"* ) echo "15" ;;
    "sonoma" | "14"* ) echo "14" ;;
    "ventura" | "13"* ) echo "13" ;;
    "monterey" | "12"* ) echo "12" ;;
    "bigsur" | "big-sur" | "11"* ) echo "11" ;;
    * ) return 1 ;;
  esac

  return 0
}

getInstallationName() {

  case "$1" in
    "26" ) echo "Tahoe" ;;
    "15" ) echo "Sequoia" ;;
    "14" ) echo "Sonoma" ;;
    "13" ) echo "Ventura" ;;
    "12" ) echo "Monterey" ;;
    "11" ) echo "Big Sur" ;;
    * ) return 1 ;;
  esac

  return 0
}

getInstallationCatalog() {

  # Apple's public release catalog for Tahoe also contains installation
  # files for the supported Intel macOS generations below it.
  echo "https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"

  return 0
}

getInstallationUrl() {

  local major="$1"

  local catalog catalog_url catalog_size
  local count url pairs distfile dist version
  local metadata_space=$((128 * 1024 * 1024))
  local best_version="" best_url=""

  INSTALLATION_RELEASE=""
  INSTALLATION_URL=""

  catalog=$(mktemp) || return 1
  pairs=$(mktemp) || { rm -f "$catalog"; return 1; }
  distfile=$(mktemp) || { rm -f "$catalog" "$pairs"; return 1; }

  catalog_url=$(getInstallationCatalog)

  catalog_size=$(curl --disable --max-time 30 --silent --show-error --fail --location --head \
    "$catalog_url" 2>/dev/null |
    awk 'tolower($1) == "content-length:" {gsub("\r", "", $2); value=$2} END {print value}' || :)

  if [[ "$catalog_size" =~ ^[0-9]+$ ]] && (( catalog_size > 0 )); then
    checkFreeSpace "$(dirname "$catalog")" "$catalog_size" || {
      rm -f "$catalog" "$pairs" "$distfile"
      return 1
    }
  else
    checkFreeSpace "$(dirname "$catalog")" "$metadata_space" || {
      rm -f "$catalog" "$pairs" "$distfile"
      return 1
    }
  fi

  local msg="Downloading installation catalog..."
  info "$msg" && html "$msg"

  if ! curl --disable --max-time 60 --silent --show-error --fail --location \
      "$catalog_url" --output "$catalog"; then
    rm -f "$catalog" "$pairs" "$distfile"
    error "Failed to download the Apple software update catalog."
    return 1
  fi

  if ! gzip -dc "$catalog" 2>/dev/null | awk '
    /<key>[0-9]{3}-[0-9]+<\/key>/ {
      active=1
      depth=0
      ia=""
      dist=""
      next
    }
    active && /<dict>/ {
      depth++
      next
    }
    active && /<string>.*InstallAssistant\.pkg<\/string>/ {
      line=$0
      sub(/.*<string>/, "", line)
      sub(/<\/string>.*/, "", line)
      ia=line
      next
    }
    active && /<string>.*English\.dist<\/string>/ {
      line=$0
      sub(/.*<string>/, "", line)
      sub(/<\/string>.*/, "", line)
      dist=line
      next
    }
    active && /<\/dict>/ {
      depth--
      if (depth == 0) {
        if (ia != "" && dist != "")
          print ia "	" dist
        active=0
      }
    }
  ' > "$pairs"; then
    rm -f "$catalog" "$pairs" "$distfile"
    error "Failed to parse the Apple software update catalog."
    return 1
  fi

  rm -f "$catalog"

  if [ ! -s "$pairs" ]; then
    rm -f "$pairs" "$distfile"
    error "No macOS installation files were found in the Apple catalog."
    return 1
  fi

  # Distribution files are tiny and overwrite the same temporary file, so a
  # single metadata reserve covers the whole version scan without doubling
  # every request with an additional HEAD operation.
  checkFreeSpace "$(dirname "$distfile")" "$metadata_space" || {
    rm -f "$pairs" "$distfile"
    return 1
  }

  count=$(wc -l < "$pairs")

  while IFS=$'	' read -r url dist; do

    [ -n "$url" ] && [ -n "$dist" ] || continue

    if ! curl --disable --max-time 30 --silent --show-error --fail --location \
        "$dist" --output "$distfile"; then
      continue
    fi

    version=$(xmlstarlet sel -T -t \
      -v "(//key[.='VERSION']/following-sibling::string[1])[1]" \
      "$distfile" 2>/dev/null || :)

    [ -n "$version" ] || continue
    [[ "${version%%.*}" == "$major" ]] || continue

    if [ -z "$best_version" ] ||
       [ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1)" == "$version" ]; then
      best_version="$version"
      best_url="$url"
    fi

  done < "$pairs"

  rm -f "$pairs" "$distfile"

  if [ -z "$best_url" ]; then
    error "No macOS $major installation files were found in the Apple catalog."
    return 1
  fi

  INSTALLATION_RELEASE="$best_version"
  INSTALLATION_URL="$best_url"
  return 0
}

checkInstallationPackage() {

  local file="$1"
  local size

  if [ ! -s "$file" ]; then
    error "Downloaded installation package is missing or empty!"
    return 1
  fi

  size=$(stat -c%s -- "$file") || return 1

  if (( size < 5000000000 )); then
    error "Downloaded installation package is unexpectedly small: $(formatBytes "$size")"
    return 1
  fi

  if ! isXarArchive "$file"; then
    error "Downloaded InstallAssistant.pkg is not a valid XAR package."
    return 1
  fi

  return 0
}

checkRecoveryDmg() {

  local file="$1"
  local listing

  if [ ! -s "$file" ]; then
    error "Recovery image is missing or empty!"
    return 1
  fi

  if ! qemu-img info "$file" > /dev/null 2>&1; then
    return 1
  fi

  listing=$(mktemp) || return 1

  if ! 7z l -slt "$file" > "$listing" 2>/dev/null; then
    rm -f "$listing"
    return 1
  fi

  if ! grep -Eiq \
      '^Path = (.+[\\/])?(System[\\/]Library[\\/]CoreServices[\\/]boot\.efi|com\.apple\.recovery\.boot[\\/]boot\.efi)$' \
      "$listing"; then
    rm -f "$listing"
    return 1
  fi

  rm -f "$listing"
  return 0
}

useRecoveryDmg() {

  local source="$1"
  local dest="$2"
  local size

  size=$(qemu-img info "$source" 2>/dev/null |
    sed -nE 's/.*\(([0-9]+) bytes\).*/\1/p' |
    head -n 1 || :)

  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    error "Failed to determine converted recovery image size."
    return 1
  fi

  checkFreeSpace "$(dirname "$dest")" "$size" || return 1

  info "Using macOS recovery image..."

  if ! qemu-img convert -p -O raw "$source" "$dest"; then
    rm -f "$dest"
    return 1
  fi

  return 0
}

downloadInstallationFiles() {

  local version="$1"
  local url="$2"
  local dest="$3"
  local connections="${4:-1}"
  local expected required
  local gib=$((1024 * 1024 * 1024))
  local msg="Downloading macOS installer"

  info "Checking download size..."

  expected=$(curl --disable --max-time 30 --silent --show-error --fail --location --head \
    "$url" 2>/dev/null |
    awk 'tolower($1) == "content-length:" {gsub("\r", "", $2); value=$2} END {print value}' || :)

  if [[ "$expected" =~ ^[0-9]+$ ]] && (( expected > 0 )); then
    required="$expected"
  else
    # Current Big Sur and newer packages are roughly 12-16 GB. Keep a safe
    # fallback when a CDN does not expose Content-Length.
    required=$((20 * gib))
  fi

  checkFreeSpace "$(dirname "$dest")" "$required" || return 1

  rm -f -- "$dest" "$dest.aria2"

  local rc=0

  info "$msg..."

  downloadToFile \
    "$url" \
    "$dest" \
    "$msg" \
    "${expected:-0}" \
    "$connections" \
    "N" || rc=$?

  if (( rc != 0 )); then
    rm -f -- "$dest" "$dest.aria2"
    return "$rc"
  fi

  if ! checkInstallationPackage "$dest"; then
    rm -f -- "$dest" "$dest.aria2"
    return 1
  fi

  return 0
}

archiveEntry() {

  local archive="$1"
  local name="$2"
  local type=()

  # InstallAssistant.pkg is both a XAR package and a DMG-compatible file.
  # Force the XAR handler when the archive has a XAR header, otherwise 7-Zip
  # may detect the DMG footer and hide package members such as SharedSupport.dmg.
  if isXarArchive "$archive"; then
    type=(-txar)
  fi

  7z l "${type[@]}" -slt "$archive" 2>/dev/null |
    sed -n 's/^Path = //p' |
    grep -E "(^|/)${name//./\\.}$" |
    head -n 1

  return 0
}

extractArchiveEntry() {

  local archive="$1"
  local entry="$2"
  local dest="$3"
  local forced="${4:-}"
  local size
  local type=()

  [ -n "$entry" ] || return 1
  mkdir -p "$dest"

  size=$(archiveEntrySize "$archive" "$entry" "$forced")

  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    error "Failed to determine extracted size for ${entry##*/}."
    return 1
  fi

  checkFreeSpace "$dest" "$size" || return 1

  if [ -n "$forced" ]; then
    type=("-t$forced")
  elif isXarArchive "$archive"; then
    type=(-txar)
  fi

  7z x "${type[@]}" -y "$archive" "$entry" -o"$dest" > /dev/null
}

extractBaseSystem() {

  local support="$1"
  local dest="$2"
  local disk_dir="$dest/disk"
  local zip_dir="$dest/zip"
  local patch_dir="$dest/patch"
  local base_dir="$dest/base"
  local partition image msg
  local zip_entry zip base_entry patch_entry
  local patch dummy base patched_size control_size
  local partitions=()

  BASE_SYSTEM_FILE=""

  rm -rf "$disk_dir" "$zip_dir" "$patch_dir" "$base_dir"
  mkdir -p "$disk_dir" "$zip_dir" "$patch_dir" "$base_dir"

  mapfile -t partitions < <(
    7z l -tdmg -slt "$support" 2>/dev/null |
      sed -n 's/^Path = //p' |
      grep -Ei '\.(hfs|apfs)$' || :
  )

  (( ${#partitions[@]} > 0 )) || return 1

  for partition in "${partitions[@]}"; do

    rm -rf "$disk_dir" "$zip_dir" "$patch_dir" "$base_dir"
    mkdir -p "$disk_dir" "$zip_dir" "$patch_dir" "$base_dir"

    msg="Extracting recovery data..."
    info "$msg" && html "$msg"

    if ! extractArchiveEntry "$support" "$partition" "$disk_dir" "dmg"; then
      continue
    fi

    image="$disk_dir/$partition"
    [ -f "$image" ] || image=$(find "$disk_dir" -type f \( -name '*.hfs' -o -name '*.apfs' \) -print -quit 2>/dev/null || :)
    [ -f "$image" ] || continue

    zip_entry=$(
      7z l -slt "$image" 2>/dev/null |
        sed -n 's/^Path = //p' |
        grep -Ei '(^|/)com_apple_MobileAsset_MacSoftwareUpdate/[^/]+\.zip$' |
        head -n 1 || :
    )

    [ -n "$zip_entry" ] || continue

    msg="Extracting installation data..."
    info "$msg" && html "$msg"

    if ! extractArchiveEntry "$image" "$zip_entry" "$zip_dir"; then
      continue
    fi

    zip="$zip_dir/$zip_entry"
    [ -f "$zip" ] || zip=$(find "$zip_dir" -type f -name '*.zip' -print -quit 2>/dev/null || :)
    [ -f "$zip" ] || continue

    # The extracted support filesystem is no longer needed after the
    # MobileAsset ZIP has been copied out.
    rm -rf "$disk_dir"

    # Older layouts contain a ready-to-use BaseSystem.dmg.
    base_entry=$(
      7z l -slt "$zip" 2>/dev/null |
        sed -n 's/^Path = //p' |
        grep -Ei '(^|/)AssetData/Restore/BaseSystem\.dmg$' |
        head -n 1 || :
    )

    if [ -n "$base_entry" ]; then

      msg="Extracting recovery image..."
      info "$msg" && html "$msg"

      if ! extractArchiveEntry "$zip" "$base_entry" "$base_dir"; then
        continue
      fi

      base="$base_dir/$base_entry"
      [ -f "$base" ] || base=$(find "$base_dir" -type f -name BaseSystem.dmg -print -quit 2>/dev/null || :)
      [ -f "$base" ] || continue

      rm -rf "$zip_dir"
      BASE_SYSTEM_FILE="$base"
      return 0
    fi

    # Current releases store the Intel BaseSystem as a BXDIFF50 replacement
    # stream. Reconstruct it locally instead of downloading a second image.
    patch_entry=$(
      7z l -slt "$zip" 2>/dev/null |
        sed -n 's/^Path = //p' |
        grep -Ei '(^|/)AssetData/payloadv2/basesystem_patches/x86_64BaseSystem\.dmg$' |
        head -n 1 || :
    )

    [ -n "$patch_entry" ] || continue

    msg="Extracting image patch..."
    info "$msg" && html "$msg"

    if ! extractArchiveEntry "$zip" "$patch_entry" "$patch_dir"; then
      continue
    fi

    patch="$patch_dir/$patch_entry"
    [ -f "$patch" ] || patch=$(find "$patch_dir" -type f -name 'x86_64BaseSystem.dmg' -print -quit 2>/dev/null || :)
    [ -f "$patch" ] || continue

    # The MobileAsset ZIP is no longer needed after the patch has been copied.
    rm -rf "$zip_dir"

    if ! isBxDiff50 "$patch"; then
      error "Recovery image patch is not a valid BXDIFF50 file."
      return 1
    fi

    patched_size=$(bxdiffValue "$patch" 16)
    control_size=$(bxdiffValue "$patch" 24)

    if [[ ! "$patched_size" =~ ^[0-9]+$ ]] || (( patched_size <= 0 )); then
      error "Failed to determine reconstructed recovery image size."
      return 1
    fi

    if [[ ! "$control_size" =~ ^[0-9]+$ ]]; then
      error "Failed to read recovery image patch metadata."
      return 1
    fi

    if (( control_size != 0 )); then
      error "Recovery image patch requires an existing base image."
      return 1
    fi

    checkFreeSpace "$base_dir" "$patched_size" || return 1

    if ! command -v ipsw >/dev/null 2>&1; then
      error "The ipsw utility is required to reconstruct the recovery image."
      return 1
    fi

    msg="Reconstructing recovery image..."
    info "$msg" && html "$msg"

    dummy="$patch_dir/BaseSystem.dmg"
    : > "$dummy"

    if ! ipsw ota patch bxdiff -s "$patch" "$dummy" -o "$base_dir" > "$patch_dir/ipsw.log" 2>&1; then
      tail -n 20 "$patch_dir/ipsw.log" >&2 || :
      error "Failed to reconstruct BaseSystem.dmg."
      return 1
    fi

    base="$base_dir/BaseSystem.dmg"

    if [ ! -f "$base" ]; then
      error "Reconstructed BaseSystem.dmg was not created."
      return 1
    fi

    if [ "$(stat -c%s -- "$base" 2>/dev/null || echo 0)" != "$patched_size" ]; then
      error "Reconstructed BaseSystem.dmg has an unexpected size."
      return 1
    fi

    rm -rf "$patch_dir"
    BASE_SYSTEM_FILE="$base"
    return 0

  done

  return 1
}

findInstallationApp() {

  local root="$1"
  local app

  app=$(find "$root" -type d \( \
      -name 'Install macOS*.app' -o \
      -name 'Install OS X*.app' -o \
      -name 'Install Mac OS X*.app' \
    \) -print -quit 2>/dev/null || :)

  if [ -n "$app" ]; then
    echo "$app"
    return 0
  fi

  # Some recovery layouts use a less obvious bundle name. Locate the bundle
  # containing the installation application executable as a fallback.
  local executable
  executable=$(find "$root" -type f -path '*/Contents/MacOS/Install*' -print -quit 2>/dev/null || :)

  [ -n "$executable" ] || return 1

  app="${executable%/Contents/MacOS/*}"
  [[ "$app" == *.app ]] || return 1

  echo "$app"
  return 0
}

extractPackageInstallationApp() {

  local pkg="$1"
  local dest="$2"
  local listing entry out app old
  local expanded payload payload_size
  local index=0

  listing=$(mktemp) || return 1

  if ! 7z l -txar -slt "$pkg" > "$listing" 2>/dev/null; then
    rm -f "$listing"
    return 1
  fi

  while IFS= read -r entry; do

    [[ "${entry##*/}" == "Payload" ]] || continue

    index=$((index + 1))
    out="$dest/payload-$index"
    mkdir -p "$out/archive" "$out/files"

    if ! extractArchiveEntry "$pkg" "$entry" "$out/archive" "xar"; then
      rm -rf "$out"
      continue
    fi

    payload="$out/archive/$entry"
    [ -f "$payload" ] || payload=$(find "$out/archive" -type f -name Payload -print -quit 2>/dev/null || :)
    [ -f "$payload" ] || { rm -rf "$out"; continue; }

    expanded=$(archiveExpandedSize "$payload")

    if [[ ! "$expanded" =~ ^[0-9]+$ ]] || (( expanded <= 0 )); then
      payload_size=$(stat -c%s -- "$payload" 2>/dev/null || echo 0)

      if [[ ! "$payload_size" =~ ^[0-9]+$ ]] || (( payload_size <= 0 )); then
        rm -rf "$out"
        continue
      fi

      # Payload formats vary across releases. When 7-Zip cannot calculate an
      # expanded size, reserve four times the compressed payload as a safe
      # fallback before trying either extractor.
      expanded=$((payload_size * 4))
    fi

    if ! checkFreeSpace "$out/files" "$expanded"; then
      rm -rf "$out"
      continue
    fi

    if ! 7z x -y "$payload" -o"$out/files" > /dev/null 2>&1; then
      bsdtar -xf "$payload" -C "$out/files" > /dev/null 2>&1 || {
        rm -rf "$out"
        continue
      }
    fi

    # The packaged Payload is no longer needed once its files have been expanded.
    rm -rf "$out/archive"

    if app=$(findInstallationApp "$out/files"); then
      rm -f "$listing"

      # Failed payload attempts can be large. Keep only the tree containing the
      # application that will actually be used.
      for old in "$dest"/payload-*; do
        [ "$old" = "$out" ] || rm -rf "$old"
      done

      echo "$app"
      return 0
    fi

    rm -rf "$out"

  done < <(sed -n 's/^Path = //p' "$listing")

  rm -f "$listing"
  rm -rf "$dest"
  return 1
}

checkWritableInstallationImage() {

  local file="$1"
  local listing

  if [ ! -s "$file" ]; then
    error "Installation image is missing or empty!"
    return 1
  fi

  if ! qemu-img info -f raw "$file" > /dev/null; then
    error "Installation image is not a valid raw disk image!"
    return 1
  fi

  listing=$(mktemp) || return 1

  if ! 7z l -slt "$file" > "$listing" 2>/dev/null; then
    rm -f "$listing"
    error "Failed to inspect the generated installation image."
    return 1
  fi

  if ! grep -Eiq \
      '^Path = (.+[\\/])?System[\\/]Library[\\/]CoreServices[\\/]boot\.efi$' \
      "$listing"; then
    rm -f "$listing"
    error "Generated installation image does not contain boot.efi."
    return 1
  fi

  if ! grep -Eiq \
      '^Path = .*Install .*\.app[\\/]Contents[\\/]SharedSupport[\\/]SharedSupport\.dmg$' \
      "$listing"; then
    rm -f "$listing"
    error "Generated installation image does not contain SharedSupport.dmg."
    return 1
  fi

  rm -f "$listing"
  return 0
}

createInstallationImage() {

  local dmg="$1"
  local dest="$2"
  local work="$STORAGE/tmp/macos-installation"
  local support_dir="$work/support"
  local base_dir="$work/base"
  local payload_dir="$work/payload"
  local expanded_size
  local base boot root base_app package_app
  local source_app root_app app_name app_size
  local dmg_size label tmp

  rm -rf "$work"
  mkdir -p "$support_dir" "$base_dir" "$payload_dir"

  local msg="Extracting package..."
  info "$msg" && html "$msg"

  package_app=$(extractPackageInstallationApp "$dmg" "$payload_dir" 2>/dev/null || :)

  # InstallAssistant.pkg is a XAR/DMG hybrid. Use its DMG side directly for
  # the support data so we do not create another 12-16 GB copy.
  if ! extractBaseSystem "$dmg" "$support_dir"; then
    error "Failed to reconstruct BaseSystem.dmg from the installation files."
    rm -rf "$work"
    return 1
  fi

  base="$BASE_SYSTEM_FILE"

  if [ ! -f "$base" ]; then
    error "Failed to locate reconstructed BaseSystem.dmg."
    rm -rf "$work"
    return 1
  fi

  expanded_size=$(archiveExpandedSize "$base")

  if [[ ! "$expanded_size" =~ ^[0-9]+$ ]] || (( expanded_size <= 0 )); then
    error "Failed to determine expanded recovery image size."
    rm -rf "$work"
    return 1
  fi

  checkFreeSpace "$base_dir" "$expanded_size" || {
    rm -rf "$work"
    return 1
  }

  info "Expanding recovery image..."

  if ! 7z x -y "$base" -o"$base_dir" > /dev/null; then
    error "Failed to extract BaseSystem.dmg."
    rm -rf "$work"
    return 1
  fi

  # The reconstructed BaseSystem and all support intermediates are no longer
  # needed after the recovery filesystem has been expanded.
  rm -rf "$support_dir"

  boot=$(find "$base_dir" -type f -path '*/System/Library/CoreServices/boot.efi' -print -quit 2>/dev/null || :)

  if [ -z "$boot" ]; then
    error "BaseSystem.dmg does not contain System/Library/CoreServices/boot.efi."
    rm -rf "$work"
    return 1
  fi

  root="${boot%/System/Library/CoreServices/boot.efi}"
  [ -d "$root" ] || {
    error "Failed to determine BaseSystem root directory."
    rm -rf "$work"
    return 1
  }

  base_app=$(findInstallationApp "$root" 2>/dev/null || :)
  source_app="$package_app"
  [ -d "$source_app" ] || source_app="$base_app"

  if [ ! -d "$source_app" ]; then
    error "Could not locate the macOS installation application."
    rm -rf "$work"
    return 1
  fi

  app_name="${source_app##*/}"
  root_app="$root/$app_name"

  info "Preparing macOS installation files..."

  if [ "$source_app" != "$root_app" ]; then

    app_size=$(du -sb --apparent-size -- "$source_app" 2>/dev/null | awk '{print $1}' || :)

    if [[ ! "$app_size" =~ ^[0-9]+$ ]]; then
      error "Failed to determine installation application size."
      rm -rf "$work"
      return 1
    fi

    checkFreeSpace "$root" "$app_size" || {
      rm -rf "$work"
      return 1
    }

    rm -rf "$root_app"

    if ! cp -a "$source_app" "$root_app"; then
      error "Failed to place the macOS installation application on the installation volume."
      rm -rf "$work"
      return 1
    fi
  fi

  rm -rf "$payload_dir"

  # Create the destination directory in the staged tree, but do not copy the
  # large DMG into it. /boot.dmg may be a read-only bind mount or live on a
  # different filesystem.
  mkdir -p "$root_app/Contents/SharedSupport"
  rm -f "$root_app/Contents/SharedSupport/SharedSupport.dmg"

  # Recovery's own installation bundle is normally the process launched at boot.
  # Point it at the same local payload so it cannot fall back to Internet Recovery.
  if [ -d "$base_app" ] && [ "$base_app" != "$root_app" ]; then
    mkdir -p "$base_app/Contents/SharedSupport"
    rm -f "$base_app/Contents/SharedSupport/SharedSupport.dmg"
    ln -s "/$app_name/Contents/SharedSupport/SharedSupport.dmg" \
      "$base_app/Contents/SharedSupport/SharedSupport.dmg"
  fi

  touch "$root/.IAPhysicalMedia" "$root/.metadata_never_index"

  label="${app_name%.app}"
  [ -n "$label" ] || label="Install macOS"

  tmp="$dest.tmp"
  rm -f "$tmp"

  local msg="Creating macOS installation image..."
  info "$msg" && html "$msg"

  local partition="$work/installation.hfs"
  local links="$work/symlinks"
  local hfslog="$work/hfsplus.log"
  local link path target
  local payload_size staged_size partition_size disk_size partition_sectors
  local mib=$((1024 * 1024))
  local gib=$((1024 * 1024 * 1024))

  if ! staged_size=$(du -sb --apparent-size -- "$root" | awk '{print $1}'); then
    rm -f "$tmp"
    rm -rf "$work"
    error "Failed to calculate installation size."
    return 1
  fi

  dmg_size=$(stat -c%s -- "$dmg" 2>/dev/null || :)

  if [[ ! "$dmg_size" =~ ^[0-9]+$ ]] || (( dmg_size <= 0 )); then
    rm -f "$tmp"
    rm -rf "$work"
    error "Failed to determine installation DMG size."
    return 1
  fi

  payload_size=$((staged_size + dmg_size))

  # Leave 2 GiB of logical free space so the image stays writable for later
  # customization. The sparse file does not allocate that free space on disk.
  partition_size=$((payload_size + (2 * gib)))
  partition_size=$((((partition_size + mib - 1) / mib) * mib))
  disk_size=$((partition_size + (2 * mib)))
  partition_sectors=$((partition_size / 512))

  checkFreeSpace "$work" "$((payload_size + (512 * mib)))" || {
    rm -f "$tmp"
    rm -rf "$work"
    return 1
  }

  rm -f "$partition" "$links" "$hfslog"
  truncate -s "$partition_size" "$partition"

  info "Creating HFS+ installation filesystem..."

  if ! mkfs.hfsplus -v "$label" "$partition" > /dev/null; then
    rm -f "$tmp" "$partition"
    rm -rf "$work"
    error "Failed to create HFS+ installation filesystem."
    return 1
  fi

  : > "$links"

  while IFS= read -r -d '' link; do
    path="/${link#"$root"/}"
    target=$(readlink -- "$link") || {
      rm -f "$tmp" "$partition"
      rm -rf "$work"
      error "Failed to read installation symlink: $path"
      return 1
    }

    printf '%s\0%s\0' "$path" "$target" >> "$links"
    rm -f -- "$link"
  done < <(find "$root" -type l -print0)

  info "Copying macOS installation files into HFS+ image..."

  if ! hfsplus "$partition" addall "$root" / > "$hfslog" 2>&1; then
    tail -n 20 "$hfslog" >&2 || :
    rm -f "$tmp" "$partition"
    rm -rf "$work"
    error "Failed to copy installation files into HFS+ image."
    return 1
  fi

  # Add the large source DMG directly to HFS+. This works for both an external
  # read-only /boot.dmg and the writable $STORAGE/boot.dmg without staging a
  # second host-side copy.
  if ! hfsplus "$partition" add "$dmg" \
      "/$app_name/Contents/SharedSupport/SharedSupport.dmg" >> "$hfslog" 2>&1; then
    tail -n 20 "$hfslog" >&2 || :
    rm -f "$tmp" "$partition"
    rm -rf "$work"
    error "Failed to copy installation DMG into HFS+ image."
    return 1
  fi

  while IFS= read -r -d '' path && IFS= read -r -d '' target; do
    if ! hfsplus "$partition" symlink "$path" "$target" >> "$hfslog" 2>&1; then
      tail -n 20 "$hfslog" >&2 || :
      rm -f "$tmp" "$partition"
      rm -rf "$work"
      error "Failed to recreate installation symlink: $path"
      return 1
    fi
  done < "$links"

  rm -rf "$base_dir"
  rm -f "$links" "$hfslog"

  checkFreeSpace "$(dirname "$tmp")" "$payload_size" || {
    rm -f "$tmp" "$partition"
    rm -rf "$work"
    return 1
  }

  info "Writing HFS+ installation partition..."

  truncate -s "$disk_size" "$tmp"

  if ! printf 'label: gpt\nunit: sectors\n\nstart=2048, size=%s, type=48465300-0000-11AA-AA11-00306543ECAC, name="%s"\n' \
      "$partition_sectors" "$label" | sfdisk "$tmp" > /dev/null; then
    rm -f "$tmp" "$partition"
    rm -rf "$work"
    error "Failed to create GPT installation disk."
    return 1
  fi

  if ! dd if="$partition" of="$tmp" bs=1M seek=1 conv=notrunc,sparse status=none; then
    rm -f "$tmp" "$partition"
    rm -rf "$work"
    error "Failed to write HFS+ installation partition."
    return 1
  fi

  rm -f "$partition"

  info "Finalizing macOS installation image..."

  if ! checkWritableInstallationImage "$tmp"; then
    rm -f "$tmp"
    rm -rf "$work"
    return 1
  fi

  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    rm -rf "$work"
    error "Failed to move installation image to $dest."
    return 1
  fi

  rm -rf "$work"
  return 0
}

install() {

  local version="$1"
  local dest="$2"
  local major name release url
  local download="$STORAGE/tmp/InstallAssistant.pkg"
  local stored_dmg="$STORAGE/boot.dmg"
  local input_dmg=""

  if ! makeDir "$STORAGE"; then
    error "Failed to create directory \"$STORAGE\" !"
    return 1
  fi

  if ! makeDir "$STORAGE/tmp"; then
    error "Failed to create directory \"$STORAGE/tmp\" !"
    return 1
  fi

  find "$STORAGE" -maxdepth 1 -type f \( -iname '*.rom' -or -iname '*.vars' \) -delete

  if [ -f "/boot.img" ]; then

    local custom_size
    info "Using custom macOS installation image from /boot.img..."

    custom_size=$(stat -c%s -- "/boot.img" 2>/dev/null || :)

    if [[ ! "$custom_size" =~ ^[0-9]+$ ]]; then
      error "Failed to determine custom installation image size."
      return 1
    fi

    checkFreeSpace "$(dirname "$dest")" "$custom_size" || return 1

    if ! cp "/boot.img" "$dest"; then
      rm -f "$dest"
      return 1
    fi

    checkWritableInstallationImage "$dest" || { rm -f "$dest"; return 1; }
    return 0
  fi

  # A user-supplied /boot.dmg always takes precedence. It may be read-only and
  # must never be renamed, removed, or modified.
  if [ -f "/boot.dmg" ]; then
    input_dmg="/boot.dmg"
  elif [ -s "$stored_dmg" ]; then
    input_dmg="$stored_dmg"
  fi

  if [ -n "$input_dmg" ]; then

    # XAR identifies InstallAssistant.pkg and compatible hybrid installation
    # media. Once detected, VERSION is intentionally ignored because the DMG
    # itself is authoritative.
    if isXarArchive "$input_dmg"; then

      if ! checkInstallationPackage "$input_dmg"; then
        return 1
      fi

      if ! createInstallationImage "$input_dmg" "$dest"; then
        return 1
      fi

      # Only our persisted $STORAGE/boot.dmg is disposable after success.
      [ "$input_dmg" != "$stored_dmg" ] || rm -f -- "$stored_dmg"

      return 0
    fi

    # Non-XAR DMGs keep the existing recovery-image behavior.
    if checkRecoveryDmg "$input_dmg"; then
      useRecoveryDmg "$input_dmg" "$dest"
      return $?
    fi

    error "The supplied boot.dmg is neither a bootable recovery image nor supported macOS installation media."
    return 1
  fi

  # VERSION is used only to select what to download when no DMG was supplied.
  if ! major=$(getInstallationMajor "$version"); then
    error "Installation files are supported for macOS Big Sur (11) through Tahoe (26)."
    return 1
  fi

  name=$(getInstallationName "$major") || return 1

  if ! getInstallationUrl "$major"; then
    return 1
  fi

  release="$INSTALLATION_RELEASE"
  url="$INSTALLATION_URL"

  if [ -z "$release" ] || [ -z "$url" ]; then
    error "Failed to resolve the macOS $name installation files URL."
    return 1
  fi

  info "Using macOS $name $release installation files."

  if ! downloadInstallationFiles "$release" "$url" "$download" "${CONNECTIONS:-1}"; then
    return 1
  fi

  # A completed, validated download becomes the generic persistent boot.dmg
  # input for subsequent starts.
  if ! mv -f "$download" "$stored_dmg"; then
    rm -f -- "$download" "$download.aria2"
    error "Failed to save installation media to $stored_dmg."
    return 1
  fi

  rm -f "$download.aria2"

  if ! createInstallationImage "$stored_dmg" "$dest"; then
    return 1
  fi

  rm -f -- "$stored_dmg"
  return 0
}

generateID() {

  # Machine identity must remain stable across restarts because OpenCore,
  # macOS activation, and the generated network identity all depend on it.
  restoreState UUID "id" || return 1

  [ -n "$UUID" ] && return 0

  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen --random) || return 1
  UUID="${UUID^^}"
  UUID="${UUID//[![:print:]]/}"

  [ -z "$UUID" ] && return 1

  writeState "id" "$UUID" || return 1

  return 0
}

generateAddress() {

  restoreState MAC "mac" || return 1

  [ -n "$MAC" ] && return 0

  # Derive a stable address from the UUID while retaining the Apple-assigned
  # 00:16:CB prefix expected by the generated OpenCore identity.
  # Generate Apple MAC address based on UUID value
  MAC=$(echo "$UUID" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/00:16:cb:\3:\4:\5/')
  MAC="${MAC^^}"

  writeState "mac" "$MAC" || return 1

  return 0
}

generateSerial() {

  local generated generatedSN generatedMLB

  restoreState SN "sn" || return 1
  restoreState MLB "mlb" || return 1

  [ -n "$SN" ] && [ -n "$MLB" ] && return 0

  # Generate a serial pair and use only the values that are still missing,
  # preserving any serial or board serial supplied by the user or restored from state.
  generated=$(/usr/local/bin/macserial --num 1 --model "${MODEL}" 2>/dev/null)

  generated="${generated##*$'\n'}"
  [[ "$generated" != *" | "* ]] && error "$generated" && return 1

  generatedMLB=${generated#*|}
  generatedMLB="${generatedMLB#"${generatedMLB%%[![:space:]]*}"}"
  generatedSN="${generated%%|*}"
  generatedSN="${generatedSN%"${generatedSN##*[![:space:]]}"}"

  [ -n "$SN" ] || SN="$generatedSN"
  [ -n "$MLB" ] || MLB="$generatedMLB"

  writeState "sn" "$SN" || return 1
  writeState "mlb" "$MLB" || return 1

  return 0
}

VERSION=$(strip "$VERSION")

if [ -z "$VERSION" ]; then

  VERSION="14"
  warn "no value specified for the VERSION variable, defaulting to \"${VERSION}\"."

fi

# Use version-specific storage so each macOS version has its own folder.
# Switching VERSION selects the corresponding existing installation without
# overwriting existing disks or redownloading the installation media again.
if [ ! -s "$BASE_IMG" ] && ! hasDisk; then
  STORAGE="$STORAGE/${VERSION,,}"
  BASE_IMG="$STORAGE/installer.img"
fi

# Installation media is required only while the primary disk is absent or blank.
if [ ! -s "$BASE_IMG" ] && ! hasData; then
  install "$VERSION" "$BASE_IMG" || exit 34
  setOwner "$BASE_IMG" || warn "failed to set the owner for \"$BASE_IMG\" !"
fi

if ! generateID; then
  error "Failed to generate UUID!" && exit 35
fi

if ! generateSerial; then
  error "Failed to generate serial number!" && exit 36
fi

if ! generateAddress; then
  error "Failed to generate MAC address!" && exit 37
fi

DISK_OPTS=""

# Keep the installation media writable so it can be modified in
# later setup stages without rebuilding or converting the media again.
if [ -s "$BASE_IMG" ]; then
  DISK_OPTS="-device virtio-blk-pci,drive=${BASE_IMG_ID},bus=pcie.0,addr=0x6"
  DISK_OPTS+=" -drive file=$BASE_IMG,id=$BASE_IMG_ID,format=raw,cache=unsafe,if=none"
fi

return 0
