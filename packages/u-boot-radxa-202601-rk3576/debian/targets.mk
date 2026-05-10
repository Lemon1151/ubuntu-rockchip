# Target platforms supported by u-boot.
# debian/rules includes this Makefile snippet.

u-boot-rockchip_platforms += rock-4d-rk3576
rock-4d-rk3576_ddr := rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.03.bin
rock-4d-rk3576_bl31 := rk3576_bl31_v1.04.elf
rock-4d-rk3576_bl32 := rk3576_bl32_v1.01.bin
rock-4d-rk3576_pkg := rock-4d

u-boot-rockchip_platforms += rock-4d-spi-rk3576
rock-4d-spi-rk3576_ddr := rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.03.bin
rock-4d-spi-rk3576_bl31 := rk3576_bl31_v1.04.elf
rock-4d-spi-rk3576_bl32 := rk3576_bl32_v1.01.bin
rock-4d-spi-rk3576_pkg := rock-4d-spi
