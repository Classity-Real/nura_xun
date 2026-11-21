#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Temporary xun recovery init.
#
# Goals:
#  - Boot without depending on the corrupted userdata rootfs
#  - Never format, erase, or write-repair userdata by default
#  - Provide console + USB gadget shell (telnet 172.16.42.1)
#  - Mount userdata read-only for inspection when possible
#  - Run read-only e2fs diagnostics on console
#
# Flash ONLY boot_b with boot-xun-recovery.img. Do not flash userdata.

/bin/busybox mkdir -p /proc /sys /dev /tmp /etc /mnt /mnt/userdata /sbin /usr/bin /usr/sbin /newroot
/bin/busybox --install -s
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mkdir -p /dev/pts /sys/kernel/config /sys/fs/pstore
mount -t devpts devpts /dev/pts
mount -t configfs configfs /sys/kernel/config
mount -t pstore pstore /sys/fs/pstore 2>/dev/null
mount -t tmpfs tmpfs /tmp

log() {
	echo "xun-recovery: $*" >/dev/kmsg
	echo "xun-recovery: $*"
}

log "recovery init, kernel $(uname -r)"
log "userdata will NOT be formatted or written by default"

if ls /sys/fs/pstore/console-ramoops* >/dev/null 2>&1; then
	cat /sys/fs/pstore/console-ramoops* >/tmp/last_kmsg 2>/dev/null
	log "previous ramoops saved to /tmp/last_kmsg"
fi

G=/sys/kernel/config/usb_gadget/g1

setup_gadget() {
	udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
	[ -n "$udc" ] || return 1
	rm -rf "$G" 2>/dev/null
	mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409"

	# Prefer CDC-NCM (what current host diagnostics bind). Fall back to ECM.
	if mkdir -p "$G/functions/ncm.usb0" 2>/dev/null; then
		func=ncm.usb0
		mode=ncm
	else
		mkdir -p "$G/functions/ecm.usb0" || return 1
		func=ecm.usb0
		mode=ecm
	fi
	mkdir -p "$G/functions/acm.usb0" || true

	echo 0x1d6b >"$G/idVendor"
	echo 0x0104 >"$G/idProduct"
	echo xun-recovery >"$G/strings/0x409/serialnumber"
	echo Xiaomi >"$G/strings/0x409/manufacturer"
	echo "Redmi Pad SE recovery" >"$G/strings/0x409/product"
	echo "NCM+ACM recovery" >"$G/configs/c.1/strings/0x409/configuration"

	echo 02:78:75:6e:72:01 >"$G/functions/$func/dev_addr" 2>/dev/null || true
	echo 02:78:75:6e:72:02 >"$G/functions/$func/host_addr" 2>/dev/null || true
	ln -sfn "$G/functions/$func" "$G/configs/c.1/$func"
	[ -d "$G/functions/acm.usb0" ] && ln -sfn "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"

	echo "" >"$G/UDC" 2>/dev/null
	sleep 0.2
	echo "$udc" >"$G/UDC" || return 1
	log "USB gadget bound to $udc ($mode + acm)"
	return 0
}

setup_net() {
	# Wait for netdev from the gadget function
	ifname=
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
		for cand in usb0 usb1 eth0; do
			[ -e "/sys/class/net/$cand" ] && ifname=$cand && break
		done
		[ -n "$ifname" ] && break
		# ConfigFS may export the ifname under the function dir
		for f in /sys/kernel/config/usb_gadget/g1/functions/*/ifname; do
			[ -f "$f" ] || continue
			n=$(cat "$f" 2>/dev/null)
			[ -n "$n" ] && [ -e "/sys/class/net/$n" ] && ifname=$n && break
		done
		[ -n "$ifname" ] && break
		sleep 0.3
	done
	[ -n "$ifname" ] || return 1

	ip link set dev "$ifname" up 2>/dev/null || ifconfig "$ifname" up 2>/dev/null || true
	ip addr flush dev "$ifname" 2>/dev/null || true
	ip addr add 172.16.42.1/24 dev "$ifname" 2>/dev/null || \
		ifconfig "$ifname" 172.16.42.1 netmask 255.255.255.0 up || return 1

	printf '%s\n' \
		"start 172.16.42.2" \
		"end 172.16.42.2" \
		"interface $ifname" \
		"option subnet 255.255.255.0" \
		"lease_file /tmp/udhcpd.leases" >/etc/udhcpd.conf
	touch /tmp/udhcpd.leases
	pkill udhcpd 2>/dev/null || true
	udhcpd /etc/udhcpd.conf 2>/dev/null || true
	pkill telnetd 2>/dev/null || true
	telnetd -l /bin/sh 2>/dev/null || true
	log "network on $ifname: 172.16.42.1  (telnet 172.16.42.1)"
	return 0
}

find_userdata() {
	for b in /sys/class/block/*; do
		dev=/dev/${b##*/}
		[ -b "$dev" ] || continue
		part=$(sed -n 's/^PARTNAME=//p' "$b/uevent" 2>/dev/null)
		[ "$part" = userdata ] || continue
		echo "$dev"
		return 0
	done
	# Fallback: large mmc partition often used as userdata
	for dev in /dev/mmcblk1p91 /dev/mmcblk0p91; do
		[ -b "$dev" ] && echo "$dev" && return 0
	done
	return 1
}

diag_userdata() {
	dev=$1
	log "=== diagnostics for $dev (read-only) ==="
	blkid "$dev" 2>/dev/null | while IFS= read -r line; do log "blkid: $line"; done
	if command -v dumpe2fs >/dev/null 2>&1; then
		dumpe2fs -h "$dev" 2>&1 | while IFS= read -r line; do log "dumpe2fs: $line"; done
	else
		log "dumpe2fs not present in this initramfs"
	fi
	if command -v e2fsck >/dev/null 2>&1; then
		# NEVER auto-repair here. Read-only check only.
		e2fsck -n "$dev" 2>&1 | head -n 120 | while IFS= read -r line; do log "e2fsck: $line"; done
	else
		log "e2fsck not present in this initramfs"
	fi
	# Superblock magic at offset 0x438 = 1080
	dd if="$dev" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | while IFS= read -r line; do
		log "superblock magic bytes @1080: $line (expect 53 ef)"
	done
}

try_mount_ro() {
	dev=$1
	mkdir -p /mnt/userdata
	if mount -t ext4 -o ro,noload "$dev" /mnt/userdata 2>/tmp/mount_ro.err; then
		log "mounted $dev RO (noload) at /mnt/userdata"
		ls -la /mnt/userdata | head -n 20 | while IFS= read -r line; do log "ls: $line"; done
		return 0
	fi
	log "RO noload mount failed: $(cat /tmp/mount_ro.err 2>/dev/null)"
	if mount -t ext4 -o ro "$dev" /mnt/userdata 2>/tmp/mount_ro2.err; then
		log "mounted $dev RO at /mnt/userdata"
		return 0
	fi
	log "RO mount failed: $(cat /tmp/mount_ro2.err 2>/dev/null)"
	return 1
}

cat >/etc/profile <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='xun-recovery# '
echo "=== xun temporary recovery shell ==="
echo "  userdata is NOT auto-repaired or formatted"
echo "  /mnt/userdata  - RO mount if successful"
echo "  last_kmsg      - previous ramoops if any"
echo "  diag           - re-run e2fsck -n / dumpe2fs -h"
echo "  telnet host:   telnet 172.16.42.1  (host IP 172.16.42.2/24)"
alias last_kmsg='cat /tmp/last_kmsg 2>/dev/null || echo no ramoops'
alias diag='dev=$(cat /tmp/userdata_dev 2>/dev/null); [ -n "$dev" ] && dumpe2fs -h "$dev"; [ -n "$dev" ] && e2fsck -n "$dev"'
EOF

# --- USB ---
wait_udc() {
	for _ in $(seq "$1"); do
		[ -n "$(ls /sys/class/udc 2>/dev/null)" ] && return 0
		sleep 1
	done
	return 1
}

if wait_udc 12; then
	if setup_gadget; then
		(
			while :; do
				[ -c /dev/ttyGS0 ] && setsid cttyhack sh -l </dev/ttyGS0 >/dev/ttyGS0 2>&1
				sleep 1
			done
		) &
		setup_net || log "gadget up but network setup failed"
		# Keep trying network a few times (UDC/host race)
		(
			for _ in 1 2 3 4 5 6 7 8 9 10; do
				sleep 2
				setup_net && break
			done
		) &
	else
		log "USB gadget setup failed; udc='$(ls /sys/class/udc 2>/dev/null)'"
	fi
else
	log "no UDC appeared"
fi

sleep 2
mdev -s

log "block devices (name sizeMiB PARTNAME):"
for b in /sys/class/block/*; do
	name=${b##*/}
	part=$(sed -n 's/^PARTNAME=//p' "$b/uevent" 2>/dev/null)
	size=$(( $(cat "$b/size" 2>/dev/null || echo 0) / 2048 ))
	case $name in
	sd?|mmcblk?) log "  $name ${size}MiB" ;;
	*) [ -n "$part" ] && [ "$size" -gt 64 ] && log "  $name ${size}MiB part=$part" ;;
	esac
done

rootdev=
rootdev=$(find_userdata) || true
if [ -n "$rootdev" ]; then
	echo "$rootdev" >/tmp/userdata_dev
	log "userdata candidate: $rootdev"
	diag_userdata "$rootdev"
	try_mount_ro "$rootdev" || true
else
	log "no userdata partition found by PARTNAME"
fi

log "recovery ready — staying in initramfs (no switch_root)"
log "host: ip addr add 172.16.42.2/24 dev <usb-iface>; telnet 172.16.42.1"

# Forever: refresh gadget net if needed, keep a console shell alive
while :; do
	setup_net >/dev/null 2>&1 || true
	if [ -c /dev/console ]; then
		setsid cttyhack sh -l </dev/console >/dev/console 2>&1 || sh -l
	else
		sleep 5
	fi
	sleep 1
done
