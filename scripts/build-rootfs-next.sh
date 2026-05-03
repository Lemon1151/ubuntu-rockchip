#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

if [[ -f ubuntu-${RELASE_VERSION}-${SUITE}-${FLAVOR}-arm64.rootfs.tar.xz ]]; then
    exit 0
fi

pushd .

tmp_dir=$(mktemp -d)
cd "${tmp_dir}" || exit 1

# Clone the livecd rootfs fork
git clone https://github.com/Joshua-Riek/livecd-rootfs
cd livecd-rootfs || exit 1

# Install build deps
apt-get update
apt-get build-dep . -y

# Build the package
dpkg-buildpackage -us -uc

# Install the custom livecd rootfs package
apt-get install ../livecd-rootfs_*.deb --assume-yes --allow-downgrades --allow-change-held-packages
dpkg -i ../livecd-rootfs_*.deb
apt-mark hold livecd-rootfs

rm -rf "${tmp_dir}"

popd

mkdir -p live-build && cd live-build

# Query the system to locate livecd-rootfs auto script installation path
cp -r "$(dpkg -L livecd-rootfs | grep "auto$")" auto

set +e

export ARCH=arm64
export IMAGEFORMAT=none
export IMAGE_TARGETS=none

# Populate the configuration directory for live build
lb config \
    --architecture arm64 \
    --bootstrap-qemu-arch arm64 \
    --bootstrap-qemu-static /usr/bin/qemu-aarch64-static \
    --archive-areas "main restricted universe multiverse" \
    --parent-archive-areas "main restricted universe multiverse" \
    --mirror-bootstrap "http://ports.ubuntu.com" \
    --parent-mirror-bootstrap "http://ports.ubuntu.com" \
    --mirror-chroot-security "http://ports.ubuntu.com" \
    --parent-mirror-chroot-security "http://ports.ubuntu.com" \
    --mirror-binary-security "http://ports.ubuntu.com" \
    --parent-mirror-binary-security "http://ports.ubuntu.com" \
    --mirror-binary "http://ports.ubuntu.com" \
    --parent-mirror-binary "http://ports.ubuntu.com" \
    --keyring-packages ubuntu-keyring \

# Generic packages to install
echo "software-properties-common" > config/package-lists/my.list.chroot

# =========================================================
# Next (26.04 / 28.04) package selection
# =========================================================
if [ "${PROJECT}" = "ubuntu" ]; then
    cat >> config/package-lists/my.list.chroot << EOF
ubuntu-desktop-minimal
localechooser-data
console-setup
nano
htop
tzdata
user-setup
network-manager
net-tools
iproute2
isc-dhcp-client
mesa-vulkan-drivers
mesa-va-drivers
alsa-utils
pipewire
pipewire-pulse
wireplumber
bluez
bluetooth
openssh-server
fastfetch
zstd
EOF
else
    cat >> config/package-lists/my.list.chroot << EOF
ubuntu-server
console-setup
nano
htop
kmod
tzdata
user-setup
network-manager
net-tools
iproute2
isc-dhcp-client
mesa-vulkan-drivers
alsa-utils
pipewire
wireplumber
bluez
bluetooth
openssh-server
fastfetch
zstd
EOF
fi

echo "Building rootfs for ${SUITE} (${FLAVOR})..."

# Build the rootfs
lb build

set -eE 

# ==============================================
# 清空 Ubuntu 默认固件
# ==============================================
echo "Clearing Ubuntu default firmware..."
rm -rf chroot/usr/lib/firmware
mkdir -p chroot/usr/lib/firmware

# ==============================================
# 安装 Armbian 固件 + 官方 linux-firmware 覆盖
# ==============================================
echo "Installing Armbian firmware..."
wget -O armbian-fw.tar.gz https://github.com/armbian/firmware/archive/refs/heads/master.tar.gz
tar -xf armbian-fw.tar.gz
cp -Rf firmware-master/* chroot/usr/lib/firmware/
rm -rf firmware-master armbian-fw.tar.gz

echo "Installing official linux-firmware (overwrite)..."
wget -O linux-fw.tar.gz https://gitlab.com/kernel-firmware/linux-firmware/-/archive/main/linux-firmware-main.tar.gz
tar -xf linux-fw.tar.gz
cp -Rf linux-firmware-main/* chroot/usr/lib/firmware/
rm -rf linux-firmware-main linux-fw.tar.gz

echo "Fix firmware permissions..."
chown -R root:root chroot/usr/lib/firmware
chmod -R 755 chroot/usr/lib/firmware

# ==============================================
# 安全卸载冗余包
# ==============================================
echo "Purging unused packages..."
chroot chroot apt-get purge -y \
  man-db manpages manpages-dev \
  texinfo info \
  docbook-xml docbook-xsl \
  yelp yelp-xsl \
  gnome-user-docs ubuntu-docs \
  systemd-coredump systemd-bootchart \
  gdb strace ltrace valgrind \
  "*-dbg" "*-dbgsym" \

# 自动清理无用依赖
chroot chroot apt-get autoremove -y
chroot chroot apt-get clean
chroot chroot apt-get purge -y snapd
chroot chroot apt-mark hold snapd

# ==============================================
# 设置主机名
# ==============================================
echo "Setting hostname to ${BOARD}..."
echo "${BOARD}" > chroot/etc/hostname

cat > chroot/etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   ${BOARD}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# ==============================================
# 【核心】销毁 Live 模式标记 → 永久系统
# ==============================================
echo "Disabling live mode permanently..."
rm -rf chroot/var/lib/livecd-rootfs
rm -rf chroot/usr/lib/livecd-rootfs
rm -f chroot/etc/livecd.conf
rm -f chroot/lib/systemd/system/multi-user.target.wants/live*
rm -f chroot/etc/systemd/system/multi-user.target.wants/live*

chroot chroot systemctl disable --now livecd-rootfs.service || true
chroot chroot systemctl mask livecd-rootfs.service || true
chroot chroot systemctl disable --now livecd-installer.service || true
chroot chroot systemctl mask livecd-installer.service || true

# ==============================================
# 创建默认用户 ubuntu / ubuntu
# ==============================================
echo "Creating default user: ubuntu (password: ubuntu)..."
chroot chroot useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,dialout ubuntu
echo 'ubuntu:ubuntu' | chroot chroot chpasswd

# ==============================================
# 设置时区 Asia/Shanghai
# ==============================================
echo "Setting timezone to Asia/Shanghai..."
chroot chroot ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > chroot/etc/timezone

# ==============================================
# 设置 root 密码 + SSH
# ==============================================
echo "Setting root password to 'root' and enabling root SSH..."
echo 'root:root' | chroot chroot chpasswd

chroot chroot sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
chroot chroot sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

chroot chroot systemctl enable ssh

chroot chroot apt clean
rm -rf chroot/var/lib/apt/lists/*

# ==============================================
# 打包 rootfs
# ==============================================
echo "Listing chroot/ directory before tarring:"
ls -l chroot/

(cd chroot/ &&  tar -p -c --sort=name --xattrs ./*) | xz -3 -T0 > "ubuntu-${RELASE_VERSION}-${SUITE}-${FLAVOR}-arm64.rootfs.tar.xz"

echo "Listing current directory after tarring:"
ls -l

mv "ubuntu-${RELASE_VERSION}-${SUITE}-${FLAVOR}-arm64.rootfs.tar.xz" ../

echo "Listing parent directory after moving the file:"
ls -l ..
