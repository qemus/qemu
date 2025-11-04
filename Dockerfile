# syntax=docker/dockerfile:1

FROM debian:trixie-slim

ARG TARGETARCH
ARG VERSION_ARG="0.0"
ARG VERSION_UTK="1.2.0"
ARG VERSION_VNC="1.7.0-beta"
ARG VERSION_PASST="2025_09_19"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
        bc \
        jq \
        xxd \
        tini \
        wget \
        7zip \
        curl \
        ovmf \
        fdisk \
        nginx \
        swtpm \
        procps \
        ethtool \
        iptables \
        iproute2 \
        dnsmasq \
        xz-utils \
        apt-utils \
        net-tools \
        e2fsprogs \
        qemu-utils \
        websocketd \
        iputils-ping \
        genisoimage \
        inotify-tools \
        netcat-openbsd \
        ca-certificates \
        qemu-system-x86 && \
    wget "https://github.com/qemus/passt/releases/download/v${VERSION_PASST}/passt_${VERSION_PASST}_${TARGETARCH}.deb" -O /tmp/passt.deb -q && \
    dpkg -i /tmp/passt.deb && \
    apt-get clean && \
    mkdir -p /etc/qemu && \
    echo "allow br0" > /etc/qemu/bridge.conf && \
    mkdir -p /usr/share/novnc && \
    wget "https://github.com/novnc/noVNC/archive/refs/tags/v${VERSION_VNC}.tar.gz" -O /tmp/novnc.tar.gz -q --timeout=10 && \
    tar -xf /tmp/novnc.tar.gz -C /tmp/ && \
    cd "/tmp/noVNC-${VERSION_VNC}" && \
    mv app core vendor package.json ./*.html /usr/share/novnc && \
    unlink /etc/nginx/sites-enabled/default && \
    sed -i 's/^worker_processes.*/worker_processes 1;/' /etc/nginx/nginx.conf && \
    echo "$VERSION_ARG" > /run/version && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chmod=755 ./src /run/
COPY --chmod=755 ./web /var/www/
COPY --chmod=664 ./web/conf/defaults.json /usr/share/novnc
COPY --chmod=664 ./web/conf/mandatory.json /usr/share/novnc
COPY --chmod=744 ./web/conf/nginx.conf /etc/nginx/default.conf

ADD --chmod=755 "https://github.com/qemus/fiano/releases/download/v${VERSION_UTK}/utk_${VERSION_UTK}_${TARGETARCH}.bin" /run/utk.bin

VOLUME /storage
EXPOSE 22 5900 8006

ENV BOOT="alpine"
ENV CPU_CORES="2"
ENV RAM_SIZE="2G"
ENV DISK_SIZE="64G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
