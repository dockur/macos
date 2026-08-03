#!/usr/bin/env bash
set -Eeuo pipefail

# Present the Intel vendor and CPUID behavior expected by macOS while hiding
# nested VMX and one-gigabyte pages that are problematic for this guest.
DEFAULT_FLAGS="vendor=GenuineIntel,vmx=off,vmware-cpuid-freq=on,-pdpe1gb"

needsAmdCpuProfile() {

  # AMD hosts and software emulation both require an explicit Intel-compatible
  # CPU profile instead of passing through the host model.
  isAmdCpu || disabled "${KVM:-}"

}

checkCpuFeatures() {

  if ! hasFlag "avx2"; then
    warn "This processor does not support AVX2. macOS versions newer than 13 require an Intel Haswell, AMD Zen, or newer processor."
  fi

  return 0
}

selectAmdCpuModel() {

  if [ -n "${CPU_MODEL:-}" ]; then
    return 0
  fi

  # Older macOS releases use the conservative Haswell profile; newer releases
  # receive Skylake plus a mitigation flag only when the host can provide it.
  case "${VERSION,,}" in
    "10"* | "11"* | "12"* | "13"* | \
    "catalina" | "bigsur" | "big-sur" | "monterey" | "ventura" )
      CPU_MODEL="Haswell-noTSX"
      ;;
    *)
      CPU_MODEL="Skylake-Client-v4"
      if hasFlag "spec-ctrl" && ! disabled "${KVM:-}"; then
        DEFAULT_FLAGS+=",+spec-ctrl"
      else
        DEFAULT_FLAGS+=",-spec-ctrl"
      fi
      ;;
  esac

  return 0
}

appendAmdCpuFlags() {

  local flag

  # TCG cannot expose several timing and XSAVE features reliably. Under KVM,
  # mirror each optional feature from the actual host instead.
  if disabled "${KVM:-}"; then

    DEFAULT_FLAGS+=",-pcid,-invpcid,-tsc-deadline,-xsavec,-xsaves"

  else

    for flag in pcid invpcid tsc-deadline xsavec xsaves; do
      if hasFlag "$flag"; then
        DEFAULT_FLAGS+=",+$flag"
      else
        DEFAULT_FLAGS+=",-$flag"
      fi
    done

  fi

  # Advertise the instruction set expected by the selected macOS CPU profile;
  # QEMU's check option rejects combinations the accelerator cannot support.
  DEFAULT_FLAGS+=",+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+smep,+xsave,+xsaveopt,+xgetbv1,+movbe,+rdrand,check"

  return 0
}

configureAmdCpu() {

  # Configuration for AMD processors
  selectAmdCpuModel
  appendAmdCpuFlags

  return 0
}

configureIntelCpu() {

  # Configuration for Intel processors
  if [ -z "${CPU_MODEL:-}" ]; then
    CPU_MODEL="Skylake-Client-v4"
  fi

  return 0
}

composeCpuFlags() {

  # Append user flags after the required defaults so explicit feature
  # overrides retain their normal last-value-wins behavior.
  if [ -z "${CPU_FLAGS:-}" ]; then
    CPU_FLAGS="$DEFAULT_FLAGS"
  else
    CPU_FLAGS="$DEFAULT_FLAGS,$CPU_FLAGS"
  fi

  return 0
}

selectClocksource() {

  SM_BIOS=""
  CLOCKSOURCE="tsc"

  # Native x86 expects TSC; an ARM host running the x86 guest through
  # emulation is validated against its architectural counter instead.
  [[ "${ARCH,,}" == "arm64" ]] && CLOCKSOURCE="arch_sys_counter"

  return 0
}

checkClocksource() {

  local result
  local clock="/sys/devices/system/clocksource/clocksource0/current_clocksource"

  if [ ! -f "$clock" ]; then
    warn "file \"$clock\" cannot be found?"
    return 0
  fi

  result=$(<"$clock")
  result="${result//[![:print:]]/}"

  case "${result,,}" in
    # A single-vCPU Intel profile is promoted to two when host timing is
    # suitable, avoiding macOS issues with the one-core topology.
    "${CLOCKSOURCE,,}" )
      if ! needsAmdCpuProfile && [[ "$CPU_CORES" == "1" ]]; then
        CPU_CORES="2"
      fi
      ;;
    "kvm-clock" )
      warn "Nested KVM virtualization detected, this might cause issues running macOS!"
      ;;
    "hyperv_clocksource_tsc_page" )
      info "Nested Hyper-V virtualization detected, this might cause issues running macOS!"
      ;;
    "hpet" )
      warn "unsupported clock source detected: '$result'. Please set host clock source to '$CLOCKSOURCE', otherwise it will cause issues running macOS!"
      ;;
    * )
      warn "unexpected clock source detected: '$result'. Please set host clock source to '$CLOCKSOURCE', otherwise it will cause issues running macOS!"
      ;;
  esac

  return 0
}

normalizeCpuCores() {

  # Round unsupported near-power-of-two requests down to the closest stable
  # topology before the stricter SMP layout selection below.
  case "$CPU_CORES" in
    "" | "0" | "3" ) CPU_CORES="2" ;;
    "5" ) CPU_CORES="4" ;;
    "9" ) CPU_CORES="8" ;;
  esac

  return 0
}

configureSmp() {

  # Describe larger counts using socket/core combinations accepted by macOS
  # instead of exposing every requested vCPU as an arbitrary topology.
  case "$CPU_CORES" in
    "1" | "2" | "4" | "8" ) SMP="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1" ;;
    "6" | "7" ) SMP="$CPU_CORES,sockets=3,dies=1,cores=2,threads=1" ;;
    "10" | "11" ) SMP="$CPU_CORES,sockets=5,dies=1,cores=2,threads=1" ;;
    "12" | "13" ) SMP="$CPU_CORES,sockets=3,dies=1,cores=4,threads=1" ;;
    "14" | "15" ) SMP="$CPU_CORES,sockets=7,dies=1,cores=2,threads=1" ;;
    "16" | "24" | "32" | "64" ) SMP="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1" ;;
    *)
      error "Invalid amount of CPU_CORES, value \"${CPU_CORES}\" is not a power of 2!" && exit 35
      ;;
  esac

  return 0
}

configureUsb() {

  # macOS has broad compatibility with the NEC xHCI model, but MSI must be
  # disabled for reliable keyboard and controller initialization.
  USB="nec-usb-xhci,id=xhci"
  USB+=" -device usb-kbd,bus=xhci.0"
  USB+=" -global nec-usb-xhci.msi=off"

  return 0
}

checkCpuFeatures

if needsAmdCpuProfile; then
  configureAmdCpu
else
  configureIntelCpu
fi

composeCpuFlags

selectClocksource
checkClocksource

normalizeCpuCores

configureSmp
configureUsb

return 0
