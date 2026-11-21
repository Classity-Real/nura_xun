#!/bin/bash
# Build the ext2/3/4 recovery utilities as static AArch64 binaries for xun's
# early initramfs. They must work before Alpine (and apk) is mounted.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
TOOLS=$ROOT/tools
DL=$ROOT/downloads
WORK=$TOOLS/e2fsprogs-build
STAGE=$WORK/stage
OUT=$TOOLS/e2fsprogs-initramfs

VER=1.47.4
ARCHIVE=$DL/e2fsprogs-$VER.tar.xz
URL=https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$VER/e2fsprogs-$VER.tar.xz
SHA256=fd5bf388cbdbe006a3d3b318d983b2948382440acc85a87f1e7d108653e8db0b

mkdir -p "$DL" "$TOOLS"

if [ -x "$OUT/e2fsck" ] && [ -x "$OUT/tune2fs" ] &&
   [ -x "$OUT/dumpe2fs" ] && [ -x "$OUT/debugfs" ]; then
    echo "static e2fsprogs initramfs tools already built"
    exit 0
fi

if [ ! -s "$ARCHIVE" ]; then
    echo "fetch e2fsprogs $VER"
    curl -fL --retry 5 --retry-delay 3 -o "$ARCHIVE.tmp" "$URL"
    mv "$ARCHIVE.tmp" "$ARCHIVE"
fi
echo "$SHA256  $ARCHIVE" | sha256sum -c -

SRC=$WORK/src
rm -rf "$SRC" "$STAGE" "$OUT"
mkdir -p "$SRC" "$STAGE" "$OUT"
tar -xJf "$ARCHIVE" -C "$SRC" --strip-components=1

cd "$SRC"
BUILD_TRIPLET=$(gcc -dumpmachine)
echo "configuring static AArch64 e2fsprogs (build=$BUILD_TRIPLET)"
CC=aarch64-linux-gnu-gcc \
CFLAGS="-O2" \
LDFLAGS="-static" \
./configure \
    --build="$BUILD_TRIPLET" \
    --host=aarch64-linux-gnu \
    --prefix=/usr \
    --bindir=/sbin \
    --sbindir=/sbin \
    --disable-nls \
    --disable-elf-shlibs \
    --disable-uuidd \
    --disable-fuse2fs

make -j"$(nproc)"
make install DESTDIR="$STAGE"

# Keep every executable e2fsprogs installs, including the mkfs/fsck aliases.
for dir in sbin bin usr/sbin usr/bin; do
    [ -d "$STAGE/$dir" ] || continue
    for src in "$STAGE/$dir"/*; do
        [ -e "$src" ] || [ -L "$src" ] || continue
        name=${src##*/}
        if [ -L "$src" ]; then
            ln -sfn "$(readlink "$src")" "$OUT/$name"
        elif [ -f "$src" ] && [ -x "$src" ]; then
            cp "$src" "$OUT/$name"
            chmod 755 "$OUT/$name"
        fi
    done
done

# mke2fs reads this configuration for filesystem defaults.
if [ -f "$STAGE/etc/mke2fs.conf" ]; then
    cp "$STAGE/etc/mke2fs.conf" "$OUT/mke2fs.conf"
elif [ -f "$SRC/misc/mke2fs.conf" ]; then
    cp "$SRC/misc/mke2fs.conf" "$OUT/mke2fs.conf"
else
    echo "e2fsprogs did not provide mke2fs.conf" >&2
    exit 1
fi

for tool in e2fsck mke2fs tune2fs dumpe2fs debugfs resize2fs badblocks e2image; do
    [ -x "$OUT/$tool" ] || {
        echo "required e2fsprogs utility missing: $tool" >&2
        exit 1
    }
done

# Fail the build if any executable is not AArch64 or still needs a dynamic
# loader. The initramfs intentionally has no musl/glibc runtime.
for bin in "$OUT"/*; do
    [ -f "$bin" ] || continue
    file "$bin" | grep -q 'ARM aarch64' || {
        echo "wrong architecture: $bin: $(file "$bin")" >&2
        exit 1
    }
    if aarch64-linux-gnu-readelf -l "$bin" | grep -q 'INTERP'; then
        echo "not a static executable: $bin" >&2
        exit 1
    fi
done

echo "static AArch64 e2fsprogs tools ready:"
ls -lh "$OUT"
