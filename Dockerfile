FROM --platform=linux/amd64 debian:trixie-slim AS builder

ARG VERSION_KVM_OPENCORE="v21"
ARG REPO_KVM_OPENCORE="https://github.com/thenickdude/KVM-Opencore"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
    fdisk \
    mtools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chmod=755 ./src/build.sh /run
COPY --chmod=644 ./config.plist /run

ADD $REPO_KVM_OPENCORE/releases/download/$VERSION_KVM_OPENCORE/OpenCore-$VERSION_KVM_OPENCORE.iso.gz /tmp/opencore.iso.gz

RUN gzip -d /tmp/opencore.iso.gz && \
    run/build.sh /tmp/opencore.iso /run/config.plist && \
    rm -rf /tmp/*

FROM scratch AS runner
COPY --from=qemux/qemu-docker:6.08 / /

ARG VERSION_ARG="0.0"
ARG VERSION_OSX_KVM="326053dd61f49375d5dfb28ee715d38b04b5cd8e"
ARG REPO_OSX_KVM="https://raw.githubusercontent.com/kholia/OSX-KVM"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
    python3 && \
    apt-get clean && \
    echo "$VERSION_ARG" > /run/version && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chmod=755 ./src /run/
COPY --chmod=644 --from=builder /images /images

ADD --chmod=644 \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_CODE.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS-1024x768.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS-1920x1080.fd /usr/share/OVMF/

EXPOSE 8006 5900
VOLUME /storage

ENV VERSION="13"
ENV RAM_SIZE="4G"
ENV CPU_CORES="2"
ENV DISK_SIZE="64G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
