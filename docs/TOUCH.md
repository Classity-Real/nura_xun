# FT8203 touch on xun (landscape chassis)

There is no third-party FT8203 SPI driver for this panel. We keep the
in-tree `build/kernel-touch/ft8203-spi.c` and change only the coordinate map.

## Current kernel map (CCW)

Panel native space is 1200x1920. Driver reports landscape 1920x1200 as:

```
X = portrait_Y
Y = 1199 - portrait_X
```

## On-device tuning (no rebuild)

If the pointer still misses, from a shell on the tablet:

```sh
# list the device name
libinput list-devices | grep -A2 -i focal

# try matrices one at a time
RULE=/etc/udev/rules.d/99-ft8203-touch.rules
# example: 90 CCW
cat >$RULE <<'EOF'
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="Focaltech FT8203*", \
  ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"
EOF
udevadm control --reload-rules
udevadm trigger
# log out/in or restart gdm if the matrix does not apply live
```

Useful matrices:

| Effect | Matrix |
|--------|--------|
| identity | `1 0 0 0 1 0` |
| swap axes | `0 1 0 1 0 0` |
| invert X | `-1 0 1 0 1 0` |
| invert Y | `1 0 0 0 -1 1` |
| 90 CW | `0 1 0 -1 0 1` |
| 90 CCW | `0 -1 1 1 0 0` |
| 180 | `-1 0 1 0 -1 1` |

## Why not another driver?

Public FocalTech trees (FT5x26, vendor FTS) are I2C-oriented and do not
match the FT8203 SPI protocol + firmware load path used on xun. The
bring-up driver already talks to the chip; the remaining problem is
only axis mapping relative to `panel_orientation=left_side_up`.
