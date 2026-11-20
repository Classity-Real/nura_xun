#!/bin/bash
# Build static aarch64 BusyBox with every applet required by tapas init.
set -eu
ROOT=$(cd "$(dirname "$0")" && pwd)
VERSION=1.37.0
ARCHIVE="$ROOT/src/busybox-$VERSION.tar.bz2"
SRC="$ROOT/work/busybox-$VERSION"
OUT="$ROOT/tools/bin/busybox.static"

[ -s "$ARCHIVE" ] || { echo "missing $ARCHIVE: run ./fetch-sources.sh first" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required to build static aarch64 BusyBox" >&2; exit 1; }
mkdir -p "$ROOT/work" "$ROOT/tools/bin"
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xjf "$ARCHIVE" -C "$ROOT/work"
docker run --rm --platform linux/arm64 \
	-v "$ROOT:/src" -w "/src/work/busybox-$VERSION" alpine:3.24 sh -ec '
	apk add --no-cache build-base linux-headers
	make defconfig
	for applet in STATIC TELNETD UDHCPD IFCONFIG DEVMEM SETSID CTTYHACK DD OD TR LOSETUP MDEV SWITCH_ROOT; do
		sed -i "s/^# CONFIG_${applet} is not set/CONFIG_${applet}=y/" .config
	done
	make oldconfig </dev/null
	make -j"$(getconf _NPROCESSORS_ONLN)"
	install -D -m 755 busybox /src/tools/bin/busybox.static
'
chmod 755 "$OUT"
file "$OUT" | grep -Eqi "ARM aarch64.*static(ally|-pie)" || { echo "BusyBox is not a statically linked aarch64 binary: $(file "$OUT")" >&2; exit 1; }
for applet in telnetd udhcpd ifconfig devmem setsid cttyhack dd od tr losetup mdev switch_root; do
	"$OUT" --list | grep -qx "$applet" || { echo "built BusyBox is missing required applet: $applet" >&2; exit 1; }
done
echo "static aarch64 BusyBox ready: $OUT"
