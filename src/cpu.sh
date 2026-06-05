#!/usr/bin/env bash
set -Eeuo pipefail

CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')
DEFAULT_FLAGS="vendor=GenuineIntel,vmx=off,vmware-cpuid-freq=on,-pdpe1gb"

has_flag() {
  # Match a whitespace-delimited token in /proc/cpuinfo (works for flags containing '-' and avoids substring matches)
  awk -v f="$1" '
    $1 == "flags" {
      for (i = 1; i <= NF; i++) if ($i == f) exit 0
    }
    END { exit 1 }
  ' /proc/cpuinfo
}

if [[ "$CPU_VENDOR" == "AuthenticAMD" || "${KVM:-}" == [Nn]* ]]; then

  # Configuration for AMD processors

  if [ -z "${CPU_MODEL:-}" ]; then

    case "${VERSION,,}" in
      "10"* | "11"* | "12"* | "13"* | \
      "catalina" | "bigsur" | "big-sur" | "monterey" | "ventura" )
        CPU_MODEL="Haswell-noTSX"
        ;;
      *)
        CPU_MODEL="Skylake-Client-v4"
        if has_flag "spec-ctrl" && [[ "${KVM:-}" != [Nn]* ]]; then
          DEFAULT_FLAGS+=",+spec-ctrl"
        else
          DEFAULT_FLAGS+=",-spec-ctrl"
        fi
        ;;
    esac

  fi

  if [[ "${KVM:-}" == [Nn]* ]]; then
  
    DEFAULT_FLAGS+=",-pcid,-invpcid,-tsc-deadline,-xsavec,-xsaves"

  else

    for flag in pcid invpcid tsc-deadline xsavec xsaves; do
      if has_flag "$flag"; then
        DEFAULT_FLAGS+=",+$flag"
      else
        DEFAULT_FLAGS+=",-$flag"
      fi
    done

  fi

  DEFAULT_FLAGS+=",+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+smep,+xsave,+xsaveopt,+xgetbv1,+movbe,+rdrand,check"

else

  # Configuration for Intel processors
  
  if [ -z "${CPU_MODEL:-}" ]; then

    CPU_MODEL="Skylake-Client-v4"

  fi

fi

if [ -z "${CPU_FLAGS:-}" ]; then
  CPU_FLAGS="$DEFAULT_FLAGS"
else
  CPU_FLAGS="$DEFAULT_FLAGS,$CPU_FLAGS"
fi

SM_BIOS=""
CLOCKSOURCE="tsc"
[[ "${ARCH,,}" == "arm64" ]] && CLOCKSOURCE="arch_sys_counter"
CLOCK="/sys/devices/system/clocksource/clocksource0/current_clocksource"

if [ ! -f "$CLOCK" ]; then
  warn "file \"$CLOCK\" cannot be found?"
else
  result=$(<"$CLOCK")
  result="${result//[![:print:]]/}"
  case "${result,,}" in
    "${CLOCKSOURCE,,}" ) 
      if [[ "$CPU_VENDOR" == "GenuineIntel" && "$CPU_CORES" == "1" && "${KVM:-}" != [Nn]* ]]; then
        CPU_CORES="2"
      fi ;;
    "kvm-clock" ) warn "Nested KVM virtualization detected, this might cause issues running macOS!" ;;
    "hyperv_clocksource_tsc_page" ) info "Nested Hyper-V virtualization detected, this might cause issues running macOS!" ;;
    "hpet" ) warn "unsupported clock source detected: '$result'. Please set host clock source to '$CLOCKSOURCE', otherwise it will cause issues running macOS!" ;;
    *) warn "unexpected clock source detected: '$result'. Please set host clock source to '$CLOCKSOURCE', otherwise it will cause issues running macOS!" ;;
  esac
fi

case "$CPU_CORES" in
  "" | "0" | "3" ) CPU_CORES="2" ;;
  "5" ) CPU_CORES="4" ;;
  "9" ) CPU_CORES="8" ;;
esac

case "$CPU_CORES" in
  "1" | "2" | "4" | "8" ) SMP="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1" ;;
  "6" | "7" ) SMP="$CPU_CORES,sockets=3,dies=1,cores=2,threads=1" ;;
  "10" | "11" ) SMP="$CPU_CORES,sockets=5,dies=1,cores=2,threads=1" ;;
  "12" | "13" ) SMP="$CPU_CORES,sockets=3,dies=1,cores=4,threads=1" ;;
  "14" | "15" ) SMP="$CPU_CORES,sockets=7,dies=1,cores=2,threads=1" ;;
  "16" | "32" | "64" ) SMP="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1" ;;
  *)
    error "Invalid amount of CPU_CORES, value \"${CPU_CORES}\" is not a power of 2!" && exit 35
    ;;
esac

USB="nec-usb-xhci,id=xhci"
USB+=" -device usb-kbd,bus=xhci.0"
USB+=" -global nec-usb-xhci.msi=off"

return 0
