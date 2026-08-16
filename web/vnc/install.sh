#!/bin/sh
set -eu

VERSION_VNC="${1:?noVNC version must be specified}"
OVERRIDE_DIR="${2:?noVNC override directory must be specified}"
ARCHIVE="/tmp/novnc.tar.gz"
SOURCE_DIR="/tmp/noVNC-${VERSION_VNC}"
INSTALL_DIR="/usr/share/novnc"

mkdir -p "$INSTALL_DIR"

wget \
  "https://github.com/novnc/noVNC/archive/refs/tags/v${VERSION_VNC}.tar.gz" \
  -O "$ARCHIVE" \
  -q \
  --timeout=10

tar -xf "$ARCHIVE" -C /tmp/

if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR: noVNC source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if [ ! -f "$OVERRIDE_DIR/VERSION" ]; then
  echo "ERROR: noVNC override version file not found" >&2
  exit 1
fi

OVERRIDE_VERSION="$(cat "$OVERRIDE_DIR/VERSION")"
if [ "$OVERRIDE_VERSION" != "$VERSION_VNC" ]; then
  echo "ERROR: noVNC override version $OVERRIDE_VERSION does not match $VERSION_VNC" >&2
  exit 1
fi

for file in \
  app/ui.js \
  core/input/util.js \
  core/rfb.js \
  vnc.html
do
  if [ ! -f "$OVERRIDE_DIR/$file" ]; then
    echo "ERROR: noVNC override file not found: $file" >&2
    exit 1
  fi
  cp "$OVERRIDE_DIR/$file" "$SOURCE_DIR/$file"
done

cd "$SOURCE_DIR"
mv app core vendor package.json ./*.html "$INSTALL_DIR"

ln -sf /var/www/js/audio.js "$INSTALL_DIR/audio-plugin.js"
