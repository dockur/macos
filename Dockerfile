FROM scratch
COPY --from=qemux/qemu-docker:5.10 / /

ARG VERSION_ARG="0.0"
ARG VERSION_OSX_KVM="326053dd61f49375d5dfb28ee715d38b04b5cd8e"
ARG REPO_OSX_KVM="https://raw.githubusercontent.com/kholia/OSX-KVM"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
    dmg2img \
    python3 \
    apt-get clean && \
    echo "$VERSION_ARG" > /run/version && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chmod=755 ./src /run/

ADD --chmod=755 $REPO_OSX_KVM/$VERSION_OSX_KVM/fetch-macOS-v2.py /run/
ADD --chmod=755 $REPO_OSX_KVM/$VERSION_OSX_KVM/OpenCore/OpenCore.qcow2 /images/
ADD --chmod=755 \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_CODE.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS-1024x768.fd \
    $REPO_OSX_KVM/$VERSION_OSX_KVM/OVMF_VARS-1920x1080.fd /usr/share/OVMF/

EXPOSE 8006 5900
VOLUME /storage

ENV RAM_SIZE "3G"
ENV CPU_CORES "2"
ENV DISK_SIZE "32G"
ENV VERSION "ventura"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
