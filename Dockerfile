FROM debian:trixie-slim

ARG VERSION_ARG="0.0"
ARG VERSION_VNC="1.6.0"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
        bc \
        jq \
        tini \
        wget \
        7zip \
        curl \
        fdisk \
        nginx \
        swtpm \
        procps \
        iptables \
        iproute2 \
        apt-utils \
        dnsmasq \
        xz-utils \
        net-tools \
        e2fsprogs \
        qemu-utils \
        iputils-ping \
        genisoimage \
        ca-certificates \
        qemu-system-x86 && \
    apt-get clean && \
    mkdir -p /etc/qemu && \
    echo "allow br0" > /etc/qemu/bridge.conf && \
    wget "https://snapshot.debian.org/archive/debian/20250128T092032Z/pool/main/e/edk2/ovmf_2024.11-5_all.deb" -O /tmp/ovmf.deb -q --timeout=10 && \
    dpkg -i /tmp/ovmf.deb && \
    mkdir -p /usr/share/novnc && \
    wget "https://github.com/novnc/noVNC/archive/refs/tags/v${VERSION_VNC}.tar.gz" -O /tmp/novnc.tar.gz -q --timeout=10 && \
    tar -xf /tmp/novnc.tar.gz -C /tmp/ && \
    cd "/tmp/noVNC-${VERSION_VNC}" && \
    mv app core vendor package.json *.html /usr/share/novnc && \
    unlink /etc/nginx/sites-enabled/default && \
    sed -i 's/^worker_processes.*/worker_processes 1;/' /etc/nginx/nginx.conf && \
    echo "$VERSION_ARG" > /run/version && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --chmod=755 ./src /run/
COPY --chmod=755 ./web /var/www/
COPY --chmod=664 ./web/conf/defaults.json /usr/share/novnc
COPY --chmod=664 ./web/conf/mandatory.json /usr/share/novnc
COPY --chmod=744 ./web/conf/nginx.conf /etc/nginx/sites-enabled/web.conf

VOLUME /storage
EXPOSE 22 5900 8006

ENV BOOT="alpine"
ENV CPU_CORES="2"
ENV RAM_SIZE="2G"
ENV DISK_SIZE="16G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
