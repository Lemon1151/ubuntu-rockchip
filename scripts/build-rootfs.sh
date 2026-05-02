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
    --linux-flavours "${KERNEL_FLAVOR}"

if [ "${SUITE}" == "noble" ] || [ "${SUITE}" == "jammy" ]; then
    # Pin rockchip package archives
    (
        echo "Package: *"
        echo "Pin: release o=LP-PPA-jjriek-rockchip"
        echo "Pin-Priority: 1001"
        echo ""
        echo "Package: *"
        echo "Pin: release o=LP-PPA-jjriek-rockchip-multimedia"
        echo "Pin-Priority: 1001"
    ) > config/archives/extra-ppas.pref.chroot
fi

if [ "${SUITE}" == "noble" ]; then
    # Ignore custom ubiquity package (mistake i made, uploaded to wrong ppa)
    (
        echo "Package: oem-*"
        echo "Pin: release o=LP-PPA-jjriek-rockchip-multimedia"
        echo "Pin-Priority: -1"
        echo ""
        echo "Package: ubiquity*"
        echo "Pin: release o=LP-PPA-jjriek-rockchip-multimedia"
        echo "Pin-Priority: -1"

    ) > config/archives/extra-ppas-ignore.pref.chroot
fi

# Snap packages to install
(
    echo "snapd/classic=stable"
    echo "core22/classic=stable"
    echo "lxd/classic=stable"
) > config/seeded-snaps

# Generic packages to install
echo "software-properties-common" > config/package-lists/my.list.chroot

if [ "${SUITE}" = "jammy" ] || [ "${SUITE}" = "noble" ]; then

    if [ "${PROJECT}" = "ubuntu" ]; then
        # ppa:ubuntu-desktop-rockchip
        cat >> config/package-lists/my.list.chroot << EOF
ubuntu-desktop-rockchip
oem-config-gtk
ubiquity-frontend-gtk
ubiquity-slideshow-ubuntu
localechooser-data
EOF
    else
        ## ppa:ubuntu-server-rockchip
        echo "ubuntu-server-rockchip" >> config/package-lists/my.list.chroot
    fi

elif [ "${SUITE}" = "resolute" ]; then

    if [ "${PROJECT}" = "ubuntu" ]; then
        cat >> config/package-lists/my.list.chroot << EOF
ubuntu-desktop
oem-config-gtk
ubiquity-frontend-gtk
ubiquity-slideshow-ubuntu
localechooser-data
console-setup
kbd
tzdata
user-setup
network-manager
net-tools
iproute2
isc-dhcp-client
linux-firmware
firmware-brcm80211
firmware-realtek
mesa-vulkan-drivers
mesa-va-drivers
xserver-xorg-video-rockchip
alsa-utils
pipewire
pipewire-pulse
wireplumber
bluez
bluetooth
openssh-server
EOF
    else
        cat >> config/package-lists/my.list.chroot << EOF
ubuntu-server
console-setup
kbd
tzdata
user-setup
network-manager
net-tools
iproute2
isc-dhcp-client
linux-firmware
firmware-brcm80211
firmware-realtek
mesa-vulkan-drivers
mesa-va-drivers
xserver-xorg-video-rockchip
alsa-utils
pipewire
pipewire-pulse
wireplumber
bluez
bluetooth
openssh-server
EOF
    fi
fi

# Build the rootfs
lb build

set -eE 

# =========================================================
# Unified post-build configuration
# - Set root password to 'root'
# - Enable root SSH with password authentication
# =========================================================
echo "Setting root password to 'root' and enabling root SSH..."

# 设置 root:root
echo 'root:root' | chroot chroot chpasswd

# 允许 root 密码 SSH 登录
chroot chroot sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
chroot chroot sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 确保 SSH 服务开机自启
chroot chroot systemctl enable ssh

# Tar the entire rootfs
echo "Listing chroot/ directory before tarring:"
ls -l chroot/

(cd chroot/ &&  tar -p -c --sort=name --xattrs ./*) | xz -3 -T0 > "ubuntu-${RELASE_VERSION}-${SUITE}-${FLAVOR}-arm64.rootfs.tar.xz"

# 检查当前目录下的文件
echo "Listing current directory after tarring:"
ls -l

#将rootfs移动到上级目录
mv "ubuntu-${RELASE_VERSION}-${SUITE}-${FLAVOR}-arm64.rootfs.tar.xz" ../

# 再次检查文件是否存在于目标目录
echo "Listing parent directory after moving the file:"
ls -l ..
