#!/bin/sh
# Build the Alpine rootfs for the xun install image. Runs as root inside an
# aarch64 Alpine container (build/make-install-image.sh starts it), so package
# scripts execute natively instead of failing with Exec format errors.
set -eu

BASE=${BASE:-/build}
ROOT=$BASE/rootfs-install/rootfs
WORK=$BASE/rootfs-install
HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}

# Regional mirrors occasionally serve an APKINDEX that's ahead of what's
# actually been synced to disk yet, so a specific package 404s even though
# apk's own index says it should be there (seen: libxml2-2.13.9-r5, HTTP 404
# on the Tsinghua mirror, consistently across multiple CI runs 30+ minutes
# apart -- a sustained mirror-side inconsistency, not a few-second blip that
# retrying the same mirror rides out). Since libxml2 is linked by most of the
# GNOME stack, that one miss cascades into unrelated-looking failures later
# in the same run (appstream's post-install immediately failing to relocate
# libxml2 symbols, then much later shared-mime-info's trigger exiting 127
# because it needs libxml2/xmllint too) -- one fetch failure, many confusing
# symptoms.
#
# apk_retry (below) rides out a short blip by retrying the same mirror a few
# times; the "for m in $MIRRORS" loops at each call site fall back to a
# *different* mirror once one keeps failing, since a sustained inconsistency
# on one mirror won't resolve by asking it again. If the caller sets MIRROR
# explicitly, only that one is used (no fallback list) so a deliberate
# override is still respected.
if [ -n "${MIRROR:-}" ]; then
	MIRRORS=$MIRROR
else
	MIRRORS="
https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable
https://mirrors.aliyun.com/alpine/latest-stable
https://mirror.nju.edu.cn/alpine/latest-stable
https://dl-cdn.alpinelinux.org/alpine/latest-stable
"
fi

apk_retry() {
	attempt=1
	max=3
	while ! "$@"; do
		if [ "$attempt" -ge "$max" ]; then
			return 1
		fi
		echo "apk command failed (attempt $attempt/$max) on this mirror, retrying in 15s: $*" >&2
		sleep 15
		attempt=$((attempt + 1))
	done
}

# Regional mirrors are tried first; dl-cdn is slow or unreachable from here,
# so it's last in the fallback list. openssl is for the password hash,
# e2fsprogs builds the image.
#
# --repository has to precede the "add" applet name for apk's option parser
# (it's a global option, not an "add"-specific one), so each call site below
# builds its own command with --repository in the right spot rather than
# sharing one generic helper that would have to append flags at the end.
ok=
for m in $MIRRORS; do
	printf '%s\n' "$m/main" "$m/community" >/etc/apk/repositories
	if apk_retry apk --repository "$m/main" --repository "$m/community" \
		add --no-cache openssl e2fsprogs zstd openssh-keygen >/dev/null; then
		ok=1
		break
	fi
	echo "mirror $m still failing after retries, trying next mirror" >&2
done
[ -n "$ok" ] || { echo "all mirrors failed for host tool install" >&2; exit 1; }

rm -rf "$ROOT"
mkdir -p "$ROOT" "$WORK/apk-cache"
tar -xzf "$BASE/rootfs-work/mini.tar.gz" -C "$ROOT"

# Install into the target root. `apk --root` runs the package scripts inside
# the target (aarch64 binaries through binfmt), so triggers compile schemas,
# icon caches and font caches for us.
PKGS=$( { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$BASE/install-packages.txt"
	sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$BASE/lang-packages.txt"; } |
	grep -v '^$' | sort -u | tr '\n' ' ')
ok=
for m in $MIRRORS; do
	printf '%s\n' "$m/main" "$m/community" >"$ROOT/etc/apk/repositories"
	# shellcheck disable=SC2086
	if apk_retry apk --root "$ROOT" --arch aarch64 --allow-untrusted \
		--cache-dir "$WORK/apk-cache" \
		--repository "$m/main" --repository "$m/community" \
		add $PKGS; then
		ok=1
		break
	fi
	echo "mirror $m still failing after retries, trying next mirror" >&2
done
[ -n "$ok" ] || { echo "all mirrors failed for target rootfs install" >&2; exit 1; }
rm -rf "$ROOT/var/cache/apk"

# --- board files ---------------------------------------------------------
# The bring-up rootfs renamed the distribution session binaries and put
# wrappers in front of them to select the English locale and log the session.
for b in gnome-session gnome-shell; do
	if [ -f "$ROOT/usr/bin/$b" ] && [ ! -e "$ROOT/usr/bin/$b.real" ]; then
		mv "$ROOT/usr/bin/$b" "$ROOT/usr/bin/$b.real"
	fi
done
cp -a "$BASE/device/." "$ROOT/"
chmod 755 "$ROOT"/etc/local.d/*.start "$ROOT"/etc/local.d/*.stop \
	"$ROOT"/usr/local/bin/time-sync \
	"$ROOT"/usr/libexec/elogind/system-sleep/*.sh

mkdir -p "$ROOT/usr/share/alsa/ucm2"
cp -a "$BASE/ucm2/." "$ROOT/usr/share/alsa/ucm2/"

# Fetch the two FT8203 firmware images published in release focal1.
# Pin their SHA-256 hashes so a changed or corrupted release asset cannot
# silently enter the install image.
mkdir -p "$BASE/firmware"
fetch_touch_firmware() {
	name=$1
	sha=$2
	url="https://github.com/Classity-Real/nura_xun/releases/download/focal1/$name"
	tmp="$BASE/firmware/$name.download"
	wget -q -O "$tmp" "$url"
	echo "$sha  $tmp" | sha256sum -c -
	mv "$tmp" "$BASE/firmware/$name"
}
fetch_touch_firmware focaltech_ts_fw_boe_ft8203.bin 3a528016614ddfaa33c0e38fb2b2c91aebed8711f4a9dd4f31f333c8b8b3162e
fetch_touch_firmware focaltech_ts_fw_huaxing_ft8203.bin 0a7d49735fca986be6263134c6c4891075da9add347a2c6008eb8433cd97fa38

mkdir -p "$ROOT/lib/firmware"
cp -a "$BASE/firmware/." "$ROOT/lib/firmware/"

# cp -a preserves the source owner (the build user); the installed files
# belong to root except for the home directory and the private SSH keys.
# Only the copied files are touched here: a recursive chown of /usr/libexec
# would clear the setuid bit on dbus-daemon-launch-helper.
chown -R root:root "$ROOT/etc/local.d" "$ROOT/etc/dconf" \
	"$ROOT/etc/gdm" "$ROOT/etc/NetworkManager" "$ROOT/etc/bluetooth" \
	"$ROOT/etc/xdg" "$ROOT/etc/greetd" "$ROOT/etc/dnsmasq-xun.conf" \
	"$ROOT/usr/local" "$ROOT/usr/libexec/elogind" \
	"$ROOT/usr/share/alsa/ucm2" "$ROOT/lib/firmware" \
	"$ROOT/usr/bin/gnome-session" "$ROOT/usr/bin/gnome-shell"
# cp -a also copied the directory attributes of build/device/etc and
# build/device/usr onto /etc and /usr themselves.
chown root:root "$ROOT/etc" "$ROOT/usr" "$ROOT/usr/bin" "$ROOT/usr/local"

rm -f "$ROOT/sbin/init"
install -m 755 "$BASE/rootfs-init.sh" "$ROOT/sbin/init"

# --- system configuration ------------------------------------------------
echo xun >"$ROOT/etc/hostname"
cat >"$ROOT/etc/hosts" <<'HOSTS'
127.0.0.1 localhost xun
::1 localhost
HOSTS
printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' >"$ROOT/etc/resolv.conf"
cat >"$ROOT/etc/fstab" <<'FSTAB'
# Persistent root and user data live on the userdata ext4 partition.
# /tmp, /var/tmp, /run and /dev/shm are mounted as volatile tmpfs.
FSTAB
cat >"$ROOT/etc/locale.conf" <<'LOCALE'
LANG=en_US.UTF-8
LANGUAGE=en
LOCALE
cat >"$ROOT/etc/environment" <<'ENV'
LANG=en_US.UTF-8
LANGUAGE=en
ENV
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOT/etc/localtime"
echo Asia/Shanghai >"$ROOT/etc/timezone"

cat >"$ROOT/etc/inittab" <<'INITTAB'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
tty0::respawn:/sbin/getty -L 115200 tty0 vt100
ttyGS0::respawn:/sbin/getty -L 115200 ttyGS0 vt100
tty1::respawn:/sbin/agetty --autologin xun --noclear tty1 38400
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
INITTAB

# --- accounts ------------------------------------------------------------
HASH=$(openssl passwd -6 xun)
if ! grep -q '^xun:' "$ROOT/etc/passwd"; then
	echo 'xun:x:1000:1000::/home/xun:/bin/bash' >>"$ROOT/etc/passwd"
	echo 'xun:x:1000:' >>"$ROOT/etc/group"
	# pam_unix treats a zero last-change day as an expired password, which
	# makes GDM autologin fail; use day 1 of the epoch instead.
	echo "xun:$HASH:1:0:99999:7:::" >>"$ROOT/etc/shadow"
	echo 'xun:!::' >>"$ROOT/etc/gshadow"
	mkdir -p "$ROOT/home/xun"
	cp -a "$ROOT/etc/skel/." "$ROOT/home/xun/" 2>/dev/null || true
fi
sed -i "s|^root:[^:]*:[^:]*:|root:$HASH:1:|" "$ROOT/etc/shadow"
for g in wheel audio video input netdev plugdev render bluetooth; do
	grep -q "^$g:" "$ROOT/etc/group" || continue
	awk -F: -v g="$g" -v OFS=: '
		$1 == g {
			if ($4 == "") $4 = "xun"
			else if ($4 !~ /(^|,)xun(,|$)/) $4 = $4 ",xun"
		}
		{ print }
	' "$ROOT/etc/group" >"$ROOT/etc/group.new"
	mv "$ROOT/etc/group.new" "$ROOT/etc/group"
done
chown -R 1000:1000 "$ROOT/home/xun"
chmod 700 "$ROOT/root"
chmod 640 "$ROOT/etc/shadow" "$ROOT/etc/gshadow"

# GDM's home is not created by the package's OpenRC subpackage, and
# accounts-service wants its user database directory before GDM starts.
GDM_UID=$(awk -F: '$1 == "gdm" { print $3 }' "$ROOT/etc/passwd")
GDM_GID=$(awk -F: '$1 == "gdm" { print $4 }' "$ROOT/etc/passwd")
install -d -m 755 -o "${GDM_UID:-32}" -g "${GDM_GID:-32}" "$ROOT/var/lib/gdm"
install -d -m 775 "$ROOT/var/lib/AccountsService"
install -d -m 700 "$ROOT/var/lib/AccountsService/users"
cat >"$ROOT/var/lib/AccountsService/users/xun" <<'ACCOUNTS'
[User]
Session=
Icon=/home/xun/.face
SystemAccount=false
ACCOUNTS
chmod 600 "$ROOT/var/lib/AccountsService/users/xun"

# --- SSH access ----------------------------------------------------------
# Prefer build/ssh/xun_key.pub when present (local/developer builds).
# In CI that file is usually missing — generate a disposable keypair so the
# image still builds. Password auth remains enabled either way.
SSH_DIR=$BASE/ssh
mkdir -p "$SSH_DIR"
if [ ! -s "$SSH_DIR/xun_key.pub" ]; then
	echo "no $SSH_DIR/xun_key.pub — generating CI/dev key"
	ssh-keygen -t ed25519 -N '' -f "$SSH_DIR/xun_key" -C "xun-ci" >/dev/null
fi
install -d -m 700 "$ROOT/root/.ssh"
install -m 600 "$SSH_DIR/xun_key.pub" "$ROOT/root/.ssh/authorized_keys"
install -d -m 700 -o 1000 -g 1000 "$ROOT/home/xun/.ssh"
install -m 600 -o 1000 -g 1000 "$SSH_DIR/xun_key.pub" \
	"$ROOT/home/xun/.ssh/authorized_keys"

SSHD=$ROOT/etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD"
grep -q '^PermitRootLogin' "$SSHD" || echo 'PermitRootLogin prohibit-password' >>"$SSHD"
grep -q '^PubkeyAuthentication' "$SSHD" || echo 'PubkeyAuthentication yes' >>"$SSHD"
grep -q '^PasswordAuthentication' "$SSHD" || echo 'PasswordAuthentication yes' >>"$SSHD"

# --- boot services -------------------------------------------------------
# Keep the proven runlevel from the bring-up rootfs; the GDM start lives in
# local.d/50-gnome.start so it runs after dbus, elogind and polkit.
#
# sshd is deliberately NOT in this list: rootfs-init.sh (our /sbin/init
# replacement) already starts /usr/sbin/sshd directly and persistently
# before handing off to this OpenRC boot, specifically so the recovery/
# telnet-adjacent SSH session survives switch_root even if something later
# in boot fails. If OpenRC's own sshd service is also enabled here, it
# tries to start a second instance once it reaches the default runlevel,
# start-stop-daemon finds one already running, and OpenRC logs it as a
# failed service ("Failed to start sshd" / "ERROR: sshd failed to start")
# even though SSH access itself is fine. Enabling it here would just add a
# second, OpenRC-supervised sshd that conflicts with the one already owned
# by rootfs-init.sh.
for s in dbus elogind polkit local networkmanager bluetooth crond \
	udev-postmount chronyd; do
	[ -x "$ROOT/etc/init.d/$s" ] || { echo "missing init script: $s" >&2; continue; }
	ln -sf "/etc/init.d/$s" "$ROOT/etc/runlevels/default/$s"
done

# --- caches and compiled data -------------------------------------------
chroot "$ROOT" /bin/sh -c '
set -e
command -v glib-compile-schemas >/dev/null && glib-compile-schemas /usr/share/glib-2.0/schemas
command -v gio-querymodules >/dev/null && gio-querymodules /usr/lib/gio/modules || true
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v update-mime-database >/dev/null && update-mime-database /usr/share/mime || true
command -v fc-cache >/dev/null && fc-cache -f >/dev/null 2>&1 || true
for d in /usr/share/icons/*; do
	[ -f "$d/index.theme" ] || continue
	command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$d" >/dev/null 2>&1 || true
done
if command -v gdk-pixbuf-query-loaders >/dev/null; then
	mkdir -p /usr/lib/gdk-pixbuf-2.0/2.10.0
	gdk-pixbuf-query-loaders > /usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
fi
command -v update-ca-certificates >/dev/null && update-ca-certificates || true
command -v udevadm >/dev/null && udevadm hwdb --update || true
command -v dconf >/dev/null && dconf update || true
'

# Alpine ships the WCN3990 and regulatory firmware zstd-compressed, but the
# xun kernel only has the XZ decompressor. Leave the .zst files in place and
# add the uncompressed names the firmware loader looks for.
if [ -d "$ROOT/lib/firmware/ath10k/WCN3990" ]; then
	find "$ROOT/lib/firmware/ath10k/WCN3990" -name '*.zst' | while read -r f; do
		zstd -d -f "$f" -o "${f%.zst}" >/dev/null 2>&1 || true
	done
fi
for f in "$ROOT"/lib/firmware/regulatory.db.zst \
	"$ROOT"/lib/firmware/regulatory.db.p7s.zst; do
	[ -f "$f" ] && zstd -d -f "$f" -o "${f%.zst}" >/dev/null 2>&1 || true
done
chown -R root:root "$ROOT/lib/firmware"

# Build the filesystem while the tree is still owned by root: mke2fs -d copies
# the ownership and the setuid bits into the image. root can also read the
# execute-only helpers without changing their modes.
if [ -n "${IMG:-}" ]; then
	rm -f "$IMG"
	truncate -s "${SIZE:-10G}" "$IMG"
	# lazy_itable_init/lazy_journal_init (mke2fs's default for ext4) leave
	# the inode table and journal superblock not actually written -- a real
	# block device's kernel driver finishes that lazily on first mount via
	# a background thread. This kernel's jbd2 doesn't do that: the journal
	# superblock here is just zero bytes, read back as "no valid journal
	# superblock found" at mount time, even though e2fsck -fn right after
	# mke2fs sees it as a normal pending-lazy-init filesystem, not damage.
	# Force both to be written for real at build time instead.
	#
	# That fix alone was not enough: the *same* "no valid journal
	# superblock found" / "Could not load journal inode" failure kept
	# recurring even with a checksum-verified, non-lazy image flashed
	# intact. Root cause, found by diffing the kernel config against what
	# modern e2fsprogs enables by default: this build's base.config has
	# "# CONFIG_CRYPTO_CRC32C is not set" (CONFIG_CRC32/CRC32_ARCH are a
	# separate, non-crypto-API lib used for other checksums and don't
	# help here), while mke2fs's default feature set turns on
	# metadata_csum (and 64bit), which checksums the superblock, inodes
	# -- including the journal inode -- and group descriptors with
	# crc32c via the crypto shash API. With no crc32c transform
	# registered, the kernel can't verify those checksums, so it treats
	# the journal inode/superblock as invalid, exactly matching the
	# observed errors. Confirmed locally: mke2fs's default output has a
	# superblock "Checksum:" field and "metadata_csum" in its feature
	# list; adding -O ^metadata_csum,^64bit removes both and leaves a
	# filesystem with no crc32c dependency at all (plain classic
	# journal, "Journal features: (none)" either way).
	#
	# Fixing this at the image-build layer (rather than flipping on
	# CONFIG_CRYPTO_CRC32C and rebuilding/reflashing the kernel) keeps
	# this a userdata-image-only change with no boot.img rebuild needed.
	mke2fs -q -t ext4 -L tapas_root -O ^metadata_csum,^64bit \
		-E root_owner=0:0,lazy_itable_init=0,lazy_journal_init=0 \
		-d "$ROOT" -F "$IMG"
	# Catch a bad build (e.g. a corrupted journal) right here, before it
	# ever reaches a device: a filesystem image that fails its own fsck
	# immediately after creation means the bug is in this build step, not
	# in a later download or fastboot transfer.
	e2fsck -fn "$IMG" || {
		echo "mke2fs just produced a filesystem that fails e2fsck -- not a download/flash problem, the image build itself is broken" >&2
		exit 1
	}
	sha256sum "$IMG"
	chown "$HOST_UID:$HOST_GID" "$IMG"
fi

# Leave the tree owned by the host user so the work directory can be cleaned
# without sudo.
chown -R "$HOST_UID:$HOST_GID" "$ROOT"
echo "rootfs: $(du -sh "$ROOT" | cut -f1)"
