#!/usr/bin/env bash
set -Eeuo pipefail

trap 'error "Status $? while: $BASH_COMMAND (line $LINENO/$BASH_LINENO)"' ERR

[ ! -f "/run/entry.sh" ] && error "Script must run inside Docker container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

echo "❯ Starting $APP for Docker v$(</run/version)..."
echo "❯ For support visit $SUPPORT"

# Docker environment variables

: "${BOOT:=""}"            # URL of the ISO file
: "${DEBUG:="N"}"          # Disable debugging
: "${MACHINE:="q35"}"      # Machine selection
: "${ALLOCATE:=""}"        # Preallocate diskspace
: "${ARGUMENTS:=""}"       # Extra QEMU parameters
: "${CPU_CORES:="2"}"      # Amount of CPU cores
: "${RAM_SIZE:="2G"}"      # Maximum RAM amount
: "${RAM_CHECK:="Y"}"      # Check available RAM
: "${DISK_SIZE:="64G"}"    # Initial data disk size
: "${BOOT_MODE:=""}"       # Boot system with UEFI
: "${BOOT_INDEX:="9"}"     # Boot index of CD drive
: "${STORAGE:="/storage"}" # Storage folder location

# Helper variables

PROCESS="${APP,,}"
PROCESS="${PROCESS// /-}"

INFO="/run/shm/msg.html"
PAGE="/run/shm/index.html"
TEMPLATE="/var/www/index.html"
FOOTER1="$APP for Docker v$(</run/version)"
FOOTER2="<a href='$SUPPORT'>$SUPPORT</a>"

CPU=$(cpu)
SYS=$(uname -r)
HOST=$(hostname -s)
KERNEL=$(echo "$SYS" | cut -b 1)
MINOR=$(echo "$SYS" | cut -d '.' -f2)
ARCH=$(dpkg --print-architecture)
CORES=$(grep -c '^processor' /proc/cpuinfo)

if ! grep -qi "socket(s)" <<< "$(lscpu)"; then
  SOCKETS=1
else
  SOCKETS=$(lscpu | grep -m 1 -i 'socket(s)' | awk '{print $(2)}')
fi

CPU_CORES="${CPU_CORES// /}"
[[ "${CPU_CORES,,}" == "max" ]] && CPU_CORES="$CORES"
[ -n "${CPU_CORES//[0-9 ]}" ] && error "Invalid amount of CPU_CORES: $CPU_CORES" && exit 15

if [ "$CPU_CORES" -gt "$CORES" ]; then
  warn "The amount for CPU_CORES (${CPU_CORES}) exceeds the amount of physical cores, so will be limited to ${CORES}."
  CPU_CORES="$CORES"
fi

# Check system

if [ ! -d "/dev/shm" ]; then
  error "Directory /dev/shm not found!" && exit 14
else
  [ ! -d "/run/shm" ] && ln -s /dev/shm /run/shm
fi

# Check folder

if [[ "${COMMIT:-}" == [Yy1]* ]]; then
  STORAGE="/local"
  mkdir -p "$STORAGE"
fi

if [ ! -d "$STORAGE" ]; then
  error "Storage folder ($STORAGE) not found!" && exit 13
fi

if [ ! -w "$STORAGE" ]; then
  error "Storage folder ($STORAGE) is not writeable!" && exit 13
fi

# Read memory
RAM_SPARE=500000000
RAM_AVAIL=$(free -b | grep -m 1 Mem: | awk '{print $7}')
RAM_TOTAL=$(free -b | grep -m 1 Mem: | awk '{print $2}')

RAM_SIZE="${RAM_SIZE// /}"
[ -z "$RAM_SIZE" ] && error "RAM_SIZE not specified!" && exit 16

if [[ "${RAM_SIZE,,}" == "max" ]]; then
  RAM_WANTED=$(( RAM_AVAIL - RAM_SPARE - RAM_SPARE ))
  RAM_WANTED=$(( RAM_WANTED / 1073741825 ))
  RAM_SIZE="${RAM_WANTED}G"
fi

if [ -z "${RAM_SIZE//[0-9. ]}" ]; then
  [ "${RAM_SIZE%%.*}" -lt "130" ] && RAM_SIZE="${RAM_SIZE}G" || RAM_SIZE="${RAM_SIZE}M"
fi

RAM_SIZE=$(echo "${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
! numfmt --from=iec "$RAM_SIZE" &>/dev/null && error "Invalid RAM_SIZE: $RAM_SIZE" && exit 16
RAM_WANTED=$(numfmt --from=iec "$RAM_SIZE")
[ "$RAM_WANTED" -lt "136314880 " ] && error "RAM_SIZE is too low: $RAM_SIZE" && exit 16

# Print system info
SYS="${SYS/-generic/}"
FS=$(stat -f -c %T "$STORAGE")
FS="${FS/UNKNOWN //}"
FS="${FS/ext2\/ext3/ext4}"
FS=$(echo "$FS" | sed 's/[)(]//g')
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)
SPACE_GB=$(formatBytes "$SPACE" "down")
AVAIL_MEM=$(formatBytes "$RAM_AVAIL" "down")
TOTAL_MEM=$(formatBytes "$RAM_TOTAL" "up")

echo "❯ CPU: ${CPU} | RAM: ${AVAIL_MEM/ GB/}/$TOTAL_MEM | DISK: $SPACE_GB (${FS}) | KERNEL: ${SYS}..."
echo

# Check compatibilty

if [[ "${FS,,}" == "ecryptfs" || "${FS,,}" == "tmpfs" ]]; then
  DISK_IO="threads"
  DISK_CACHE="writeback"
fi

if [[ "${BOOT_MODE:-}" == "windows"* ]]; then
  if [[ "${FS,,}" == "btrfs" ]]; then
    warn "you are using the BTRFS filesystem for /storage, this might introduce issues with Windows Setup!"
  fi
fi

# Check available memory

if [[ "$RAM_CHECK" != [Nn]* ]] && (( (RAM_WANTED + RAM_SPARE) > RAM_AVAIL )); then
  AVAIL_MEM=$(formatBytes "$RAM_AVAIL")
  msg="Your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is too high for the $AVAIL_MEM of memory available, please set a lower value."
  [[ "${FS,,}" != "zfs" ]] && error "$msg" && exit 17
  info "$msg"
fi

addPackage() {
  local pkg=$1
  local desc=$2

  if apt-mark showinstall | grep -qx "$pkg"; then
    return 0
  fi

  MSG="Installing $desc..."
  info "$MSG" && html "$MSG"

  DEBIAN_FRONTEND=noninteractive apt-get -qq update
  DEBIAN_FRONTEND=noninteractive apt-get -qq --no-install-recommends -y install "$pkg" > /dev/null

  return 0
}

cp -r /var/www/* /run/shm
html "Starting $APP for Docker..."

if [[ "${WEB:-}" != [Nn]* ]]; then

  user="admin"
  [ -n "${USER:-}" ] && user="${USER:-}"
  
  if [ -n "${PASS:-}" ]; then
  
    sed -i "s/auth_basic off/auth_basic \"NoVNC\"/g" /etc/nginx/sites-enabled/web.conf
  
  else
  
    sed -i "s/auth_basic \"NoVNC\"/auth_basic off/g" /etc/nginx/sites-enabled/web.conf
  
  fi
  
  # Set password
  echo "$user:{PLAIN}${PASS:-}" > /etc/nginx/.htpasswd
  
  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then
  
    sed -i "s/listen 8006 default_server;/listen [::]:8006 default_server ipv6only=off;/g" /etc/nginx/sites-enabled/web.conf
  
  else
  
    sed -i "s/listen [::]:8006 default_server ipv6only=off;/listen 8006 default_server;/g" /etc/nginx/sites-enabled/web.conf
  
  fi
  
  # Start webserver
  nginx -e stderr

fi

return 0
