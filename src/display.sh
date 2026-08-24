#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU acceleration
: "${VGA:="vmware"}"    # VGA adaptor
: "${DISPLAY:="web"}"   # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${VNC_PORT:="5900"}" # VNC port

# Sanitize variables
VGA=$(strip "$VGA")
LOSSY=$(strip "$LOSSY")
DISPLAY=$(strip "$DISPLAY")
VNC_PORT=$(strip "$VNC_PORT")
WSS_SOCKET="${WSS_SOCKET:-$QEMU_DIR/vnc-ws.sock}"

port=$(( VNC_PORT - 5900 ))

# Preserve the historic :0 setting as an alias for the managed web display.
[[ "$DISPLAY" == ":0" ]] && DISPLAY="web"

LOSSY_OPT=""
enabled "$LOSSY" && LOSSY_OPT=",lossy=on"

configureSoftwareDisplay() {

  VGA_OPT="-vga ${VGA}"
  if [[ "${VGA,,}" == "std,"* ]]; then
    VGA_OPT="-device VGA,${VGA#*,}"
  fi

  case "${DISPLAY,,}" in

    "vnc" )
      DISPLAY_OPTS="-display vnc=:${port}${LOSSY_OPT} ${VGA_OPT}" ;;
    "web" )
      DISPLAY_OPTS="-display vnc=:${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT} ${VGA_OPT}" ;;
    "disabled" )
      DISPLAY_OPTS="-display none ${VGA_OPT}" ;;
    "none" )
      DISPLAY_OPTS="-display none -vga none" ;;
    * )
      DISPLAY_OPTS="-display ${DISPLAY} ${VGA_OPT}" ;;

  esac

  return 0
}

configureSoftwareDisplay
enabled "$GPU" || return 0

msg="Configuring Reims vGPU..."
enabled "$DEBUG" && echo "$msg"

if [ ! -d /dev/dri ]; then
  warn "GPU acceleration was requested, but '/dev/dri' was not added to the devices section of your compose file; falling back to software rendering."
  return 0
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
  warn "GPU acceleration was requested, but no accessible DRM render node was found in '/dev/dri'; falling back to software rendering."
  return 0
fi

if ! compgen -G '/usr/lib/*/libvulkan.so.1' >/dev/null 2>&1 \
    && [ ! -e /usr/lib/libvulkan.so.1 ] \
    && [ ! -e /usr/lib64/libvulkan.so.1 ]; then
  warn "GPU acceleration was requested, but the Vulkan loader is not available in the container; falling back to software rendering."
  return 0
fi

if ! compgen -G '/etc/vulkan/icd.d/*.json' >/dev/null 2>&1 \
    && ! compgen -G '/usr/share/vulkan/icd.d/*.json' >/dev/null 2>&1; then
  warn "GPU acceleration was requested, but no Vulkan ICD is available in the container; falling back to software rendering."
  return 0
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
info "Hardware rendering enabled:"
info
info "Device:     Reims vGPU"
info "Backend:    Vulkan"
info "RAM:        shared memfd"

return 0
