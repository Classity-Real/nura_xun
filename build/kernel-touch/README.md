# FT8203 touch

`ft8203-spi.c` is copied into the kernel tree by `build-xun.sh`.

If the driver still contains the landscape in-driver rotation
(`1919 - y`), `build-xun.sh` applies
`build/patches/ft8203-no-double-rotate.patch` so coordinates stay in
native 1200x1920 panel space. DRM `panel_orientation=left_side_up`
then lets Mutter/libinput map touch correctly once.
