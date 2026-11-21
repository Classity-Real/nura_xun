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

# Keep the external initramfs source pinned, but locally switch its USB
# network function from ECM to CDC-NCM for Windows 11. ACM serial is unchanged.
TAPAS_INIT=$ROOT/tapas-bringup/initramfs/init
if ! grep -q 'functions/ncm.usb0' "$TAPAS_INIT"; then
	patch -d "$ROOT/tapas-bringup" -p1 -s -N <"$ROOT/patches/tapas-ncm.patch" || {
		echo "failed to apply the xun CDC-NCM initramfs patch" >&2
		exit 1
	}
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

alpine_pkg() {
	local name=$1
	local arch=${2:-x86_64}
	curl -s "$ALPINE_URL/main/$arch/" | tr '"' '\n' | grep -E "^${name}-[0-9].*\.apk$" | head -n1
}

# This busybox.static ends up as /bin/busybox inside the DEVICE's initramfs
# (build-xun.sh's initramfs.list), executed by the aarch64 kernel on the
# tablet -- it must be an aarch64 binary, not whatever the build host is.
# An x86_64 busybox here makes the kernel fail to exec /init with ENOEXEC
# (error -8) since /init's shebang interpreter is unusable.
#
# Alpine's busybox-static package will NOT do: it is built without server
# applets (no telnetd binary at all, anywhere in Alpine's busybox packages;
# udhcpd lives only in the separate busybox-extras multi-call binary). The
# tapas-bringup init script calls both directly for the USB bring-up shell
# (tapas: network on usb0: telnet 172.16.42.1), and silently gets
# "telnetd: not found" with nothing listening if they are missing -- the
# upstream tapas project's own build.sh in fact hard-requires a caller-
# supplied busybox with exactly this applet list, for exactly this reason.
# So build our own, statically, from upstream source, with those applets
# forced on regardless of the version's defconfig defaults.
BUSYBOX_VER=1.36.1
BUSYBOX_URL=https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2
# Applets the tapas-bringup init script calls directly (see its build.sh).
BUSYBOX_APPLETS="telnetd udhcpd ifconfig devmem setsid cttyhack dd od tr
losetup mdev switch_root mount sh sleep seq pkill kill mkdir cat grep sed
ls chmod printf"

busybox_ok() {
	[ -x "$ROOT/tools/bin/busybox.static" ] || return 1
	file "$ROOT/tools/bin/busybox.static" 2>/dev/null | grep -qi aarch64 || return 1
	for applet in $BUSYBOX_APPLETS; do
		# -n 2: GNU strings' default minimum (4) drops short applet names
		# like ls/dd/tr/sh/od/cat/sed, which would otherwise always "fail"
		# this check even on a correctly built binary.
		strings -n 2 "$ROOT/tools/bin/busybox.static" 2>/dev/null |
			grep -qx "$applet" || return 1
	done
}

if ! busybox_ok; then
	echo "building a static aarch64 busybox (with telnetd/udhcpd) from source"
	rm -f "$ROOT/tools/bin/busybox.static"
	BBSRC=$DL/busybox-$BUSYBOX_VER
	if [ ! -d "$BBSRC" ]; then
		fetch "$BUSYBOX_URL" "$DL/busybox-$BUSYBOX_VER.tar.bz2"
		rm -rf "$BBSRC"
		mkdir -p "$BBSRC"
		tar -xjf "$DL/busybox-$BUSYBOX_VER.tar.bz2" -C "$BBSRC" --strip-components=1
	fi
	make -C "$BBSRC" CROSS_COMPILE=aarch64-linux-gnu- defconfig
	# busybox has no scripts/kconfig/merge_config.sh (unlike the kernel) and
	# no "olddefconfig" target, so merge the fragment by hand: drop any
	# conflicting line for each symbol we set, then append ours, and
	# finalize with "silentoldconfig" (busybox's non-interactive oldconfig).
	# CONFIG_TC is explicitly off: the tc applet's CBQ qdisc structures
	# were removed from upstream Linux headers, so it fails to build
	# against this cross-sysroot's (newer) kernel headers, and we don't
	# need it for the bring-up shell anyway.
	cat >"$BBSRC/busybox-xun.config" <<'EOF4'
CONFIG_STATIC=y
CONFIG_TELNETD=y
CONFIG_FEATURE_TELNETD_STANDALONE=y
CONFIG_UDHCPD=y
# CONFIG_TC is not set
EOF4
	grep -E '^CONFIG_[A-Za-z0-9_]+=|^# CONFIG_[A-Za-z0-9_]+ is not set' \
		"$BBSRC/busybox-xun.config" |
		sed -E 's/^# //; s/ is not set$//; s/=.*//' |
		while IFS= read -r key; do
			sed -i -E "/^${key}=/d; /^# ${key} is not set\$/d" "$BBSRC/.config"
		done
	cat "$BBSRC/busybox-xun.config" >>"$BBSRC/.config"
	make -C "$BBSRC" CROSS_COMPILE=aarch64-linux-gnu- silentoldconfig
	make -C "$BBSRC" CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" busybox
	mkdir -p "$ROOT/tools/bin"
	cp "$BBSRC/busybox" "$ROOT/tools/bin/busybox.static"
	chmod 755 "$ROOT/tools/bin/busybox.static"
	busybox_ok || {
		echo "built busybox.static is missing a required applet or the" \
			"wrong architecture -- $(file "$ROOT/tools/bin/busybox.static")" >&2
		exit 1
	}
fi
fetch "$ALPINE_URL/main/x86_64/$(alpine_pkg apk-tools-static)" \
	"$ROOT/rootfs-work/apk-tools.apk"

if [ ! -s "$ROOT/rootfs-work/mini.tar.gz" ] || ! tar -tzf "$ROOT/rootfs-work/mini.tar.gz" >/dev/null 2>&1; then
	rm -f "$ROOT/rootfs-work/mini.tar.gz"
	fetch "$MINI_URL" "$ROOT/rootfs-work/mini.tar.gz"
	tar -tzf "$ROOT/rootfs-work/mini.tar.gz" >/dev/null
fi

echo "sources are in place"
