#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU acceleration
: "${VGA:="vmware"}"    # VGA adapter
: "${DISPLAY:="web"}"   # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${VNC_PORT:="5900"}" # VNC port

# Sanitize variables
VGA=$(strip "$VGA")
LOSSY=$(strip "$LOSSY")
DISPLAY=$(strip "$DISPLAY")
VNC_PORT=$(strip "$VNC_PORT")
WSS_SOCKET="${WSS_SOCKET:-$QEMU_DIR/vnc-ws.sock}"

VGA_DEVICE="${VGA%%,*}"
VGA_OPTIONS="${VGA#"$VGA_DEVICE"}"

case "${VGA_DEVICE,,}" in
  "std" | "vga" )
    VGA_DEVICE="VGA"
    VGA_ARG="-device" ;;
  "vmware" | "vmware-svga" )
    VGA_DEVICE="vmware-svga"
    VGA_ARG="-device" ;;
  "virtio" )
    VGA_DEVICE="virtio-vga"
    VGA_ARG="-device" ;;
  "virtio-"* )
    VGA_DEVICE="${VGA_DEVICE,,}"
    VGA_ARG="-device" ;;
  * )
    VGA_ARG="-vga" ;;
esac

VGA="${VGA_DEVICE}${VGA_OPTIONS}"
VGA_ARG+=" ${VGA}"

# QEMU accepts a VNC display number rather than a TCP port,
# so translate the configured port back to its :N display index.
port=$(( VNC_PORT - 5900 ))

LOSSY_OPT=""
enabled "$LOSSY" && LOSSY_OPT=",lossy=on"

# Preserve the historic :0 setting as an alias for the managed web display.
[[ "$DISPLAY" == ":0" ]] && DISPLAY="web"

case "${DISPLAY,,}" in

  "vnc" )
    DISPLAY_OPTS="-display vnc=:${port}${LOSSY_OPT} ${VGA_ARG}" ;;
  "web" )
    DISPLAY_OPTS="-display vnc=:${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT} ${VGA_ARG}" ;;
  "disabled" )
    DISPLAY_OPTS="-display none ${VGA_ARG}" ;;
  "none" )
    DISPLAY_OPTS="-display none -vga none" ;;
  *)
    DISPLAY_OPTS="-display ${DISPLAY} ${VGA_ARG}" ;;

esac

enabled "$GPU" || return 0

msg="Configuring Reims vGPU..."
enabled "$DEBUG" && echo "$msg"

if [ ! -d /dev/dri ]; then
  error "GPU acceleration was requested, but '/dev/dri' was not added to the devices section of your compose file."
  exit 72
fi

RENDER_NODE=""
for node in /dev/dri/renderD*; do

  [ -c "$node" ] || continue

  gpu_fd=""
  if ! { exec {gpu_fd}<>"$node"; } 2>/dev/null; then
    continue
  fi

  { exec {gpu_fd}>&-; } 2>/dev/null || true
  RENDER_NODE="$node"
  break
done

if [ -z "$RENDER_NODE" ]; then
  error "GPU acceleration was requested, but no accessible DRM render node was found in '/dev/dri'."
  exit 72
fi

if ! command -v vulkaninfo >/dev/null 2>&1; then
  error "GPU acceleration was requested, but 'vulkaninfo' is not available in the container."
  exit 72
fi

VULKAN_SUMMARY=""
if ! VULKAN_SUMMARY="$(vulkaninfo --summary 2>&1)"; then
  enabled "$DEBUG" && printf '%s\n' "$VULKAN_SUMMARY"
  error "GPU acceleration was requested, but Vulkan device enumeration failed."
  exit 72
fi

# Reims requires Vulkan 1.2 and rejects devices below that API floor. Mirror its
# device policy here: CPU/software Vulkan does not count as hardware rendering,
# while discrete, integrated, virtual and other non-CPU devices are eligible.
if ! awk '
  function check_device() {
    if (!in_device || type == "" || major < 0 || minor < 0) {
      return
    }

    if (type != "PHYSICAL_DEVICE_TYPE_CPU" &&
        (major > 1 || (major == 1 && minor >= 2))) {
      compatible = 1
    }
  }

  /^GPU[0-9]+:/ {
    check_device()
    in_device = 1
    major = -1
    minor = -1
    type = ""
    next
  }

  in_device && /^[[:space:]]*apiVersion[[:space:]]*=/ {
    value = $0
    sub(/^.*=[[:space:]]*/, "", value)
    split(value, version, ".")
    major = version[1] + 0
    minor = version[2] + 0
    next
  }

  in_device && /^[[:space:]]*deviceType[[:space:]]*=/ {
    type = $0
    sub(/^.*=[[:space:]]*/, "", type)
    sub(/[[:space:]].*$/, "", type)
    next
  }

  END {
    check_device()
    exit compatible ? 0 : 1
  }
' <<< "$VULKAN_SUMMARY"; then
  enabled "$DEBUG" && printf '%s\n' "$VULKAN_SUMMARY"
  error "GPU acceleration was requested, but no Vulkan 1.2+ device is available."
  exit 72
fi

# Vulkan 1.2 promotes 8-bit storage and viewport-index output into core feature
# structures, but support for both remains optional. Reims enables and relies on
# these capabilities when translating the guest Metal command stream, so verify
# them on the same Vulkan 1.2+ non-CPU device accepted above.
VULKAN_DETAILS=""
if ! VULKAN_DETAILS="$(env -u DISPLAY -u WAYLAND_DISPLAY vulkaninfo 2>&1)"; then
  enabled "$DEBUG" && printf '%s\n' "$VULKAN_DETAILS"
  error "GPU acceleration was requested, but Vulkan capability enumeration failed."
  exit 72
fi

if ! awk '
  function check_device() {
    if (!in_device || type == "" || major < 0 || minor < 0) {
      return
    }

    if (type != "PHYSICAL_DEVICE_TYPE_CPU" &&
        (major > 1 || (major == 1 && minor >= 2)) &&
        storage8 == "true" && viewport_index == "true") {
      compatible = 1
    }
  }

  /^GPU[0-9]+:/ {
    check_device()
    in_device = 1
    major = -1
    minor = -1
    type = ""
    storage8 = ""
    viewport_index = ""
    next
  }

  in_device && /^[[:space:]]*apiVersion[[:space:]]*=/ {
    value = $0
    sub(/^.*=[[:space:]]*/, "", value)
    split(value, version, ".")
    major = version[1] + 0
    minor = version[2] + 0
    next
  }

  in_device && /^[[:space:]]*deviceType[[:space:]]*=/ {
    type = $0
    sub(/^.*=[[:space:]]*/, "", type)
    sub(/[[:space:]].*$/, "", type)
    next
  }

  in_device && /^[[:space:]]*storageBuffer8BitAccess[[:space:]]*=/ {
    storage8 = $0
    sub(/^.*=[[:space:]]*/, "", storage8)
    sub(/[[:space:]].*$/, "", storage8)
    next
  }

  in_device && /^[[:space:]]*shaderOutputViewportIndex[[:space:]]*=/ {
    viewport_index = $0
    sub(/^.*=[[:space:]]*/, "", viewport_index)
    sub(/[[:space:]].*$/, "", viewport_index)
    next
  }

  END {
    check_device()
    exit compatible ? 0 : 1
  }
' <<< "$VULKAN_DETAILS"; then
  enabled "$DEBUG" && printf '%s\n' "$VULKAN_DETAILS"
  error "GPU acceleration was requested, but no Vulkan 1.2+ device provides Reims' required storageBuffer8BitAccess and shaderOutputViewportIndex features."
  exit 72
fi

REIMS_ROM="/usr/share/qemu/reims-vgpu-gop.rom"
if [ ! -s "$REIMS_ROM" ]; then
  error "Reims GOP ROM is missing at '$REIMS_ROM'."
  exit 72
fi

# Reims maps guest RAM into its Vulkan backend, so the memory must be backed by
# a shared memfd. config.sh is sourced later and turns this into the matching
# memory-backend-memfd object plus machine memory-backend property.
RAM_BACKEND="memfd"

# The upstream x86 product path keeps Reims behind a secondary conventional PCI
# bridge. The GOP ROM belongs to this same device; it is not a second display.
REIMS_OPTS="-vga none"
REIMS_OPTS+=" -device pci-bridge,chassis_nr=5,id=pci.5,bus=pcie.0,addr=1e.0"
REIMS_OPTS+=" -device reims-vgpu-pci,id=reimsvgpu,romfile=${REIMS_ROM},rombar=1,bus=pci.5,addr=01.0"

case "${DISPLAY,,}" in

  "vnc" )
    DISPLAY_OPTS="-display none ${REIMS_OPTS} -vnc :${port}${LOSSY_OPT}" ;;
  "web" )
    DISPLAY_OPTS="-display none ${REIMS_OPTS} -vnc :${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT}" ;;
  "disabled" | "none" )
    DISPLAY_OPTS="-display none ${REIMS_OPTS}" ;;
  * )
    DISPLAY_OPTS="-display ${DISPLAY} ${REIMS_OPTS}" ;;

esac

echo
info "Hardware rendering enabled succesfully. Beware that this feature is still experimental!"

enabled "$DEBUG" && echo && printf '%s\n' "$VULKAN_DETAILS"

return 0
