#!/bin/bash
# Download everything the xun port needs but does not keep in the repository.
set -eu
ROOT=$(cd "$(dirname "$0")" && pwd)
SRC=$ROOT/src
DL=$ROOT/downloads
mkdir -p "$SRC/patches" "$DL" "$ROOT/tools/bin" "$ROOT/tapas-images" \
	"$ROOT/rootfs-work"

KERNEL=7.2.1
KERNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/kernel/v7.x/linux-$KERNEL.tar.xz"
SM6225_URL="https://gitlab.postmarketos.org/sm6225-mainline/kernels/linux-v.$KERNEL"
ALPINE_URL="https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable"

SM6225_COMMITS="
650f459de5b9eb6f4f73728fd935d34677074965
8b6545f79b5ff3e589436c0746fc3014739dc12c
f5a976a8334c7563137352eaafe8d49a2a3b8c6a
e127de2a6297931b1abce1fb5b13a415163c325e
"

TAPAS_REPO=https://github.com/Sype0/pmos-tapas.git
TAPAS_REV=5dee84cc5d7939a1042cf9daf2a21e67ab5c3579
TAPAS_IMAGE_URL=https://github.com/Sype0/pmos-tapas/releases/download/latest/boot-tapas-safe.img

PANELGEN_REPO=https://github.com/msm8916-mainline/linux-mdss-dsi-panel-driver-generator.git
PANELGEN_REV=28c4df25628f6241ce925af15637a443ea2b3bb5

AUDIOREACH_REPO=https://github.com/linux-msm/audioreach-topology.git
AUDIOREACH_REV=d6bb205aca5f4b8fa6b2f44cf8b5f6a081cbf037

FTP8203_REPO=https://github.com/RigoLigoRLC/unixnu-nativefocaltechtouch.git

SPES_FW_REPO=https://gitlab.postmarketos.org/sm6225-mainline/firmwares/firmware-xiaomi-spes.git
SPES_FW_SUBDIR=qcom/sm6225/XIAOMI/SPES

MINI_URL="https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.0-aarch64.tar.gz"

fetch() {
	url=$1
	file=$2
	if [ -s "$file" ]; then
		return 0
	fi
	echo "fetch $url"
	curl -fL --retry 5 --retry-delay 3 -o "$file" "$url"
}

fetch "$KERNEL_URL" "$SRC/linux-$KERNEL.tar.xz"

for sha in $SM6225_COMMITS; do
	short=${sha:0:8}
	fetch "$SM6225_URL/-/commit/$sha.patch" "$SRC/patches/$short.patch"
done

if [ ! -f "$ROOT/tapas-bringup/config/base.config" ]; then
	find "$ROOT/tapas-bringup" -mindepth 1 -delete 2>/dev/null || true
	git clone "$TAPAS_REPO" "$ROOT/tapas-bringup"
	git -C "$ROOT/tapas-bringup" checkout -q "$TAPAS_REV"
fi
fetch "$TAPAS_IMAGE_URL" "$ROOT/tapas-images/boot-tapas-safe.img"

[ -d "$DL/panel-generator" ] ||
	git clone "$PANELGEN_REPO" "$DL/panel-generator"
git -C "$DL/panel-generator" checkout -q "$PANELGEN_REV"
[ -d "$DL/audioreach-topology" ] ||
	git clone "$AUDIOREACH_REPO" "$DL/audioreach-topology"
git -C "$DL/audioreach-topology" checkout -q "$AUDIOREACH_REV"
[ -d "$DL/ft8203-reference" ] ||
	git clone "$FTP8203_REPO" "$DL/ft8203-reference" ||
	echo "warning: ft8203-reference unavailable, skipping"

FWDIR=$ROOT/firmware/qcom
mkdir -p "$FWDIR"
if [ ! -s "$FWDIR/a630_sqe.fw" ]; then
	rm -rf "$DL/firmware-xiaomi-spes"
	git clone --depth 1 "$SPES_FW_REPO" "$DL/firmware-xiaomi-spes"
	cp "$DL/firmware-xiaomi-spes/$SPES_FW_SUBDIR"/a610_zap.* "$FWDIR/"
	cp "$DL/firmware-xiaomi-spes/$SPES_FW_SUBDIR"/a630_sqe.fw "$FWDIR/"
fi

# Build our own BusyBox: Alpine's package omits applets required by tapas init.
BUSYBOX_VERSION=1.37.0
fetch "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2" \
	"$SRC/busybox-$BUSYBOX_VERSION.tar.bz2"
rm -f "$ROOT/tools/bin/busybox.static"

alpine_pkg() {
	local name=$1
	local arch=${2:-x86_64}
	curl -s "$ALPINE_URL/main/$arch/" | tr '"' '\n' | grep -E "^${name}-[0-9].*\.apk$" | head -n1
}

fetch "$ALPINE_URL/main/x86_64/$(alpine_pkg apk-tools-static)" \
	"$ROOT/rootfs-work/apk-tools.apk"

if [ ! -s "$ROOT/rootfs-work/mini.tar.gz" ] || ! tar -tzf "$ROOT/rootfs-work/mini.tar.gz" >/dev/null 2>&1; then
	rm -f "$ROOT/rootfs-work/mini.tar.gz"
	fetch "$MINI_URL" "$ROOT/rootfs-work/mini.tar.gz"
	tar -tzf "$ROOT/rootfs-work/mini.tar.gz" >/dev/null
fi

echo "sources are in place"
