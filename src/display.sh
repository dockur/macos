#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU acceleration
: "${VGA:="vmware"}"    # VGA adaptor
: "${DISPLAY:="web"}"   # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${VNC_PORT:="5900"}" # VNC port
: "${RENDERNODE:=""}"   # Render node

# Sanitize variables
VGA=$(strip "$VGA")
LOSSY=$(strip "$LOSSY")
DISPLAY=$(strip "$DISPLAY")
VNC_PORT=$(strip "$VNC_PORT")
RENDERNODE=$(strip "$RENDERNODE")
WSS_SOCKET="${WSS_SOCKET:-$QEMU_DIR/vnc-ws.sock}"

port=$(( VNC_PORT - 5900 ))

# Preserve the historic :0 setting as an alias for the managed web display.
[[ "$DISPLAY" == ":0" ]] && DISPLAY="web"

LOSSY_OPT=""
enabled "$LOSSY" && LOSSY_OPT=",lossy=on"

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
  *)
    DISPLAY_OPTS="-display ${DISPLAY} ${VGA_OPT}" ;;

esac

enabled "$GPU" || return 0

msg="Configuring display drivers..."
enabled "$DEBUG" && echo "$msg"

if [[ "$ARCH" != "amd64" ]]; then
  warn "GPU acceleration is only supported for the AMD64 platform, ignoring GPU=Y."
  return 0
fi

# Return the PCI vendor for a usable DRM render node. Any malformed, missing,
# inaccessible or disappearing node is rejected without aborting display setup.

gpuNodeVendor() {

  local node="$1"

  local render_name="${node##*/}"
  [[ "$render_name" =~ ^renderD[0-9]{3}$ ]] || return 1

  local render_number="${render_name#renderD}"
  (( 10#$render_number >= 128 )) || return 1
  [ -c "$node" ] || return 1

  local gpu_fd
  if ! { exec {gpu_fd}<>"$node"; } 2>/dev/null; then
    return 1
  fi

  { exec {gpu_fd}>&-; } 2>/dev/null || true

  local vendor_file="/sys/class/drm/${render_name}/device/vendor"
  [ -r "$vendor_file" ] || return 1

  if ! IFS= read -r GPU_VENDOR < "$vendor_file"; then
    return 1
  fi

  GPU_VENDOR="${GPU_VENDOR,,}"
  return 0
}

# Venus requires a Vulkan userspace driver in addition to the normal EGL/GBM
# rendering path. Keep this separate so normal VirGL/OpenGL does not require Vulkan.

venusEnabled() {

  [[ ",${VGA,,}," =~ ,venus=(on|true|yes|1), ]]
}

disableVenus() {

  VGA="$(sed -E 's/,venus=(on|true|yes|1)(,|$)/\2/I' <<< "$VGA")"
}

drmNativeEnabled() {

  [[ ",${VGA,,}," =~ ,drm_native_context=(on|true|yes|1), ]]
}

disableDrmNative() {

  VGA="$(sed -E 's/,drm_native_context=(on|true|yes|1)(,|$)/\2/I' <<< "$VGA")"
}

vulkanLibraryAvailable() {

  local library="$1"

  compgen -G "/usr/lib/*/${library}" >/dev/null 2>&1 \
    || [ -e "/usr/lib/${library}" ] \
    || [ -e "/usr/lib64/${library}" ]
}

vulkanManifestAvailable() {

  local manifest="$1"

  compgen -G "/etc/vulkan/icd.d/${manifest}*.json" >/dev/null 2>&1 \
    || compgen -G "/usr/share/vulkan/icd.d/${manifest}*.json" >/dev/null 2>&1
}

mesaVulkanReady() {

  local vendor="$1"
  local library manifest
  VULKAN_REASON=""

  if ! vulkanLibraryAvailable "libvulkan.so.1"; then
    VULKAN_REASON="the Vulkan loader is not available in the container"
    return 1
  fi

  case "$vendor" in
    "0x8086" )
      for library in libvulkan_intel.so libvulkan_intel_hasvk.so; do
        if ! vulkanLibraryAvailable "$library"; then
          VULKAN_REASON="the Intel Vulkan driver library '$library' is not available in the container"
          return 1
        fi
      done

      for manifest in intel_icd intel_hasvk_icd; do
        if ! vulkanManifestAvailable "$manifest"; then
          VULKAN_REASON="the Intel Vulkan ICD '$manifest' is not available in the container"
          return 1
        fi
      done ;;

    "0x1002" )
      if ! vulkanLibraryAvailable "libvulkan_radeon.so"; then
        VULKAN_REASON="the AMD Vulkan driver library 'libvulkan_radeon.so' is not available in the container"
        return 1
      fi

      if ! vulkanManifestAvailable "radeon_icd"; then
        VULKAN_REASON="the AMD Vulkan ICD 'radeon_icd' is not available in the container"
        return 1
      fi ;;
  esac

  return 0
}

# NVIDIA uses the proprietary host driver injected by NVIDIA Container Toolkit
# rather than a Mesa Gallium driver from qemu-minimal. Require the complete EGL
# and GBM path before selecting an NVIDIA render node. Venus additionally needs
# the Vulkan loader, NVIDIA ICD and NVIDIA Vulkan userspace libraries.

nvidiaDriverVersion() {

  local data=""
  NVIDIA_DRIVER_VERSION=""

  if [ -r /proc/driver/nvidia/version ]; then
    data="$(head -n 1 /proc/driver/nvidia/version 2>/dev/null || true)"
  elif [ -r /sys/module/nvidia/version ]; then
    data="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
  fi

  if [[ "$data" =~ ([0-9]{3,})\.([0-9]+)(\.[0-9]+)? ]]; then
    NVIDIA_DRIVER_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}${BASH_REMATCH[3]:-}"
    return 0
  fi

  return 1
}

nvidiaVulkanReady() {

  local icd=""
  local major minor

  if ! nvidiaDriverVersion; then
    NVIDIA_REASON="the NVIDIA driver version cannot be determined"
    return 1
  fi

  [[ "$NVIDIA_DRIVER_VERSION" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"

  if (( major < 570 || (major == 570 && minor < 86) )); then
    NVIDIA_REASON="NVIDIA driver $NVIDIA_DRIVER_VERSION is older than the 570.86 minimum required by Venus"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libvulkan.so.1' >/dev/null 2>&1 \
      && [ ! -e /usr/lib/libvulkan.so.1 ] \
      && [ ! -e /usr/lib64/libvulkan.so.1 ]; then
    NVIDIA_REASON="the Vulkan loader is not available in the container"
    return 1
  fi

  for icd in /etc/vulkan/icd.d/nvidia_icd*.json /usr/share/vulkan/icd.d/nvidia_icd*.json; do
    [ -r "$icd" ] && break
    icd=""
  done

  if [ -z "$icd" ]; then
    NVIDIA_REASON="the NVIDIA Vulkan ICD is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/*/nvidia/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/nvidia/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/nvidia/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libGLX_nvidia.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA Vulkan driver library is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/*/nvidia/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/nvidia/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/nvidia/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libnvidia-glvkspirv.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA Vulkan SPIR-V compiler library is not available in the container"
    return 1
  fi

  return 0
}

nvidiaGpuReady() {

  local modeset=""
  NVIDIA_REASON=""

  if ! compgen -G '/usr/lib/*/libEGL_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libEGL_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libEGL_nvidia.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA EGL driver is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libnvidia-egl-gbm.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libnvidia-egl-gbm.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libnvidia-egl-gbm.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA EGL GBM platform library is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/gbm/nvidia-drm_gbm.so' >/dev/null 2>&1 \
      && [ ! -e /usr/lib/gbm/nvidia-drm_gbm.so ] \
      && [ ! -e /usr/lib64/gbm/nvidia-drm_gbm.so ]; then
    NVIDIA_REASON="the NVIDIA GBM backend is not available in the container"
    return 1
  fi

  if [ ! -r /usr/share/glvnd/egl_vendor.d/10_nvidia.json ] \
      || [ ! -r /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json ]; then
    NVIDIA_REASON="the NVIDIA EGL vendor configuration is not available in the container"
    return 1
  fi

  if [ ! -r /sys/module/nvidia_drm/parameters/modeset ] \
      || ! IFS= read -r modeset < /sys/module/nvidia_drm/parameters/modeset; then
    NVIDIA_REASON="the nvidia-drm KMS state cannot be determined"
    return 1
  fi

  case "${modeset,,}" in
    "y" | "1" ) ;;
    * )
      NVIDIA_REASON="nvidia-drm modesetting is disabled"
      return 1 ;;
  esac

  return 0
}

modernVirtioGpuGuest() {

  case "${APP,,}" in
    "macos" ) return 1 ;;
  esac

  return 0
}

drmNativeGpuGuest() {

  case "${APP,,}" in
    "qemu" ) return 0 ;;
  esac

  return 1
}

hostBlobsSupported() {

  kernelAtLeast 6 13
}

# qemu-render builds the AMDGPU and i915 native-context backends. Host support
# can be validated here; arbitrary guest kernel/Mesa support is negotiated later.
drmNativeReady() {

  DRM_REASON=""

  if [[ "${APP,,}" == "windows" ]]; then
    DRM_REASON="DRM native contexts require a Linux guest"
    return 1
  fi

  if ! hostBlobsSupported; then
    DRM_REASON="Linux 6.13 or newer is required for DRM native contexts"
    return 1
  fi

  if ! [[ ",${VGA,,}," =~ ,blob=(on|true|yes|1), ]]; then
    DRM_REASON="virtio-gpu host blobs are not enabled"
    return 1
  fi

  case "$GPU_VENDOR" in
    "0x1002" )
      if [[ "$GPU_DRIVER" != "amdgpu" ]]; then
        DRM_REASON="the AMD GPU is using '$GPU_DRIVER' instead of the amdgpu DRM driver"
        return 1
      fi ;;
    "0x8086" )
      if [[ "$GPU_DRIVER" != "i915" ]]; then
        DRM_REASON="the Intel GPU is using '$GPU_DRIVER' instead of the i915 DRM driver"
        return 1
      fi ;;
    * )
      DRM_REASON="no native DRM renderer is available for this GPU"
      return 1 ;;
  esac

  return 0
}

venusGuestPatRequired() {

  local cpu_vendor driver device=""

  # TCG does not use the Intel KVM guest-PAT quirk.
  disabled "${KVM:-}" && return 1

  isIntelCpu || return 1

  case "$GPU_VENDOR" in
    "0x1002" | "0x10de" )
      # RADV/NVIDIA dGPU on an Intel CPU.
      return 0 ;;
    "0x8086" )
      driver=$(readlink -f "/sys/class/drm/${RENDER_NAME}/device/driver" 2>/dev/null || true)
      driver="${driver##*/}"
      [[ "$driver" == "xe" ]] && return 0

      if [ -r "/sys/class/drm/${RENDER_NAME}/device/device" ]; then
        IFS= read -r device < "/sys/class/drm/${RENDER_NAME}/device/device" || device=""
        device="${device,,}"
      fi

      # Meteor Lake requires guest PAT even when it is still using i915.
      case "$device" in
        "0x7d40" | "0x7d45" | "0x7d55" | "0x7d60" | "0x7dd5" ) return 0 ;;
      esac ;;
  esac

  return 1
}

venusGuestPatReady() {

  VULKAN_PAT_REASON=""
  venusGuestPatRequired || return 0

  if ! hasFlag "ss"; then
    VULKAN_PAT_REASON="the Intel CPU cannot safely honor guest PAT because self-snoop is unavailable"
    return 1
  fi

  if ! kernelAtLeast 6 16; then
    VULKAN_PAT_REASON="Linux 6.16 or newer is required for guest PAT support on this Intel CPU/GPU combination"
    return 1
  fi

  VIRTGPU_GUEST_PAT="Y"
  return 0
}

GPU_VENDOR=""
NVIDIA_NODE=""
NVIDIA_REASON=""
VULKAN_REASON=""
VULKAN_PAT_REASON=""
DRM_REASON=""
OPENGL_46_REASON=""
VULKAN_STATE_REASON=""
DRM_STATE_REASON=""
VIRTGPU_GUEST_PAT=""
fail="falling back to software rendering."

if [ -n "$RENDERNODE" ]; then

  if ! gpuNodeVendor "$RENDERNODE"; then
    warn "GPU render node '$RENDERNODE' is unavailable or inaccessible; $fail"
    return 0
  fi

  case "$GPU_VENDOR" in
    "0x8086" | "0x1002" ) ;;
    "0x10de" )
      if ! nvidiaGpuReady; then
        warn "NVIDIA GPU at $RENDERNODE cannot be used for hardware rendering because $NVIDIA_REASON; $fail"
        return 0
      fi ;;
    * )
      warn "unsupported GPU at $RENDERNODE; $fail"
      return 0 ;;
  esac

else

  if [ ! -d /dev/dri ]; then
    warn "GPU acceleration was requested, but '/dev/dri' was not added to the devices section of your compose file; $fail"
    return 0
  fi

  RENDER_NODE_FOUND="N"

  for node in /dev/dri/renderD*; do

    [ -e "$node" ] || continue
    RENDER_NODE_FOUND="Y"

    if ! gpuNodeVendor "$node"; then
      continue
    fi

    case "$GPU_VENDOR" in
      "0x8086" | "0x1002" )
        RENDERNODE="$node"
        break ;;
      "0x10de" )
        NVIDIA_NODE="$node"
        if nvidiaGpuReady; then
          RENDERNODE="$node"
          break
        fi ;;
    esac

  done

  if [ -z "$RENDERNODE" ]; then

    if [ -n "$NVIDIA_NODE" ] && [ -n "$NVIDIA_REASON" ]; then
      warn "NVIDIA GPU at $NVIDIA_NODE cannot be used for hardware rendering because $NVIDIA_REASON; $fail"
    elif [[ "$RENDER_NODE_FOUND" != "Y" ]]; then
      warn "/dev/dri is available, but no GPU render nodes were found; $fail"
    else
      warn "no usable GPU render node found; $fail"
    fi

    return 0
  fi

fi

# Re-read the selected node after auto-detection so the vendor name and device
# number below are based on the final render node and survive hotplug races.
if ! gpuNodeVendor "$RENDERNODE"; then
  warn "GPU render node '$RENDERNODE' became unavailable; $fail"
  return 0
fi

RENDER_NAME="${RENDERNODE##*/}"
CARD_NUMBER="${RENDER_NAME#renderD}"
GPU_DEVICE=""
GPU_DRIVER=""

if [ -r "/sys/class/drm/${RENDER_NAME}/device/device" ]; then
  IFS= read -r GPU_DEVICE < "/sys/class/drm/${RENDER_NAME}/device/device" || GPU_DEVICE=""
  GPU_DEVICE="${GPU_DEVICE,,}"
fi

GPU_DRIVER=$(readlink -f "/sys/class/drm/${RENDER_NAME}/device/driver" 2>/dev/null || true)
GPU_DRIVER="${GPU_DRIVER##*/}"
GPU_DEVICE_NAME=""
GPU_PCI_SLOT=$(readlink -f "/sys/class/drm/${RENDER_NAME}/device" 2>/dev/null || true)
GPU_PCI_SLOT="${GPU_PCI_SLOT##*/}"

if [[ "$GPU_PCI_SLOT" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
  GPU_DEVICE_NAME=$(lspci -D -s "$GPU_PCI_SLOT" -vmm 2>/dev/null \
    | sed -n 's/^Device:[[:space:]]*//p' | head -n 1 || true)
fi

case "$GPU_VENDOR" in
  "0x8086" ) GPU_NAME="Intel" ;;
  "0x1002" ) GPU_NAME="AMD" ;;
  "0x10de" ) GPU_NAME="NVIDIA" ;;
  * ) GPU_NAME="GPU" ;;
esac

if [ ! -d /dev/dri ]; then
  mkdir -m 755 /dev/dri 2>/dev/null || true
fi

# Derive the matching DRM card from the validated render node number.
CARD_DEVICE="/dev/dri/card$((10#$CARD_NUMBER - 128))"

# Containers normally have no udev, so reconstruct the matching DRM card and
# render character devices from the render-node minor number when necessary.
if [ ! -c "$CARD_DEVICE" ]; then
  if mknod "$CARD_DEVICE" c 226 $((10#$CARD_NUMBER - 128)) 2>/dev/null; then
    chmod 666 "$CARD_DEVICE" 2>/dev/null || true
  fi
fi

if [ ! -c "$RENDERNODE" ]; then
  if mknod "$RENDERNODE" c 226 "$((10#$CARD_NUMBER))" 2>/dev/null; then
    chmod 666 "$RENDERNODE" 2>/dev/null || true
  fi
fi

if ! gpuNodeVendor "$RENDERNODE"; then
  warn "GPU render node '$RENDERNODE' became unavailable; $fail"
  return 0
fi

if venusEnabled; then

  case "$GPU_VENDOR" in
    "0x8086" | "0x1002" )
      if ! mesaVulkanReady "$GPU_VENDOR"; then
        VULKAN_STATE_REASON="$VULKAN_REASON"
        disableVenus
      fi ;;
    "0x10de" )
      if ! nvidiaVulkanReady; then
        VULKAN_STATE_REASON="$NVIDIA_REASON"
        disableVenus
      fi ;;
  esac

  if venusEnabled && ! venusGuestPatReady; then
    VULKAN_STATE_REASON="$VULKAN_PAT_REASON"
    disableVenus
  fi

fi

case "${VGA,,}" in

  "virtio" )

    if ! modernVirtioGpuGuest; then
      VGA="virtio-vga-gl"
    elif hostBlobsSupported; then
      VGA="virtio-vga-gl,hostmem=8G,blob=true"

      if drmNativeGpuGuest; then
        VGA+=",drm_native_context=on"
      fi

      case "$GPU_VENDOR" in
        "0x8086" | "0x1002" )
          if ! mesaVulkanReady "$GPU_VENDOR"; then
            VULKAN_STATE_REASON="$VULKAN_REASON"
          elif ! venusGuestPatReady; then
            VULKAN_STATE_REASON="$VULKAN_PAT_REASON"
          else
            VGA+=",venus=true"
          fi ;;
        "0x10de" )
          if ! nvidiaVulkanReady; then
            VULKAN_STATE_REASON="$NVIDIA_REASON"
          elif ! venusGuestPatReady; then
            VULKAN_STATE_REASON="$VULKAN_PAT_REASON"
          else
            VGA+=",venus=true"
          fi ;;
      esac

    else

      OPENGL_46_REASON="requires virtio-gpu host blobs (Linux 6.13+ host kernel)"
      VULKAN_STATE_REASON="requires virtio-gpu host blobs (Linux 6.13+ host kernel)"
      if drmNativeGpuGuest; then
        DRM_STATE_REASON="requires virtio-gpu host blobs (Linux 6.13+ host kernel)"
      fi
      VGA="virtio-vga-gl"

    fi ;;

  "std,"* ) VGA="VGA,${VGA#*,}" ;;

esac

if drmNativeEnabled && ! drmNativeReady; then
  DRM_STATE_REASON="$DRM_REASON"
  disableDrmNative
fi

OPENGL_46="   "
[[ ",${VGA,,}," =~ ,blob=(on|true|yes|1), ]] && OPENGL_46=" ✓ "

VULKAN_STATE="   "
venusEnabled && VULKAN_STATE=" ✓ "

DRM_STATE="   "
drmNativeEnabled && DRM_STATE=" ✓ "

echo
info "Hardware rendering enabled:"
info

info "Device:     $GPU_NAME${GPU_DEVICE_NAME:+ $GPU_DEVICE_NAME}"

if [ -n "$GPU_DEVICE" ]; then
  info "PCI ID:     ${GPU_VENDOR#0x}:${GPU_DEVICE#0x}"
fi

info "Driver:     ${GPU_DRIVER:-unknown}"

if [[ "$GPU_VENDOR" == "0x10de" ]]; then
  nvidiaDriverVersion || NVIDIA_DRIVER_VERSION="unknown"
  info "Version:    $NVIDIA_DRIVER_VERSION"
else
  MESA_VERSION="$(dpkg-query -W -f='${Provides}\n' qemu-render 2>/dev/null \
    | sed -n 's/.*libgbm1 (= \([^)]*\)).*/\1/p' || true)"

  [ -n "$MESA_VERSION" ] && info "Mesa:       $MESA_VERSION"
fi

info "Render:     $RENDERNODE"
info

if modernVirtioGpuGuest; then
  info "Vulkan:     [$VULKAN_STATE]${VULKAN_STATE_REASON:+ $VULKAN_STATE_REASON}"
  if drmNativeGpuGuest; then
    info "DRM Native: [$DRM_STATE]${DRM_STATE_REASON:+ $DRM_STATE_REASON}"
  fi
  info "OpenGL 4.3: [ ✓ ]"
  info "OpenGL 4.6: [$OPENGL_46]${OPENGL_46_REASON:+ $OPENGL_46_REASON}"
fi
echo

DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -device $VGA"

[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :${port}${LOSSY_OPT}"
[[ "${DISPLAY,,}" == "web" ]] && DISPLAY_OPTS+=" -vnc :${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT}"

return 0
