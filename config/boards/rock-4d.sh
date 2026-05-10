# shellcheck shell=bash

export BOARD_NAME="Radxa ROCK 4D"
export BOARD_MAKER="Radxa"
export BOARD_SOC="Rockchip RK3576"
export BOARD_CPU="ARM Cortex A72 / A53"
export UBOOT_PACKAGE="u-boot-radxa-202601-rk3576"
export UBOOT_RULES_TARGET="rock-4d-rk3576"
export UBOOT_RULES_TARGET_EXTRA="rock-4d-spi-rk3576"
export COMPATIBLE_SUITES=("noble" "resolute")
export COMPATIBLE_FLAVORS=("server" "desktop")

function config_image_hook__rock-5d() {
    local rootfs="$1"

    # Kernel modules to blacklist
    echo "blacklist panfrost" > "${rootfs}/etc/modprobe.d/panfrost.conf"

    return 0
}
