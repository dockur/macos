#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_TOOLS="/run/install"
IMAGE_ASSETS="/assets/install"

checkDmgImage() {

  local file="$1"
  local size

  if [ ! -s "$file" ]; then
    error "Downloaded recovery image is missing or empty!"
    return 1
  fi

  size=$(stat -c%s "$file")

  if [ "$size" -lt 100000000 ]; then
    error "Downloaded recovery image is too small: $(formatBytes "$size")"
    return 1
  fi

  info "Checking recovery image format..."

  # qemu-img validates the disk container structure without mounting or
  # trusting filesystems inside the downloaded recovery image.
  if ! qemu-img info "$file" >/dev/null; then
    error "Downloaded recovery image is not a valid disk image!"
    return 1
  fi

  return 0
}

buildProductPackage() {

  local identifier="$1"
  local scripts="$2"
  local dest="$3"
  local work source_file
  local outer_listing scripts_listing

  work=$(mktemp -d "$STORAGE/tmp/package.XXXXXX") || return 1

  local component_name="component.pkg"
  local component="$work/$component_name"
  local verify="$work/verify"

  mkdir -p "$component" "$verify"

  # Match the payload-free component layout produced by Linux macOS package
  # generators: PackageInfo and Scripts live below component.pkg in the same
  # outer XAR as Distribution. component.pkg is not a nested XAR.
  if ! /usr/bin/sed \
      -e "s|@IDENTIFIER@|$identifier|g" \
      "$IMAGE_ASSETS/package/PackageInfo" > "$component/PackageInfo"; then
    rm -rf "$work"
    error "Failed to prepare PackageInfo for $identifier."
    return 1
  fi

  if ! (
    cd "$scripts"
    find . -print |
      cpio -o --format odc --owner 0:80 2>/dev/null |
      gzip -c > "$component/Scripts"
  ); then
    rm -rf "$work"
    error "Failed to create scripts archive for $identifier."
    return 1
  fi

  if ! /usr/bin/sed \
      -e "s|@IDENTIFIER@|$identifier|g" \
      -e "s|@COMPONENT@|$component_name|g" \
      "$IMAGE_ASSETS/package/Distribution" > "$work/Distribution"; then
    rm -rf "$work"
    error "Failed to prepare Distribution for $identifier."
    return 1
  fi

  rm -f "$dest"

  if ! (
    cd "$work"
    xar --compression none -cf "$dest" Distribution "$component_name"
  ); then
    rm -rf "$work"
    error "Failed to build product package $dest."
    return 1
  fi

  if ! outer_listing=$(xar -tf "$dest" 2>/dev/null); then
    rm -rf "$work" "$dest"
    error "Failed to inspect product package $dest."
    return 1
  fi

  for name in \
    Distribution \
    "$component_name/PackageInfo" \
    "$component_name/Scripts"; do

    if ! grep -Fxq "$name" <<< "$outer_listing"; then
      rm -rf "$work" "$dest"
      error "Product package $dest is missing $name."
      return 1
    fi
  done

  if ! (
    cd "$verify"
    xar -xf "$dest"
  ); then
    rm -rf "$work" "$dest"
    error "Failed to extract product package $dest for verification."
    return 1
  fi

  if ! python3 "$IMAGE_TOOLS/package/validate.py" \
      "$verify/Distribution" \
      "$verify/$component_name/PackageInfo" \
      "$identifier"; then
    rm -rf "$work" "$dest"
    error "Product package $dest failed XML validation."
    return 1
  fi

  if ! scripts_listing=$(
    gzip -dc "$verify/$component_name/Scripts" 2>/dev/null |
      cpio -it 2>/dev/null
  ); then
    rm -rf "$work" "$dest"
    error "Failed to inspect the scripts archive in $dest."
    return 1
  fi

  if ! grep -Fxq 'postinstall' <<< "$scripts_listing"; then
    rm -rf "$work" "$dest"
    error "Product package $dest does not contain its postinstall script."
    return 1
  fi

  mkdir -p "$verify/scripts"

  if ! (
    cd "$verify/scripts"
    gzip -dc "$verify/$component_name/Scripts" 2>/dev/null |
      cpio -idmu 2>/dev/null
  ); then
    rm -rf "$work" "$dest"
    error "Failed to extract the scripts archive in $dest."
    return 1
  fi

  for source_file in "$scripts"/*; do

    [ -f "$source_file" ] || continue

    local name="${source_file##*/}"
    local packaged_file="$verify/scripts/$name"

    if [ ! -f "$packaged_file" ] || ! cmp -s "$source_file" "$packaged_file"; then
      rm -rf "$work" "$dest"
      error "Packaged script data $name failed byte-for-byte validation."
      return 1
    fi

    local source_mode=$(stat -c '%a' "$source_file")
    local packaged_mode=$(stat -c '%a' "$packaged_file")

    if [ "$source_mode" != "$packaged_mode" ]; then
      rm -rf "$work" "$dest"
      error "Packaged script data $name has mode $packaged_mode instead of $source_mode."
      return 1
    fi

  done

  rm -rf "$work"
  return 0
}

createAdminPackage() {

  local dest="$1"

  local msg="Building unattended setup packages..."
  info "$msg"

  local work
  work=$(mktemp -d "$STORAGE/tmp/admin.XXXXXX") || return 1

  local scripts="$work/scripts"
  mkdir -p "$scripts"

  if ! python3 "$IMAGE_TOOLS/admin/create.py" \
      "$scripts" \
      "$SETUP_USERNAME" \
      "$SETUP_PASSWORD" \
      "$SETUP_AUTOLOGIN"; then
    rm -rf "$work"
    error "Failed to create unattended account data."
    return 1
  fi

  if ! cp -f "$IMAGE_TOOLS/admin/postinstall" "$scripts/postinstall"; then
    rm -rf "$work"
    error "Failed to prepare unattended account package script."
    return 1
  fi

  chmod 0755 "$scripts/postinstall" "$scripts/config"
  chmod 0600 "$scripts/user.plist"
  [ ! -f "$scripts/kcpassword" ] || chmod 0600 "$scripts/kcpassword"

  if ! bash -n "$scripts/postinstall"; then
    rm -rf "$work"
    error "Generated account package script is invalid."
    return 1
  fi

  if ! python3 "$IMAGE_TOOLS/admin/validate.py" \
      "$scripts/user.plist" "$SETUP_USERNAME"; then
    rm -rf "$work"
    error "Generated account record failed validation."
    return 1
  fi

  if ! buildProductPackage "com.macos.install.admin" "$scripts" "$dest"; then
    rm -rf "$work"
    return 1
  fi

  rm -rf "$work"
  return 0
}

createSkipSetupPackage() {

  local dest="$1"
  local work scripts

  work=$(mktemp -d "$STORAGE/tmp/skipsetup.XXXXXX") || return 1
  scripts="$work/scripts"
  mkdir -p "$scripts"

  if ! cp -f "$IMAGE_TOOLS/setup/postinstall" "$scripts/postinstall" ||
     ! cp -f "$IMAGE_ASSETS/setup/com.apple.SetupAssistant.plist" \
        "$scripts/com.apple.SetupAssistant.plist"; then
    rm -rf "$work"
    error "Failed to prepare Setup Assistant package scripts."
    return 1
  fi

  chmod 0755 "$scripts/postinstall"
  chmod 0644 "$scripts/com.apple.SetupAssistant.plist"

  if ! bash -n "$scripts/postinstall"; then
    rm -rf "$work"
    error "Generated Setup Assistant package script is invalid."
    return 1
  fi

  if ! buildProductPackage "com.macos.install.skipsetup" "$scripts" "$dest"; then
    rm -rf "$work"
    return 1
  fi

  rm -rf "$work"
  return 0
}

createAutomatedInstallationFiles() {

  local script="$1"
  local progress="$2"

  if ! cp -f "$IMAGE_TOOLS/recovery/macos-install.sh" "$script" ||
     ! cp -f "$IMAGE_TOOLS/recovery/progress-poc.js" "$progress"; then
    error "Failed to prepare automated Recovery files."
    return 1
  fi

  chmod 0755 "$script"
  chmod 0644 "$progress"

  return 0
}

patchRecoveryBootstrap() {

  local image="$1"
  local result

  if ! result=$(python3 "$IMAGE_TOOLS/recovery/patch.py" "$image"); then
    error "Failed to patch the Recovery startup hook."
    return 1
  fi

  info "$result"
  return 0
}

prepareAutomatedRecovery() {

  local source="$1"
  local dest="$2"
  local admin="$3"
  local setup="$4"
  local work script progress state qemu_info
  local msg="Preparing automated installation..."

  info "$msg" && html "$msg"

  work=$(mktemp -d "$STORAGE/tmp/recovery.XXXXXX") || return 1
  script="$work/macos-install.sh"
  progress="$work/progress-poc.js"
  state="$STORAGE/tmp/autoinstall"

  if ! createAutomatedInstallationFiles "$script" "$progress"; then
    rm -rf "$work"
    return 1
  fi

  [ -s "$admin" ] || {
    rm -rf "$work"
    error "Prebuilt account package is missing."
    return 1
  }

  [ -s "$setup" ] || {
    rm -rf "$work"
    error "Prebuilt Setup Assistant package is missing."
    return 1
  }

  if ! makeDir "$state"; then
    rm -rf "$work"
    error "Failed to create unattended installation state directory."
    return 1
  fi

  if ! cp -f "$script" "$state/macos-install.sh" ||
     ! cp -f "$progress" "$state/progress-poc.js" ||
     ! cp -f "$admin" "$state/admin.pkg" ||
     ! cp -f "$setup" "$state/skipsetup.pkg"; then
    rm -rf "$work"
    error "Failed to stage unattended installation files."
    return 1
  fi

  chmod 0755 "$state/macos-install.sh"
  chmod 0644 "$state/progress-poc.js" "$state/admin.pkg" "$state/skipsetup.pkg"

  if ! cmp -s "$script" "$state/macos-install.sh" ||
     ! cmp -s "$progress" "$state/progress-poc.js" ||
     ! cmp -s "$admin" "$state/admin.pkg" ||
     ! cmp -s "$setup" "$state/skipsetup.pkg"; then
    rm -rf "$work"
    error "Staged unattended installation files failed byte-for-byte validation."
    return 1
  fi

  if ! patchRecoveryBootstrap "$source"; then
    rm -rf "$work"
    return 1
  fi

  # The source keeps its .dmg suffix while being patched, so QEMU can probe
  # the exact final bytes using its DMG driver before the file is moved.
  if ! qemu_info=$(qemu-img info --output=json "$source" 2>/dev/null); then
    rm -rf "$work"
    error "Patched recovery image is not recognized by QEMU."
    return 1
  fi

  if ! python3 -c '
import json, sys
info = json.load(sys.stdin)
raise SystemExit(0 if info.get("format") == "dmg" else 1)
' <<< "$qemu_info"; then
    rm -rf "$work"
    error "QEMU did not identify the patched recovery image as DMG."
    return 1
  fi

  rm -rf "$work"

  if ! mv -f "$source" "$dest"; then
    error "Failed to save automated recovery image to $dest."
    return 1
  fi

  return 0
}

return 0
