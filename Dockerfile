FROM debian:trixie-slim

ARG VERSION_ARG="0.0"
ARG VERSION_VNC="1.4.0"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN set -eu && \
    apt-get update && \
    apt-get --no-install-recommends -y install \
        tini \
        wget \
        ovmf \
        nginx \
        swtpm \
        procps \
        iptables \
        iproute2 \
        apt-utils \
        dnsmasq \
        net-tools \
        qemu-utils \
        genisoimage \
        ca-certificates \
        netcat-openbsd \
        qemu-system-x86 && \
    apt-get clean && \
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
COPY --chmod=744 ./web/nginx.conf /etc/nginx/sites-enabled/web.conf

VOLUME /storage
EXPOSE 22 5900 8006

ENV CPU_CORES "1"
ENV RAM_SIZE "1G"
ENV DISK_SIZE "16G"
ENV BOOT "http://example.com/image.iso"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
