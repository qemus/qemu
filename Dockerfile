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
        dos2unix \
        net-tools \
        e2fsprogs \
        qemu-utils \
        websocketd \
        iputils-ping \
        genisoimage \
        inotify-tools \
        netcat-openbsd \
        ca-certificates \
        qemu-system-x86 \
        qemu-system-modules-spice && \
    wget "https://github.com/qemus/passt/releases/download/v${VERSION_PASST}/passt_${VERSION_PASST}_${TARGETARCH}.deb" -O /tmp/passt.deb -q && \
    dpkg -i /tmp/passt.deb && \
    apt-get clean && \
    mkdir -p /etc/qemu && \
    echo "allow br0" > /etc/qemu/bridge.conf && \
    mkdir -p /usr/share/novnc && \
    wget "https://github.com/novnc/noVNC/archive/refs/tags/v${VERSION_VNC}.tar.gz" -O /tmp/novnc.tar.gz -q --timeout=10 && \
    tar -xf /tmp/novnc.tar.gz -C /tmp/ && \
    mv /tmp/noVNC-${VERSION_VNC}/app /tmp/noVNC-${VERSION_VNC}/core /tmp/noVNC-${VERSION_VNC}/vendor /tmp/noVNC-${VERSION_VNC}/package.json /tmp/noVNC-${VERSION_VNC}/*.html /usr/share/novnc && \
    unlink /etc/nginx/sites-enabled/default && \
    sed -i 's/^worker_processes.*/worker_processes 1;/' /etc/nginx/nginx.conf && \
    echo "$VERSION_ARG" > /run/version && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN apt-get update && \
    apt-get --no-install-recommends install -y python3 python3-venv && \
    python3 -m venv /opt/isoenv && \
    /opt/isoenv/bin/pip install --no-cache-dir pycdlib && \
    ln -sf /opt/isoenv/bin/python /usr/local/bin/pycdlib-python && \
    ln -sf /opt/isoenv/bin/pycdlib /usr/local/bin/pycdlib-python && \
    rm -rf /var/lib/apt/lists/*

COPY --chmod=755 ./src /run/
RUN dos2unix /run/*

COPY --chmod=644 ./assets /run/assets
RUN dos2unix /run/assets/*

COPY --chmod=755 ./web /var/www/
COPY --chmod=664 ./web/conf/defaults.json /usr/share/novnc
COPY --chmod=664 ./web/conf/mandatory.json /usr/share/novnc
COPY --chmod=744 ./web/conf/nginx.conf /etc/nginx/default.conf

ADD --chmod=755 "https://github.com/qemus/fiano/releases/download/v${VERSION_UTK}/utk_${VERSION_UTK}_${TARGETARCH}.bin" /run/utk.bin

VOLUME /storage
EXPOSE 22 5900 8006

ENV RAM_SIZE="8G"
ENV CPU_CORES="8"
ENV DISK_SIZE="64G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
