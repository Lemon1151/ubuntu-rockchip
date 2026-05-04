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

ROOTFS="ubuntu-${RELASE_VERSION}-${SUITE}-${FLAVOR}-arm64.rootfs.tar.xz"

if [[ -f ${ROOTFS} ]]; then
    exit 0
fi

# =========================================================
# 下载 ubuntu-base（固定路径，自动取最新点发布）
# =========================================================
BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${RELASE_VERSION}/release"
CHECKSUM="SHA256SUMS"

if [[ ! -f ${CHECKSUM} ]]; then
    echo "Downloading ${CHECKSUM}..."
    wget -O "${CHECKSUM}" "${BASE_URL}/${CHECKSUM}"
fi

# 自动匹配 ubuntu-base-xx.xx.xx-base-arm64.tar.gz 并取最新版
BASE_TAR=$(grep -oP 'ubuntu-base-\d+\.\d+(\.\d+)?-base-arm64\.tar\.gz' "${CHECKSUM}" | sort -V | tail -n1)

if [[ -z ${BASE_TAR} ]]; then
    echo "Error: cannot find ubuntu-base arm64 tarball"
    exit 1
fi

echo "Selected ubuntu-base: ${BASE_TAR}"

if [[ ! -f ${BASE_TAR} ]]; then
    wget -O "${BASE_TAR}" "${BASE_URL}/${BASE_TAR}"
fi

sha256sum -c <<< "$(grep "${BASE_TAR}" "${CHECKSUM}")"

# =========================================================
# 解压 ubuntu-base
# =========================================================
CHROOT_DIR=chroot
umount -lf ${CHROOT_DIR}/dev/pts 2>/dev/null || true
umount -lf ${CHROOT_DIR}/dev 2>/dev/null || true
umount -lf ${CHROOT_DIR}/sys 2>/dev/null || true
umount -lf ${CHROOT_DIR}/proc 2>/dev/null || true
rm -rf ${CHROOT_DIR}
mkdir -p ${CHROOT_DIR}

echo "Extracting ubuntu-base..."
tar -xpf "${BASE_TAR}" -C "${CHROOT_DIR}"

# =========================================================
# 准备 chroot 环境
# =========================================================
mount -t proc proc ${CHROOT_DIR}/proc
mount -t sysfs sys ${CHROOT_DIR}/sys
mount -o bind /dev ${CHROOT_DIR}/dev
mount -o bind /dev/pts ${CHROOT_DIR}/dev/pts
cp /etc/resolv.conf ${CHROOT_DIR}/etc/resolv.conf

set +e

cat > ${CHROOT_DIR}/etc/apt/sources.list << EOF
deb http://ports.ubuntu.com ${SUITE} main restricted universe multiverse
deb http://ports.ubuntu.com ${SUITE}-security main restricted universe multiverse
deb http://ports.ubuntu.com ${SUITE}-updates main restricted universe multiverse
EOF

chroot ${CHROOT_DIR} apt update && apt upgrade -y

# =========================================================
# 安装核心包
# =========================================================
if [ "${PROJECT}" = "ubuntu" ]; then
    PKGS="
      ubuntu-desktop
      localechooser-data
      firefox
      sudo
      nano
      vim
      htop
      curl
      wget
      git
      fastfetch
      zstd
      unzip
      zip
    "
else
    PKGS="
      ubuntu-server
      localechooser-data
      sudo
      nano
      vim
      htop
      kmod
      kbd
      tzdata
      unzip
      zip
      curl
      wget
      git
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
    "
fi

# =========================================================
# 启用必备服务（chroot 必须手动开启）
# =========================================================
chroot "${CHROOT_DIR}" systemctl enable ssh
chroot "${CHROOT_DIR}" systemctl enable systemd-resolved

if [ "${PROJECT}" = "ubuntu" ]; then
    chroot "${CHROOT_DIR}" systemctl enable NetworkManager
else
    chroot "${CHROOT_DIR}" systemctl enable systemd-networkd
fi

# =========================================================
# 仅服务器版：netplan 自动网络配置
# =========================================================
if [ "${PROJECT}" != "ubuntu" ]; then
cat > "${CHROOT_DIR}/etc/netplan/00-auto-eth.yaml" <<EOF
network:
  renderer: networkd
  ethernets:
    all-usb-eth:
      match:
        name: en*
      dhcp4: true
      dhcp6: true
      optional: true
  version: 2
EOF
chmod 600 "${CHROOT_DIR}/etc/netplan/00-auto-eth.yaml"
fi

# =========================================================
# 安装 linux-firmware（手动）
# =========================================================
FIRMWARE_TARGET="${CHROOT_DIR}/usr/lib/firmware"

echo "Cleaning default firmware..."
rm -rf "${FIRMWARE_TARGET}"
mkdir -p "${FIRMWARE_TARGET}"

# Armbian 固件
echo "Installing Armbian firmware..."
wget -O armbian-fw.tar.gz https://github.com/armbian/firmware/archive/refs/heads/master.tar.gz
tar -xf armbian-fw.tar.gz
cp -Rf firmware-master/* "${FIRMWARE_TARGET}/"
rm -rf firmware-master armbian-fw.tar.gz

# 官方 linux-firmware
echo "Installing official linux-firmware..."
wget -O linux-fw.tar.gz https://gitlab.com/kernel-firmware/linux-firmware/-/archive/main/linux-firmware-main.tar.gz
tar -xf linux-fw.tar.gz
cd linux-firmware-main

# 删除 x86 独显 / 计算卡，缩小rootfs体积
rm -rf nvidia amdgpu radeon amdnpu amdtee i915
rm -rf intel/avs intel/catpt intel/dsp* intel/fw_sst* intel/ice intel/ipu intel/ish intel/qat intel/vpu intel/vsc
cd ..
cp -Rf linux-firmware-main/* "${FIRMWARE_TARGET}/"
rm -rf linux-firmware-main linux-fw.tar.gz

echo "Fix firmware permissions..."
chown -R root:root "${FIRMWARE_TARGET}"
chmod -R 755 "${FIRMWARE_TARGET}"

# =======锁住firmware，防止执行apt更新覆盖=======
echo "Locking linux-firmware..."
chroot ${CHROOT_DIR} apt-mark hold linux-firmware 2>/dev/null || true

# =========================================================
# 主机名 / hosts
# =========================================================
echo "${BOARD}" > ${CHROOT_DIR}/etc/hostname
cat > ${CHROOT_DIR}/etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   ${BOARD}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# =========================================================
# 增强：root 串口登录
# =========================================================
echo "Adding securetty for root login..."
cat > ${CHROOT_DIR}/etc/securetty << EOF
ttyS0
ttyS1
ttyS2
ttyS3
ttyAMA0
ttyAML0
tty1
tty2
tty3
EOF

# =========================================================
# 用户 / 时区 / SSH
# =========================================================
chroot ${CHROOT_DIR} useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,dialout ubuntu
echo 'ubuntu:ubuntu' | chroot ${CHROOT_DIR} chpasswd
echo 'root:root' | chroot ${CHROOT_DIR} chpasswd

chroot ${CHROOT_DIR} ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > ${CHROOT_DIR}/etc/timezone

chroot ${CHROOT_DIR} sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
chroot ${CHROOT_DIR} sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
chroot ${CHROOT_DIR} systemctl enable ssh

# =========================================================
# 清理
# =========================================================
chroot ${CHROOT_DIR} apt clean
rm -rf ${CHROOT_DIR}/var/lib/apt/lists/*
rm -rf ${CHROOT_DIR}/tmp/*
rm -f ${CHROOT_DIR}/etc/resolv.conf

set -eE

# =========================================================
# 卸载
# =========================================================
umount ${CHROOT_DIR}/dev/pts
umount ${CHROOT_DIR}/dev
umount ${CHROOT_DIR}/sys
umount ${CHROOT_DIR}/proc

# =========================================================
# 打包 rootfs
# =========================================================
echo "Listing chroot/ directory before tarring:"
ls -l ${CHROOT_DIR}/

(cd ${CHROOT_DIR}/ && tar -p -c --sort=name --xattrs ./*) | \
    xz -3 -T0 > "${ROOTFS}"

echo "Listing current directory after tarring:"
ls -l

echo "Listing parent directory after moving the file:"
