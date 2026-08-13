# syntax=docker/dockerfile:1

FROM debian:trixie-slim

ARG TARGETARCH
ARG VERSION_ARG="0.0"
ARG VERSION_QMP="0.0.6"
ARG VERSION_WSD="0.4.2"
ARG VERSION_UTK="1.3.0"
ARG VERSION_VNC="1.7.0"
ARG VERSION_MINI="1.0.0"
ARG VERSION_OVMF="2026.05-2"
ARG VERSION_PASST="2026_07_28"
ARG VERSION_SEABIOS="1.17.0-1"
ARG VERSION_QEMU="1:11.0.3+ds-2"
ARG DEBIAN_SNAPSHOT="20260809T204446Z"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN --mount=type=bind,source=web/conf/novnc.sh,target=/run/novnc.sh,ro <<EOF
  set -eu

  echo "deb https://deb.debian.org/debian trixie non-free" > /etc/apt/sources.list.d/non-free.list

  apt-get update
  apt-get --no-install-recommends -y install \
    bc \
    jq \
    xxd \
    tini \
    wget \
    7zip \
    7zip-rar \
    curl \
    aria2 \
    fdisk \
    nginx \
    unzip \
    swtpm \
    procps \
    ipcalc \
    ethtool \
    python3 \
    python3-pip \
    iptables \
    iproute2 \
    dnsmasq \
    xorriso \
    xz-utils \
    apt-utils \
    net-tools \
    e2fsprogs \
    diffutils \
    util-linux \
    iputils-ping \
    genisoimage \
    inotify-tools \
    netcat-openbsd \
    ca-certificates

  if [ "$TARGETARCH" = "amd64" ]; then
    wget "https://github.com/qemus/qemu-minimal/releases/download/v${VERSION_MINI}/qemu-minimal_${VERSION_MINI}_amd64.deb" -O /tmp/mini.deb -q --timeout=10
    apt-get --no-install-recommends -y install /tmp/mini.deb
  fi

  # Install QEMU 11 and OVMF UEFI firmware from Debian Sid
  echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ sid main" \
    > /etc/apt/sources.list.d/qemu-snapshot.list

  apt-get update
  apt-get --no-install-recommends -y -t sid install \
    "seabios=${VERSION_SEABIOS}" \
    "ovmf-generic=${VERSION_OVMF}" \
    "qemu-utils=${VERSION_QEMU}" \
    "qemu-system-x86=${VERSION_QEMU}"

  if [ "$TARGETARCH" = "amd64" ]; then
    apt-get --no-install-recommends -y -t sid install \
      "qemu-system-modules-opengl=${VERSION_QEMU}" \
      "qemu-system-modules-spice=${VERSION_QEMU}"
  fi

  # Install QMP
  pip3 install --no-cache-dir --break-system-packages --root-user-action=ignore "qemu.qmp==${VERSION_QMP}"

  # Install Passt package
  wget "https://github.com/qemus/passt/releases/download/v${VERSION_PASST}/passt_${VERSION_PASST}_${TARGETARCH}.deb" -O /tmp/passt.deb -q --timeout=10
  dpkg -i /tmp/passt.deb

  # Install websocketd package
  wget "https://github.com/qemus/websocketd/releases/download/v${VERSION_WSD}/websocketd-${VERSION_WSD}_${TARGETARCH}.deb" -O /tmp/wsd.deb -q --timeout=10
  dpkg -i /tmp/wsd.deb

  rm -f /etc/apt/sources.list.d/qemu-snapshot.list
  apt-get clean

  # Install noVNC
  sh /run/novnc.sh "$VERSION_VNC"

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

ADD --chmod=755 "https://github.com/qemus/boot-logo/releases/download/v${VERSION_UTK}/boot-logo_${TARGETARCH}.bin" /run/boot-logo

VOLUME /storage
EXPOSE 22 5900 8006

ENV BOOT="alpine"
ENV CPU_CORES="2"
ENV RAM_SIZE="2G"
ENV DISK_SIZE="64G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
