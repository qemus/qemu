# syntax=docker/dockerfile:1

FROM debian:trixie-slim

ARG TARGETARCH
ARG VERSION_ARG="0.0"
ARG VERSION_QMP="0.0.6"
ARG VERSION_UTK="1.1.0"
ARG VERSION_VNC="1.7.0"
ARG VERSION_OVMF="2025.11-5"
ARG VERSION_SEABIOS="1.17.0-1"
ARG VERSION_PASST="2026_07_28"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN --mount=type=bind,source=web/conf/novnc.sh,target=/run/novnc.sh,ro <<EOF
  set -eu

  apt-get update
  apt-get --no-install-recommends -y install \
    bc \
    jq \
    xxd \
    tini \
    wget \
    7zip \
    curl \
    aria2 \
    fdisk \
    nginx \
    swtpm \
    procps \
    ipcalc \
    ethtool \
    iptables \
    iproute2 \
    dnsmasq \
    xorriso \
    xz-utils \
    apt-utils \
    net-tools \
    e2fsprogs \
    diffutils \
    qemu-utils \
    util-linux \
    websocketd \
    iputils-ping \
    genisoimage \
    inotify-tools \
    netcat-openbsd \
    ca-certificates \
    qemu-system-x86 \
    python3 \
    python3-pip

  # Install QMP
  pip3 install --no-cache-dir --break-system-packages --root-user-action=ignore "qemu.qmp==${VERSION_QMP}"

  # Install Passt package
  wget "https://github.com/qemus/passt/releases/download/v${VERSION_PASST}/passt_${VERSION_PASST}_${TARGETARCH}.deb" -O /tmp/passt.deb -q --timeout=10
  dpkg -i /tmp/passt.deb

  # Install SeaBIOS package
  wget "https://deb.debian.org/debian/pool/main/s/seabios/seabios_${VERSION_SEABIOS}_all.deb" -O /tmp/seabios.deb -q --timeout=10
  dpkg -i /tmp/seabios.deb

  # Install OVMF package
  wget "https://deb.debian.org/debian/pool/main/e/edk2/ovmf-generic_${VERSION_OVMF}_all.deb" -O /tmp/ovmf.deb -q --timeout=10
  dpkg -i /tmp/ovmf.deb

  apt-get clean

  # Configure QEMU
  mkdir -p /etc/qemu
  echo "allow br0" > /etc/qemu/bridge.conf

  # Install noVNC
  sh /run/novnc.sh "$VERSION_VNC"

  # Configure nginx
  unlink /etc/nginx/sites-enabled/default
  sed -i 's/^worker_processes.*/worker_processes 1;/' /etc/nginx/nginx.conf

  # Set version file
  echo "$VERSION_ARG" > /etc/version

  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF

COPY --chmod=755 ./src /run/
COPY --chmod=755 --exclude=conf/novnc.sh ./web /var/www/
COPY --chmod=664 ./web/conf/defaults.json /usr/share/novnc
COPY --chmod=664 ./web/conf/mandatory.json /usr/share/novnc
COPY --chmod=744 ./web/conf/nginx.conf /etc/nginx/default.conf
COPY --chmod=644 ./web/img/favicon.svg /usr/share/novnc/app/images/favicon.svg

ADD --chmod=755 "https://github.com/qemus/boot-logo/releases/download/v${VERSION_UTK}/boot-logo_${TARGETARCH}.bin" /run

VOLUME /storage
EXPOSE 22 5900 8006

ENV BOOT="alpine"
ENV CPU_CORES="2"
ENV RAM_SIZE="2G"
ENV DISK_SIZE="64G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
