# syntax=docker/dockerfile:1

FROM scratch AS base
COPY --from=qemux/qemu:7.47 / /

ARG VERSION_ARG="0.0"
ARG VERSION_VM_HIDE="2.0.0"
ARG VERSION_OPENCORE="1.0.7"
ARG VERSION_KVM_OPENCORE="0.7"
ARG VERSION_OSX_KVM="326053dd61f49375d5dfb28ee715d38b04b5cd8e"

ARG REPO_OPENCORE="https://github.com/acidanthera/OpenCorePkg"
ARG REPO_VM_HIDE="https://github.com/Carnations-Botanica/VMHide"
ARG REPO_KVM_OPENCORE="https://github.com/LongQT-sea/OpenCore-ISO"
ARG REPO_OSX_KVM="https://raw.githubusercontent.com/kholia/OSX-KVM"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN <<EOF
  set -eu

  apt-get update
  apt-get --no-install-recommends -y install \
    mtools \
    xmlstarlet

  apt-get clean

  # Extract macserial
  wget "$REPO_OPENCORE/releases/download/$VERSION_OPENCORE/OpenCore-$VERSION_OPENCORE-RELEASE.zip" -O /tmp/opencore.zip -q --timeout=30
  unzip -p /tmp/opencore.zip Utilities/macserial/macserial.linux > /usr/local/bin/macserial
  chmod 755 /usr/local/bin/macserial

  # Set version file
  echo "$VERSION_ARG" > /etc/version

  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF

COPY --chmod=755 ./src /run/
COPY --chmod=755 ./assets /assets/

ADD --chmod=644 \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_CODE.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS-1024x768.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS-1920x1080.fd /usr/share/OVMF/

ADD $REPO_VM_HIDE/releases/download/$VERSION_VM_HIDE/VMHide-$VERSION_VM_HIDE-RELEASE.zip /vmh.zip
ADD $REPO_KVM_OPENCORE/releases/download/v$VERSION_KVM_OPENCORE/LongQT-OpenCore-v$VERSION_KVM_OPENCORE.iso /opencore.iso

VOLUME /storage
EXPOSE 22 5900 8006

ENV VERSION="14"
ENV RAM_SIZE="4G"
ENV CPU_CORES="1"
ENV DISK_SIZE="64G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
