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

BASE_IMG="$STORAGE/setup.dmg"

# Fixed setup values for the unattended-install proof. These are intentionally
# not environment variables yet; locale settings will be implemented only
# after the basic zero-click path has been proven.
SETUP_USERNAME="admin"
SETUP_PASSWORD="admin"
SETUP_AUTOLOGIN="Y"
SETUP_LANGUAGE="en-US"
SETUP_REGION="US"
SETUP_KEYBOARD="U.S."
SETUP_TIMEZONE="Etc/UTC"

INSTALL_STATE_DIR=""

function getRandom() {

  local length="${1}"
  local result=""
  local chars=("0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "A" "B" "C" "D" "E" "F")

  # Apple recovery requests require opaque hexadecimal nonce fields; they
  # are session tokens rather than persistent machine identity.
  for ((i=0; i<length; i++)); do
      result+="${chars[$((RANDOM % 16))]}"
  done

  echo "$result"
  return 0
}

checkDownloadSize() {

  local file="$1"
  local expected="$2"
  local actual

  if [ -z "$expected" ]; then
    warn "Could not determine expected recovery image size."
    return 0
  fi

  if ! actual=$(stat -c%s -- "$file" 2>/dev/null); then
    error "Failed to determine downloaded recovery image size."
    return 1
  fi

  if (( actual != expected )); then
    error "Downloaded recovery image is incomplete: got $(formatBytes "$actual"), expected $(formatBytes "$expected")."
    return 1
  fi

  return 0
}

function download() {

  local info
  local dest="$1"
  local board="$2"
  local version="$3"
  local connections="${4:-1}"
  local type="latest"
  local appleSession
  local downloadLink
  local downloadSession
  local log expected
  local mlb="00000000000000000"
  local reason response

  local msg="Downloading macOS ${version^}"
  info "$msg recovery image..." && html "$msg..."

  # The initial request exists only to obtain Apple's recovery-session cookie
  # from the verbose response headers.
  appleSession=$(curl --disable --max-time 30 -v -H "Host: osrecovery.apple.com" \
                      -H "Connection: close" \
                      -A "InternetRecovery/1.0" https://osrecovery.apple.com/ 2>&1 | tr ';' '\n' | awk -F'session=|;' '/session=/ {print $2; exit}' || :)

  if [ -z "$appleSession" ]; then
    error "Failed to obtain Apple recovery session."
    return 1
  fi

  log=$(mktemp)
  response=$(mktemp)

  # Submit the board identifier and fresh request nonces while capturing both
  # Apple's text response and curl's diagnostic output separately.
  if curl --disable --max-time 60 --silent --show-error --fail-with-body \
      --request POST \
      --header "Host: osrecovery.apple.com" \
      --header "Connection: close" \
      --user-agent "InternetRecovery/1.0" \
      --cookie "session=\"${appleSession}\"" \
      --header "Content-Type: text/plain" \
      --data $'cid='"$(getRandom 16)"$'\nsn='"${mlb}"$'\nbid='"${board}"$'\nk='"$(getRandom 64)"$'\nfg='"$(getRandom 64)"$'\nos='"${type}" \
      --output "$response" \
      https://osrecovery.apple.com/InstallationPayload/RecoveryImage \
      2>"$log"; then
    local code=0
  else
    local code=$?
  fi

  # Apple's response is space-delimited key/value text. Splitting it into
  # records makes the image URL and expiring asset token selectable below.
  info=$(tr ' ' '\n' < "$response")
  reason=$(sed -En 's/^curl: \([0-9]+\) //p' "$log" | tail -n 1)

  rm -f "$response" "$log"

  if (( code != 0 )); then

    msg="Failed to connect to the Apple servers"

    if [ -n "$reason" ]; then
      error "$msg: ${reason%.}."
    else
      error "$msg with exit status $code."
    fi

    return 1
  fi

  # The recovery response supplies the CDN URL and its expiring token as
  # separate records; both are required for the authenticated download.
  downloadLink=$(echo "$info" | grep 'oscdn' | grep 'dmg' | head -n 1 || :)
  downloadSession=$(echo "$info" | grep 'expires' | grep 'dmg' | head -n 1 || :)

  if [ -z "$downloadLink" ] || [ -z "$downloadSession" ]; then

    [ -n "$info" ] && echo "$info" && echo
    error "The Apple servers returned an unexpected response."

    return 1
  fi

  # Content-Length is optional validation metadata. The DMG format checks
  # below remain authoritative when the CDN omits it.
  expected=$(curl --disable -fsSI \
    -H "Host: oscdn.apple.com" \
    -H "Connection: close" \
    -A "InternetRecovery/1.0" \
    -H "Cookie: AssetToken=${downloadSession}" \
    "$downloadLink" \
    | awk 'tolower($1) == "content-length:" {gsub("\r","",$2); print $2; exit}' || :)

  # Each attempt uses a newly issued Apple download session, so do not
  # resume a partial download created with an older session.
  rm -f -- "$dest" "$dest.aria2"

  if downloadToFile \
      "$downloadLink" \
      "$dest" \
      "$msg" \
      "${expected:-0}" \
      "$connections" \
      "N" \
      --header "Host: oscdn.apple.com" \
      --header "Connection: close" \
      --user-agent "InternetRecovery/1.0" \
      --header "Cookie: AssetToken=${downloadSession}"; then
    local rc=0
  else
    local rc=$?
  fi

  if (( rc != 0 )); then
    rm -f -- "$dest" "$dest.aria2"
    return "$rc"
  fi

  if ! checkDownloadSize "$dest" "$expected"; then
    rm -f -- "$dest" "$dest.aria2"
    return 1
  fi

  if ! checkDmgImage "$dest"; then
    rm -f -- "$dest" "$dest.aria2"
    return 1
  fi

  return 0
}

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
  cat > "$component/PackageInfo" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<pkg-info postinstall-action="none" preserve-xattr="false" format-version="2" identifier="$identifier" version="1.0" auth="root">
    <bundle-version/>
    <upgrade-bundle/>
    <update-bundle/>
    <atomic-update-bundle/>
    <strict-identifier/>
    <relocate/>
    <scripts>
        <postinstall file="./postinstall"/>
    </scripts>
</pkg-info>
EOF

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

  cat > "$work/Distribution" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <pkg-ref id="$identifier">
        <bundle-version/>
    </pkg-ref>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default">
            <line choice="$identifier"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$identifier" visible="false">
        <pkg-ref id="$identifier"/>
    </choice>
    <pkg-ref id="$identifier" version="1.0" onConclusion="none" installKBytes="0">#$component_name</pkg-ref>
    <product id="$identifier" version="1.0"/>
</installer-gui-script>
EOF

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

  if ! python3 - \
      "$verify/Distribution" \
      "$verify/$component_name/PackageInfo" \
      "$identifier" <<'PY'
import sys
import xml.etree.ElementTree as ET

distribution, package_info, expected = sys.argv[1:]

droot = ET.parse(distribution).getroot()
products = droot.findall("product")
if len(products) != 1 or products[0].get("id") != expected:
    raise SystemExit("Distribution product id is missing or incorrect")

refs = [
    element for element in droot.findall("pkg-ref")
    if (element.text or "").strip() == "#component.pkg"
]
if len(refs) != 1 or refs[0].get("id") != expected:
    raise SystemExit("Distribution component reference is missing or incorrect")

metadata_refs = [
    element for element in droot.findall("pkg-ref")
    if element.find("bundle-version") is not None
]
if len(metadata_refs) != 1 or metadata_refs[0].get("id") != expected:
    raise SystemExit("Distribution bundle metadata reference is missing")

proot = ET.parse(package_info).getroot()
if proot.get("identifier") != expected:
    raise SystemExit("PackageInfo identifier is incorrect")

post = proot.find("./scripts/postinstall")
if post is None or post.get("file") != "./postinstall":
    raise SystemExit("PackageInfo postinstall entry is missing")
PY
  then
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

  if ! python3 - \
      "$scripts" \
      "$SETUP_USERNAME" \
      "$SETUP_PASSWORD" \
      "$SETUP_AUTOLOGIN" <<'PY'
import hashlib
import os
import plistlib
import secrets
import shlex
import sys
import uuid

out, username, password, autologin = sys.argv[1:]
generated_uid = str(uuid.uuid4()).upper()

iterations = 30000 + secrets.randbelow(20000)
salt = secrets.token_bytes(32)
entropy = hashlib.pbkdf2_hmac(
    "sha512", password.encode("utf-8"), salt, iterations, dklen=128
)

shadow = {
    "SALTED-SHA512-PBKDF2": {
        "entropy": entropy,
        "iterations": iterations,
        "salt": salt,
    }
}
shadow_data = plistlib.dumps(shadow, fmt=plistlib.FMT_BINARY)

writers = [
    "_writers_hint",
    "_writers_jpegphoto",
    "_writers_passwd",
    "_writers_picture",
    "_writers_realname",
    "_writers_UserCertificate",
]

user = {
    "name": [username],
    "uid": ["501"],
    "gid": ["20"],
    "home": [f"/Users/{username}"],
    "realname": [username],
    "shell": ["/bin/bash"],
    "generateduid": [generated_uid],
    "passwd": ["********"],
    "authentication_authority": [
        ";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"
    ],
    "ShadowHashData": [shadow_data],
}
for key in writers:
    user[key] = [username]

with open(os.path.join(out, "user.plist"), "wb") as handle:
    plistlib.dump(user, handle, fmt=plistlib.FMT_XML, sort_keys=False)

with open(os.path.join(out, "config"), "w", encoding="utf-8") as handle:
    handle.write("USERNAME=" + shlex.quote(username) + "\n")
    handle.write("UUID=" + shlex.quote(generated_uid) + "\n")
    handle.write("AUTOLOGIN=" + shlex.quote(autologin) + "\n")

if autologin.lower() in ("1", "true", "yes", "y", "on"):
    key = [125, 137, 82, 35, 210, 188, 221, 234, 163, 185, 31]
    data = [ord(char) for char in password] + [0]
    remainder = len(data) % 12
    if remainder:
        data.extend([0] * (12 - remainder))
    for offset in range(0, len(data), len(key)):
        for index in range(offset, min(offset + len(key), len(data))):
            data[index] ^= key[index - offset]
    if not data:
        data = [125] + [0] * 11
    with open(os.path.join(out, "kcpassword"), "wb") as handle:
        handle.write(bytes(data))
PY
  then
    rm -rf "$work"
    error "Failed to create unattended account data."
    return 1
  fi

  cat > "$scripts/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

MYDIR="${0%/*}"
. "$MYDIR/config"

TARGET="${3:-/}"
if [ "$TARGET" = "/" ]; then
  PREFIX=""
else
  PREFIX="${TARGET%/}"
fi

USER_DIR="$PREFIX/private/var/db/dslocal/nodes/Default/users"
ADMIN_PLIST="$PREFIX/private/var/db/dslocal/nodes/Default/groups/admin.plist"
LOGIN_PLIST="$PREFIX/Library/Preferences/com.apple.loginwindow"
PLISTBUDDY="/usr/libexec/PlistBuddy"

fail() {
  echo "account package: $1" >&2
  exit 1
}

plist_array_add() {

  local plist="$1"
  local array="$2"
  local value="$3"
  local current

  current=$("$PLISTBUDDY" -c "Print :$array" "$plist" 2>/dev/null || :)

  if [ -z "$current" ]; then
    "$PLISTBUDDY" -c "Add :$array array" "$plist" >/dev/null ||
      fail "failed to create $array in $plist"
  elif printf '%s\n' "$current" | /usr/bin/awk -v wanted="$value" '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == wanted) found=1
    }
    END { exit(found ? 0 : 1) }
  '; then
    return 0
  fi

  "$PLISTBUDDY" -c "Add :$array: string \"$value\"" "$plist" >/dev/null ||
    fail "failed to add $value to $array"
}

[ -d "$USER_DIR" ] || fail "local user database is missing"
[ -f "$ADMIN_PLIST" ] || fail "admin group database is missing"
[ -f "$MYDIR/user.plist" ] || fail "user plist is missing"

/bin/cp "$MYDIR/user.plist" "$USER_DIR/$USERNAME.plist" ||
  fail "failed to install local user record"
/usr/sbin/chown 0:0 "$USER_DIR/$USERNAME.plist" ||
  fail "failed to set local user ownership"
/bin/chmod 0600 "$USER_DIR/$USERNAME.plist" ||
  fail "failed to set local user permissions"

plist_array_add "$ADMIN_PLIST" users "$USERNAME"
plist_array_add "$ADMIN_PLIST" groupmembers "$UUID"

if [ "$AUTOLOGIN" = "Y" ]; then
  [ -f "$MYDIR/kcpassword" ] || fail "kcpassword is missing"
  /bin/mkdir -p "$PREFIX/private/etc" ||
    fail "failed to create private/etc"
  /bin/cp "$MYDIR/kcpassword" "$PREFIX/private/etc/kcpassword" ||
    fail "failed to install kcpassword"
  /usr/sbin/chown 0:0 "$PREFIX/private/etc/kcpassword" ||
    fail "failed to set kcpassword ownership"
  /bin/chmod 0600 "$PREFIX/private/etc/kcpassword" ||
    fail "failed to set kcpassword permissions"

  /usr/bin/defaults write "$LOGIN_PLIST" autoLoginUser "$USERNAME" ||
    fail "failed to configure automatic login"
fi

exit 0
POSTINSTALL

  chmod 0755 "$scripts/postinstall" "$scripts/config"
  chmod 0600 "$scripts/user.plist"
  [ ! -f "$scripts/kcpassword" ] || chmod 0600 "$scripts/kcpassword"

  if ! bash -n "$scripts/postinstall"; then
    rm -rf "$work"
    error "Generated account package script is invalid."
    return 1
  fi

  if ! python3 - "$scripts/user.plist" "$SETUP_USERNAME" <<'PY'
import plistlib
import sys

path, expected = sys.argv[1:]
with open(path, "rb") as handle:
    user = plistlib.load(handle)

assert user["name"] == [expected]
assert user["uid"] == ["501"]
assert user["gid"] == ["20"]
assert user["realname"] == [expected]
assert user["authentication_authority"] == [
    ";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"
]

shadow = plistlib.loads(user["ShadowHashData"][0])
record = shadow["SALTED-SHA512-PBKDF2"]
assert 30000 <= record["iterations"] < 50000
assert len(record["salt"]) == 32
assert len(record["entropy"]) == 128
PY
  then
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

  cat > "$scripts/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

TARGET="${3:-/}"
if [ "$TARGET" = "/" ]; then
  PREFIX=""
else
  PREFIX="${TARGET%/}"
fi

SYSTEM_PLIST="$PREFIX/System/Library/CoreServices/SystemVersion.plist"
SETUP_PLIST="$PREFIX/Library/User Template/Non_localized/Library/Preferences/com.apple.SetupAssistant.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"

fail() {
  echo "setup package: $1" >&2
  exit 1
}

[ -f "$SYSTEM_PLIST" ] || fail "target SystemVersion.plist is missing"

OS_VERSION=$("$PLISTBUDDY" -c 'Print :ProductVersion' "$SYSTEM_PLIST" 2>/dev/null || :)
OS_BUILD=$("$PLISTBUDDY" -c 'Print :ProductBuildVersion' "$SYSTEM_PLIST" 2>/dev/null || :)

[ -n "$OS_VERSION" ] || fail "target ProductVersion is missing"
[ -n "$OS_BUILD" ] || fail "target ProductBuildVersion is missing"

/bin/mkdir -p "$PREFIX/private/var/db" ||
  fail "failed to create setup state directory"
/usr/bin/touch "$PREFIX/private/var/db/.AppleSetupDone" ||
  fail "failed to mark system Setup Assistant complete"

/bin/mkdir -p "$PREFIX/Library/User Template/English.lproj" ||
  fail "failed to create English user template"
/usr/bin/touch "$PREFIX/Library/User Template/English.lproj/.skipbuddy" ||
  fail "failed to create first-login skip marker"

/bin/mkdir -p "${SETUP_PLIST%/*}" ||
  fail "failed to create Setup Assistant preference directory"

cat > "$SETUP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>DidSeeAccessibility</key>
    <true/>
    <key>DidSeeActivationLock</key>
    <false/>
    <key>DidSeeAppStore</key>
    <false/>
    <key>DidSeeAppearanceSetup</key>
    <true/>
    <key>DidSeeApplePaySetup</key>
    <false/>
    <key>DidSeeAvatarSetup</key>
    <false/>
    <key>DidSeeCloudSetup</key>
    <true/>
    <key>DidSeePrivacy</key>
    <true/>
    <key>DidSeeScreenTime</key>
    <true/>
    <key>DidSeeSiriSetup</key>
    <true/>
    <key>DidSeeSyncSetup</key>
    <false/>
    <key>DidSeeSyncSetup2</key>
    <false/>
    <key>DidSeeTouchIDSetup</key>
    <false/>
    <key>DidSeeTrueTone</key>
    <true/>
    <key>DidSeeiCloudLoginForStorageServices</key>
    <true/>
    <key>LastPreLoginTasksPerformedBuild</key>
    <string>$OS_BUILD</string>
    <key>LastPreLoginTasksPerformedVersion</key>
    <string>$OS_VERSION</string>
    <key>LastPrivacyBundleVersion</key>
    <string>2</string>
    <key>LastSeenBuddyBuildVersion</key>
    <string>$OS_BUILD</string>
    <key>LastSeenCloudProductVersion</key>
    <string>$OS_VERSION</string>
    <key>LastSeenDiagnosticsProductVersion</key>
    <string>$OS_VERSION</string>
    <key>LastSeenSiriProductVersion</key>
    <string>$OS_VERSION</string>
    <key>MiniBuddyLaunchReason</key>
    <integer>0</integer>
    <key>MiniBuddyLaunchedPostMigration</key>
    <false/>
    <key>MiniBuddyShouldLaunchToResumeSetup</key>
    <false/>
    <key>NSAddServicesToContextMenus</key>
    <false/>
    <key>PreviousBuildVersion</key>
    <string>0</string>
    <key>PreviousSystemVersion</key>
    <string>0</string>
    <key>SkipFirstLoginOptimization</key>
    <false/>
</dict>
</plist>
EOF

/usr/bin/plutil -lint "$SETUP_PLIST" >/dev/null ||
  fail "generated Setup Assistant plist is invalid"

/usr/sbin/chown 0:0 \
  "$PREFIX/private/var/db/.AppleSetupDone" \
  "$PREFIX/Library/User Template/English.lproj/.skipbuddy" \
  "$SETUP_PLIST" ||
  fail "failed to set setup file ownership"

/bin/chmod 0644 \
  "$PREFIX/private/var/db/.AppleSetupDone" \
  "$PREFIX/Library/User Template/English.lproj/.skipbuddy" \
  "$SETUP_PLIST" ||
  fail "failed to set setup file permissions"

exit 0
POSTINSTALL

  chmod 0755 "$scripts/postinstall"

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
  local plist="$2"

  cat > "$script" <<'RECOVERY_SCRIPT'
#!/bin/bash
set -u

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

LOCAL_LOG="/var/log/macos-install.log"
STATE_DIR="/Volumes/installstate"
STATE_LOG="$STATE_DIR/install.log"
STARTED="$STATE_DIR/started"
TARGET_VOLUME="/Volumes/Macintosh HD"
ADMIN_PACKAGE="$STATE_DIR/admin.pkg"
SETUP_PACKAGE="$STATE_DIR/skipsetup.pkg"
MIN_TARGET_SIZE=$((16 * 1024 * 1024 * 1024))

exec >> "$LOCAL_LOG" 2>&1

echo "[log] unattended installation starting"

mount_state_share() {

  local count=0

  while (( count < 120 )); do

    if [ -d "$STATE_DIR" ]; then
      return 0
    fi

    /sbin/mount_9p installstate >/dev/null 2>&1 || :

    [ -d "$STATE_DIR" ] && return 0

    count=$((count + 1))
    sleep 1
  done

  return 1
}

fail() {

  local message="$1"

  echo "[log] ERROR: $message"
  [ -d "$STATE_DIR" ] && rm -f "$STARTED"
  exit 1
}

select_target_disk() {

  local disk info size
  local best=""
  local best_size=0

  while IFS= read -r disk; do

    [ -n "$disk" ] || continue

    info=$(/usr/sbin/diskutil info "/dev/$disk" 2>/dev/null || :)
    [ -n "$info" ] || continue

    if printf '%s\n' "$info" |
       /usr/bin/grep -Eq '^[[:space:]]*(Media|Device) Read-Only:[[:space:]]*Yes'; then
      continue
    fi

    size=$(printf '%s\n' "$info" |
      /usr/bin/sed -nE 's/^[[:space:]]*Disk Size:.*\(([0-9]+) Bytes\).*/\1/p' |
      /usr/bin/head -n 1)

    [[ "$size" =~ ^[0-9]+$ ]] || continue
    (( size >= MIN_TARGET_SIZE )) || continue

    echo "[log] candidate target /dev/$disk ($size bytes)" >&2

    if (( size > best_size )); then
      best="$disk"
      best_size="$size"
    fi

  done < <(
    /usr/sbin/diskutil list physical 2>/dev/null |
      /usr/bin/sed -nE 's#^/dev/(disk[0-9]+).*#\1#p'
  )

  [ -n "$best" ] || return 1
  printf '/dev/%s\n' "$best"
}

find_startosinstall() {

  local file

  for file in \
    /Volumes/*/Install\ macOS*.app/Contents/Resources/startosinstall \
    /Volumes/*/Install\ OS\ X*.app/Contents/Resources/startosinstall \
    /Volumes/*/Install\ Mac\ OS\ X*.app/Contents/Resources/startosinstall \
    /Install\ macOS*.app/Contents/Resources/startosinstall \
    /Install\ OS\ X*.app/Contents/Resources/startosinstall \
    /Install\ Mac\ OS\ X*.app/Contents/Resources/startosinstall \
    /Applications/Install\ macOS*.app/Contents/Resources/startosinstall \
    /Applications/Install\ OS\ X*.app/Contents/Resources/startosinstall \
    /Applications/Install\ Mac\ OS\ X*.app/Contents/Resources/startosinstall; do

    if [ -x "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done

  return 1
}

if ! mount_state_share; then
  fail "failed to mount installation state share"
fi

if ! : > "$STATE_DIR/.write-test" 2>/dev/null; then
  fail "installation state share is not writable"
fi
rm -f "$STATE_DIR/.write-test"

cat "$LOCAL_LOG" >> "$STATE_LOG" 2>/dev/null || :
exec >> "$STATE_LOG" 2>&1

echo "[log] installation state share mounted"

if [ -e "$STARTED" ]; then
  echo "[log] installation was already started; refusing to erase the target disk again"
  exit 0
fi

[ -s "$ADMIN_PACKAGE" ] || fail "account package is missing"
[ -s "$SETUP_PACKAGE" ] || fail "Setup Assistant package is missing"

STARTOSINSTALL=""
count=0
while (( count < 120 )); do
  STARTOSINSTALL=$(find_startosinstall || :)
  [ -n "$STARTOSINSTALL" ] && break
  count=$((count + 1))
  sleep 1
done

[ -n "$STARTOSINSTALL" ] || fail "startosinstall was not found in the recovery image"

echo "[log] using $STARTOSINSTALL"

USAGE=$("$STARTOSINSTALL" --usage 2>&1 || :)
[ -n "$USAGE" ] || fail "startosinstall did not return usage information"

printf '%s\n' "$USAGE" | /usr/bin/grep -q -- '--installpackage' ||
  fail "startosinstall does not support --installpackage"

echo "[log] account and Setup Assistant packages passed preflight"

TARGET_DISK=""
count=0
while (( count < 120 )); do
  TARGET_DISK=$(select_target_disk || :)
  [ -n "$TARGET_DISK" ] && break
  count=$((count + 1))
  sleep 1
done

[ -n "$TARGET_DISK" ] || fail "no writable installation disk of at least 16 GiB was found"

echo "[log] selected $TARGET_DISK"

# Everything needed for the unattended install has passed validation. Only now
# create the guard and perform the destructive target erase.
: > "$STARTED" || fail "failed to create installation guard"

if ! /usr/sbin/diskutil eraseDisk APFS "Macintosh HD" GPT "$TARGET_DISK"; then
  fail "failed to erase $TARGET_DISK as APFS"
fi

count=0
while (( count < 60 )); do
  [ -d "$TARGET_VOLUME" ] && break
  count=$((count + 1))
  sleep 1
done

[ -d "$TARGET_VOLUME" ] || fail "target APFS volume did not mount"

ARGS=(
  --volume "$TARGET_VOLUME"
  --agreetolicense
  --nointeraction
  --installpackage "$ADMIN_PACKAGE"
  --installpackage "$SETUP_PACKAGE"
)

echo "[log] starting online macOS installation on $TARGET_VOLUME"
echo "[log] scheduling account and Setup Assistant packages"

"$STARTOSINSTALL" "${ARGS[@]}"
rc=$?

if (( rc != 0 )); then
  rm -f "$STARTED"
  echo "[log] ERROR: startosinstall exited with status $rc"
  printf '%s\n' "$USAGE"
  exit "$rc"
fi

echo "[log] startosinstall completed its prepare phase; waiting for reboot"

while :; do
  sleep 60
done
RECOVERY_SCRIPT

  cat > "$plist" <<'RECOVERY_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macos.install</string>
    <key>ProgramArguments</key>
    <array>
        <string>/macos-install.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
RECOVERY_PLIST

  chmod 0755 "$script"
  chmod 0644 "$plist"

  return 0
}

patchRecoveryBootstrap() {

  local image="$1"
  local result

  if ! result=$(python3 - "$image" <<'PY'
import plistlib
import struct
import sys
import zlib

UDRW = 0x00000001
UDZO = 0x80000005

ORIGINAL = b'''#
# launchd passes the "boot mode" to us, if one is set for this boot
#
# in certain boot modes, we tell diskarbitrationd not to automatically
# mount any other volumes. This has to happen here, before launchd
# starts all the daemons, so we can be sure it is set before diskarbitrationd
# starts up.
'''

BOOTSTRAP = b'''#
# Start unattended installation from the host state share.
#
(
  while ! /sbin/mount_9p installstate >/dev/null 2>&1; do sleep 1; done
  /Volumes/installstate/macos-install.sh
) &
'''


def be32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def be64(data, offset):
    return struct.unpack_from(">Q", data, offset)[0]


def main():
    path = sys.argv[1]

    if len(BOOTSTRAP) + 2 > len(ORIGINAL):
        raise RuntimeError("Recovery bootstrap is larger than the replaceable rc.cdrom.sh block")

    # Keep the HFS+ file and every DMG logical chunk exactly the same size.
    padding = len(ORIGINAL) - len(BOOTSTRAP)
    replacement = BOOTSTRAP + b"#" + (b" " * (padding - 2)) + b"\n"

    if len(replacement) != len(ORIGINAL):
        raise RuntimeError("Recovery bootstrap replacement length mismatch")

    with open(path, "r+b") as image:
        image.seek(0, 2)
        size = image.tell()

        if size < 512:
            raise RuntimeError("Recovery image is too small to be a DMG")

        image.seek(size - 512)
        koly = image.read(512)

        if koly[:4] != b"koly":
            raise RuntimeError("Recovery image has no UDIF koly trailer")

        data_fork_offset = be64(koly, 24)
        xml_offset = be64(koly, 216)
        xml_length = be64(koly, 224)

        image.seek(xml_offset)
        plist = plistlib.loads(image.read(xml_length))

        matches = []

        for blkx_index, blkx in enumerate(plist["resource-fork"]["blkx"]):
            mish = blkx["Data"]

            if mish[:4] != b"mish":
                continue

            first_sector = be64(mish, 8)
            mish_data_offset = be64(mish, 24)
            run_count = (len(mish) - 204) // 40

            for run_index in range(run_count):
                entry = 204 + run_index * 40
                run_type = be32(mish, entry)

                if run_type not in (UDRW, UDZO):
                    continue

                sector = first_sector + be64(mish, entry + 8)
                sectors = be64(mish, entry + 16)
                compressed_offset = be64(mish, entry + 24)
                compressed_length = be64(mish, entry + 32)
                physical_offset = data_fork_offset + mish_data_offset + compressed_offset

                image.seek(physical_offset)
                stored = image.read(compressed_length)

                if len(stored) != compressed_length:
                    raise RuntimeError("Short read while scanning Recovery DMG chunk")

                if run_type == UDRW:
                    decoded = stored
                else:
                    decoded = zlib.decompress(stored)

                expected = sectors * 512
                if len(decoded) != expected:
                    raise RuntimeError(
                        f"DMG chunk {blkx_index}/{run_index} expands to "
                        f"{len(decoded)} bytes, expected {expected}"
                    )

                count = decoded.count(ORIGINAL)
                if count:
                    matches.append((
                        blkx_index,
                        run_index,
                        run_type,
                        sector,
                        sectors,
                        physical_offset,
                        compressed_length,
                        decoded,
                        count,
                    ))

        total = sum(match[8] for match in matches)

        if total != 1 or len(matches) != 1:
            raise RuntimeError(
                f"Expected exactly one rc.cdrom.sh bootstrap block, found {total}"
            )

        (
            blkx_index,
            run_index,
            run_type,
            sector,
            sectors,
            physical_offset,
            compressed_length,
            decoded,
            _,
        ) = matches[0]

        patched = decoded.replace(ORIGINAL, replacement, 1)

        if len(patched) != len(decoded):
            raise RuntimeError("Patched DMG chunk changed logical size")

        if run_type == UDRW:
            stored = patched
            if len(stored) != compressed_length:
                raise RuntimeError("Patched raw DMG chunk changed physical size")
        else:
            compressed = zlib.compress(patched, 9)
            if len(compressed) > compressed_length:
                raise RuntimeError(
                    f"Patched DMG chunk grew from {compressed_length} to "
                    f"{len(compressed)} compressed bytes"
                )
            stored = compressed + (b"\0" * (compressed_length - len(compressed)))

        image.seek(physical_offset)
        image.write(stored)
        image.flush()

        # Verify the exact chunk bytes from the patched image rather than only
        # trusting the in-memory buffer that was written.
        image.seek(physical_offset)
        stored = image.read(compressed_length)

        if run_type == UDRW:
            verified = stored
        else:
            verified = zlib.decompress(stored)

        if len(verified) != sectors * 512:
            raise RuntimeError("Patched DMG chunk failed logical-size verification")

        if verified.count(ORIGINAL) != 0 or verified.count(replacement) != 1:
            raise RuntimeError("Patched rc.cdrom.sh bootstrap failed byte verification")

        kind = "raw" if run_type == UDRW else "zlib"
        print(
            f"Patched Recovery bootstrap in blkx {blkx_index}, run {run_index} "
            f"({kind}, sector {sector}, {compressed_length} stored bytes)."
        )


try:
    main()
except Exception as exc:
    print(f"Recovery bootstrap patch failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
  ); then
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
  local work script plist state qemu_info
  local msg="Preparing automated installation..."

  info "$msg" && html "$msg"

  work=$(mktemp -d "$STORAGE/tmp/recovery.XXXXXX") || return 1
  script="$work/macos-install.sh"
  plist="$work/com.macos.install.plist"
  state="$STORAGE/tmp/autoinstall"

  createAutomatedInstallationFiles "$script" "$plist"

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
     ! cp -f "$admin" "$state/admin.pkg" ||
     ! cp -f "$setup" "$state/skipsetup.pkg"; then
    rm -rf "$work"
    error "Failed to stage unattended installation files."
    return 1
  fi

  chmod 0755 "$state/macos-install.sh"
  chmod 0644 "$state/admin.pkg" "$state/skipsetup.pkg"

  if ! cmp -s "$script" "$state/macos-install.sh" ||
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

install() {

  local version="$1"
  local dest="$2"

  local file="$STORAGE/tmp/recovery.dmg"
  local payload="$STORAGE/tmp/setup-payload"
  local admin="$payload/admin.pkg"
  local setup="$payload/skipsetup.pkg"

  # Apple recovery catalogs are selected by board identifier, so each macOS
  # generation maps to a model known to receive that release.
  case "${version,,}" in
    "tahoe" | "26"* | "16"* )
      local board="Mac-CFF7D910A743CAAF" ;;
    "sequoia" | "15"* )
      local board="Mac-937A206F2EE63C01" ;;
    "sonoma" | "14"* )
      local board="Mac-827FAC58A8FDFA22" ;;
    "ventura" | "13"* )
      local board="Mac-4B682C642B45593E" ;;
    "monterey" | "12"* )
      local board="Mac-B809C3757DA9BB8D" ;;
    "bigsur" | "big-sur" | "11"* )
      local board="Mac-2BD1B31983FE1663" ;;
    "catalina" | "10"* )
      local board="Mac-00BE6ED71E35EB86" ;;
    *)
      error "Unknown VERSION specified, value \"${version}\" is not recognized!"
      return 1 ;;
  esac

  rm -f "$dest" "$dest.tmp"

  if ! makeDir "$STORAGE"; then
    error "Failed to create directory \"$STORAGE\" !"
    return 1
  fi

  if ! makeDir "$STORAGE/tmp"; then
    error "Failed to create directory \"$STORAGE/tmp\" !"
    return 1
  fi

  rm -rf "$payload"
  mkdir -p "$payload" || {
    error "Failed to create unattended setup payload directory."
    return 1
  }

  # New recovery media invalidates cached firmware state that may still point
  # at an older installer or incompatible boot entry.
  find "$STORAGE" -maxdepth 1 -type f \( -iname '*.rom' -or -iname '*.vars' \) -delete

  rm -f -- "$file" "$file.aria2"

  # Try a multi-connection recovery download first.
  if download "$file" "$board" "$version" "${CONNECTIONS:-1}"; then
    local rc=0
  else
    local rc=$?
  fi

  if (( rc != 0 )); then

    # Status 2 represents deterministic download validation failure, so a
    # second transport attempt cannot recover it.
    if (( rc == 2 )); then
      rm -f -- "$file" "$file.aria2"
      rm -rf "$payload"
      exit 60
    fi

    delay 5

    # Obtain a fresh Apple session and retry with single-connection Wget.
    if ! download "$file" "$board" "$version" "1"; then
      rm -f -- "$file" "$file.aria2"
      rm -rf "$payload"
      exit 60
    fi

  fi

  # Build and validate the actual account and Setup Assistant packages
  if ! createAdminPackage "$admin" || ! createSkipSetupPackage "$setup"; then
    rm -rf "$payload"
    return 1
  fi

  if ! prepareAutomatedRecovery "$file" "$dest" "$admin" "$setup"; then
    rm -f -- "$file" "$file.aria2"
    rm -rf "$payload"
    return 1
  fi

  rm -f -- "$file" "$file.aria2"
  rm -rf "$payload"
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
  BASE_IMG="$STORAGE/setup.dmg"
fi

# Recovery media is required only while the primary disk is absent or blank.
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

INSTALL_STATE_DIR="$STORAGE/tmp/autoinstall"

if ! makeDir "$INSTALL_STATE_DIR"; then
  error "Failed to create unattended installation state directory."
  exit 34
fi

# A blank primary disk represents a new installation attempt. Keep prior logs,
# but clear the destructive-operation guard for the new target.
if ! hasData; then
  rm -f "$INSTALL_STATE_DIR/started"
fi

DISK_OPTS=""

# OpenCore uses PCI 0x5. The generic disk layer attaches setup.dmg at 0x6,
# while the state/log share is pinned at 0x7 and managed disks use 0xA-0xF.
if [ -s "$BASE_IMG" ]; then
  DISK_OPTS="-fsdev local,id=installstatefs,path=$INSTALL_STATE_DIR,security_model=none"
  DISK_OPTS+=" -device virtio-9p-pci,id=installstate9p,fsdev=installstatefs,mount_tag=installstate,bus=pcie.0,addr=0x7"
fi

return 0
