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

  local count catalog catalog_url url
  local pairs distfile dist version
  local best_version="" best_url=""

  INSTALLATION_RELEASE=""
  INSTALLATION_URL=""

  catalog=$(mktemp) || return 1
  pairs=$(mktemp) || { rm -f "$catalog"; return 1; }
  distfile=$(mktemp) || { rm -f "$catalog" "$pairs"; return 1; }

  catalog_url=$(getInstallationCatalog)

  local msg="Downloading Apple installation catalog..."
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
  local size magic

  if [ ! -s "$file" ]; then
    error "Downloaded installation package is missing or empty!"
    return 1
  fi

  size=$(stat -c%s -- "$file") || return 1

  if (( size < 5000000000 )); then
    error "Downloaded installation package is unexpectedly small: $(formatBytes "$size")"
    return 1
  fi

  magic=$(head -c 4 -- "$file" 2>/dev/null || :)

  if [[ "$magic" != "xar!" ]]; then
    error "Downloaded InstallAssistant.pkg is not a valid XAR package."
    return 1
  fi

  return 0
}

downloadInstallationFiles() {

  local version="$1"
  local url="$2"
  local dest="$3"
  local connections="${4:-1}"
  local expected
  local msg="Downloading macOS installation files..."

  info "Checking macOS $version download size..."

  expected=$(curl --disable --max-time 30 --silent --show-error --fail --location --head \
    "$url" 2>/dev/null |
    awk 'tolower($1) == "content-length:" {gsub("\r", "", $2); value=$2} END {print value}' || :)

  local rc=0

  info "$msg" && html "$msg"

  downloadToFile \
    "$url" \
    "$dest" \
    "$msg" \
    "${expected:-0}" \
    "$connections" \
    "Y" || rc=$?

  (( rc == 0 )) || return "$rc"

  checkInstallationPackage "$dest"
}

archiveEntry() {

  local archive="$1"
  local name="$2"
  local type=()

  # InstallAssistant.pkg is both a XAR package and a DMG-compatible file.
  # Force the XAR handler when the archive has a XAR header, otherwise 7-Zip
  # may detect the DMG footer and hide package members such as SharedSupport.dmg.
  if [ "$(head -c 4 -- "$archive" 2>/dev/null || :)" = "xar!" ]; then
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
  local type=()

  [ -n "$entry" ] || return 1
  mkdir -p "$dest"

  if [ "$(head -c 4 -- "$archive" 2>/dev/null || :)" = "xar!" ]; then
    type=(-txar)
  fi

  7z x "${type[@]}" -y "$archive" "$entry" -o"$dest" > /dev/null
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
  local listing entry payload out app
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

    if ! 7z x -txar -y "$pkg" "$entry" -o"$out/archive" > /dev/null 2>&1; then
      continue
    fi

    payload="$out/archive/$entry"
    [ -f "$payload" ] || payload=$(find "$out/archive" -type f -name Payload -print -quit 2>/dev/null || :)
    [ -f "$payload" ] || continue

    if ! 7z x -y "$payload" -o"$out/files" > /dev/null 2>&1; then
      bsdtar -xf "$payload" -C "$out/files" > /dev/null 2>&1 || continue
    fi

    if app=$(findInstallationApp "$out/files"); then
      rm -f "$listing"
      echo "$app"
      return 0
    fi

  done < <(sed -n 's/^Path = //p' "$listing")

  rm -f "$listing"
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

  local pkg="$1"
  local dest="$2"
  local version="$3"
  local major="$4"
  local work="$STORAGE/tmp/macos-installation"
  local package_dir="$work/package"
  local support_dir="$work/support"
  local base_dir="$work/base"
  local payload_dir="$work/payload"
  local shared_entry base_entry shared
  local base boot root base_app package_app
  local source_app root_app app_name label tmp

  local msg="Extracting system data..."
  info "$msg" && html "$msg" 

  rm -rf "$work"
  mkdir -p "$package_dir" "$support_dir" "$base_dir" "$payload_dir"

  shared_entry=$(archiveEntry "$pkg" "SharedSupport.dmg")

  if [ -z "$shared_entry" ]; then
    error "InstallAssistant.pkg does not contain SharedSupport.dmg."
    rm -rf "$work"
    return 1
  fi

  if ! extractArchiveEntry "$pkg" "$shared_entry" "$package_dir"; then
    error "Failed to extract SharedSupport.dmg from InstallAssistant.pkg."
    rm -rf "$work"
    return 1
  fi

  shared="$package_dir/$shared_entry"
  [ -f "$shared" ] || shared=$(find "$package_dir" -type f -name SharedSupport.dmg -print -quit 2>/dev/null || :)

  if [ ! -f "$shared" ]; then
    error "Failed to locate extracted SharedSupport.dmg."
    rm -rf "$work"
    return 1
  fi

  # Try to recover the installation application skeleton while the package
  # is still available. BaseSystem contains a usable installation bundle too, so
  # failure here is non-fatal and has a fallback below.
  info "Extracting macOS installation application..."

  package_app=$(extractPackageInstallationApp "$pkg" "$payload_dir" 2>/dev/null || :)

  base_entry=$(archiveEntry "$shared" "BaseSystem.dmg")

  if [ -z "$base_entry" ]; then
    error "SharedSupport.dmg does not contain BaseSystem.dmg."
    rm -rf "$work"
    return 1
  fi

  local msg="Extracting recovery image..."
  info "$msg" && html "$msg" 

  if ! extractArchiveEntry "$shared" "$base_entry" "$support_dir"; then
    error "Failed to extract BaseSystem.dmg from SharedSupport.dmg."
    rm -rf "$work"
    return 1
  fi

  base="$support_dir/$base_entry"
  [ -f "$base" ] || base=$(find "$support_dir" -type f -name BaseSystem.dmg -print -quit 2>/dev/null || :)

  if [ ! -f "$base" ]; then
    error "Failed to locate extracted BaseSystem.dmg."
    rm -rf "$work"
    return 1
  fi

  info "Expanding recovery image..."

  if ! 7z x -y "$base" -o"$base_dir" > /dev/null; then
    error "Failed to extract BaseSystem.dmg."
    rm -rf "$work"
    return 1
  fi

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
    rm -rf "$root_app"

    if ! cp -a "$source_app" "$root_app"; then
      error "Failed to place the macOS installation application on the installation volume."
      rm -rf "$work"
      return 1
    fi
  fi

  mkdir -p "$root_app/Contents/SharedSupport"
  rm -f "$root_app/Contents/SharedSupport/SharedSupport.dmg"

  # Move instead of copy so the 12-16 GB payload exists only once while the
  # writable image is being assembled.
  if ! mv "$shared" "$root_app/Contents/SharedSupport/SharedSupport.dmg"; then
    error "Failed to place SharedSupport.dmg in the installation application."
    rm -rf "$work"
    return 1
  fi

  # Recovery's own installation bundle is normally the process launched at boot.
  # Point it at the same local payload so it cannot fall back to Internet
  # Recovery merely because the installation application also exists at volume root.
  if [ -d "$base_app" ] && [ "$base_app" != "$root_app" ]; then
    mkdir -p "$base_app/Contents/SharedSupport"
    rm -f "$base_app/Contents/SharedSupport/SharedSupport.dmg"
    ln -s "/$app_name/Contents/SharedSupport/SharedSupport.dmg" \
      "$base_app/Contents/SharedSupport/SharedSupport.dmg"
  fi

  touch "$root/.IAPhysicalMedia" "$root/.metadata_never_index"

  # The package is no longer needed once its payload has been moved into the
  # expanded BaseSystem, which keeps peak storage use substantially lower.
  rm -f -- "$pkg" "$pkg.aria2"
  rm -rf "$package_dir" "$support_dir" "$payload_dir"

  label="Install macOS $(getInstallationName "$major")"
  tmp="$dest.tmp"
  rm -f "$tmp"

  info "Creating macOS $version installation image..."
  html "Creating macOS installation image..."

  local partition="$work/installation.hfs"
  local links="$work/symlinks"
  local hfslog="$work/hfsplus.log"
  local link path target
  local payload_size partition_size disk_size partition_sectors
  local mib=$((1024 * 1024))
  local gib=$((1024 * 1024 * 1024))

  if ! payload_size=$(du -sb --apparent-size -- "$root" | awk '{print $1}'); then
    rm -f "$tmp"
    rm -rf "$work"
    error "Failed to calculate installation size."
    return 1
  fi

  # Leave 2 GiB free so the image stays writable for later customization.
  partition_size=$((payload_size + (2 * gib)))
  partition_size=$((((partition_size + mib - 1) / mib) * mib))
  disk_size=$((partition_size + (2 * mib)))
  partition_sectors=$((partition_size / 512))

  rm -f "$partition" "$links" "$hfslog"
  truncate -s "$partition_size" "$partition"

  info "Creating HFS+ installation filesystem..."

  if ! mkfs.hfsplus -v "$label" "$partition" > /dev/null; then
    rm -f "$tmp" "$partition"
    rm -rf "$work"
    error "Failed to create HFS+ installation filesystem."
    return 1
  fi

  # libdmg-hfsplus addall follows host symlinks. Remove them from the staging
  # tree first and recreate them explicitly inside HFS+ afterwards.

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

  while IFS= read -r -d '' path && IFS= read -r -d '' target; do
    if ! hfsplus "$partition" symlink "$path" "$target" >> "$hfslog" 2>&1; then
      tail -n 20 "$hfslog" >&2 || :
      rm -f "$tmp" "$partition"
      rm -rf "$work"
      error "Failed to recreate installation symlink: $path"
      return 1
    fi
  done < "$links"

  # Wrap the populated HFS+ partition in a sparse GPT raw disk. No loop device
  # or host filesystem mount is required.
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
  local pkg="$STORAGE/InstallAssistant.pkg"

  if ! major=$(getInstallationMajor "$version"); then
    error "Installation files are supported for macOS Big Sur (11) through Tahoe (26)."
    return 1
  fi

  name=$(getInstallationName "$major") || return 1

  if ! makeDir "$STORAGE"; then
    error "Failed to create directory \"$STORAGE\" !"
    return 1
  fi

  # New installation media invalidates cached firmware state that may still
  # point at older installation media or an incompatible boot entry.
  find "$STORAGE" -maxdepth 1 -type f \( -iname '*.rom' -or -iname '*.vars' \) -delete

  if [ -f "/boot.img" ]; then

    info "Using custom macOS installation image from /boot.img..."

    if ! cp "/boot.img" "$dest"; then
      rm -f "$dest"
      return 1
    fi

    checkWritableInstallationImage "$dest" || { rm -f "$dest"; return 1; }

    return 0
  fi

  if [ -f "/boot.dmg" ]; then

    info "Converting custom macOS boot image from dmg to raw format..."

    if ! qemu-img convert -p -O raw "/boot.dmg" "$dest"; then
      rm -f "$dest"
      return 1
    fi

    checkWritableInstallationImage "$dest" || { rm -f "$dest"; return 1; }

    return 0
  fi

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

  if [ -s "$pkg" ]; then
    info "Checking cached InstallAssistant.pkg..."

    if ! checkInstallationPackage "$pkg"; then
      rm -f "$pkg" "$pkg.aria2"
    fi
  fi

  if [ ! -s "$pkg" ]; then
    if ! downloadInstallationFiles "$release" "$url" "$pkg" "${CONNECTIONS:-1}"; then
      rm -f "$pkg" "$pkg.aria2"
      return 1
    fi
  fi

  createInstallationImage "$pkg" "$dest" "$release" "$major"
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
