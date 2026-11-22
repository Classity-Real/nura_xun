#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0-only
# Temporary xun recovery init. Flash ONLY boot_b. Do not touch userdata.

/bin/busybox mkdir -p /proc /sys /dev /tmp /etc /mnt /mnt/userdata /sbin /usr/bin /usr/sbin /newroot
/bin/busybox --install -s
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mkdir -p /dev/pts /sys/kernel/config /sys/fs/pstore
mount -t devpts devpts /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts -o mode=0620,gid=5
mount -t configfs configfs /sys/kernel/config
mount -t pstore pstore /sys/fs/pstore 2>/dev/null
mount -t tmpfs tmpfs /tmp

# telnetd / login shells need a working ptmx
[ -c /dev/ptmx ] || mknod -m 666 /dev/ptmx c 5 2
[ -c /dev/tty ] || mknod -m 666 /dev/tty c 5 0
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3

log() {
	echo "xun-recovery: $*" >/dev/kmsg
	echo "xun-recovery: $*"
}

log "recovery init, kernel $(uname -r)"
log "userdata will NOT be formatted or written by default"

for a in telnetd udhcpd nc setsid cttyhack; do
	if /bin/busybox --list 2>/dev/null | grep -qx "$a"; then
		log "busybox applet: $a OK"
	else
		log "busybox applet: $a MISSING"
	fi
done

if ls /sys/fs/pstore/console-ramoops* >/dev/null 2>&1; then
	cat /sys/fs/pstore/console-ramoops* >/tmp/last_kmsg 2>/dev/null
	log "previous ramoops saved to /tmp/last_kmsg"
fi

G=/sys/kernel/config/usb_gadget/g1
DWC3_DEV=4e00000.usb

force_device_role() {
	for role in \
		/sys/class/usb_role/*/role \
		/sys/devices/platform/*/usb_role/*/role \
		/sys/devices/platform/${DWC3_DEV}/usb_role/*/role; do
		[ -e "$role" ] || continue
		echo device >"$role" 2>/dev/null && log "USB role set to device via $role" && return 0
	done
	return 1
}

reset_dwc3() {
	if [ -e /sys/bus/platform/drivers/dwc3/unbind ]; then
		log "dwc3: unbind $DWC3_DEV"
		echo "$DWC3_DEV" >/sys/bus/platform/drivers/dwc3/unbind 2>/dev/null || true
		sleep 0.4
		echo "$DWC3_DEV" >/sys/bus/platform/drivers/dwc3/bind 2>/dev/null || true
		sleep 0.6
	fi
}

teardown_gadget() {
	[ -d "$G" ] || return 0
	echo "" >"$G/UDC" 2>/dev/null || true
	sleep 0.2
	rm -rf "$G" 2>/dev/null || true
}

setup_gadget() {
	force_device_role || true
	udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
	if [ -z "$udc" ]; then
		reset_dwc3
		udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
	fi
	[ -n "$udc" ] || return 1

	teardown_gadget
	mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409"
	mkdir -p "$G/functions/ncm.usb0" || return 1
	mkdir -p "$G/functions/acm.usb0" || true

	echo 0x1d6b >"$G/idVendor"
	echo 0x0104 >"$G/idProduct"
	echo xun-recovery >"$G/strings/0x409/serialnumber"
	echo Xiaomi >"$G/strings/0x409/manufacturer"
	echo "Redmi Pad SE recovery" >"$G/strings/0x409/product"
	echo "NCM+ACM recovery" >"$G/configs/c.1/strings/0x409/configuration"
	echo 02:78:75:6e:72:01 >"$G/functions/ncm.usb0/dev_addr" 2>/dev/null || true
	echo 02:78:75:6e:72:02 >"$G/functions/ncm.usb0/host_addr" 2>/dev/null || true
	ln -sfn "$G/functions/ncm.usb0" "$G/configs/c.1/ncm.usb0"
	[ -d "$G/functions/acm.usb0" ] && ln -sfn "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"
	echo 0x0100 >"$G/bcdDevice" 2>/dev/null || true
	echo 0x0200 >"$G/bcdUSB" 2>/dev/null || true

	echo "" >"$G/UDC" 2>/dev/null || true
	sleep 0.3
	echo "$udc" >"$G/UDC" || return 1
	sleep 0.5
	mdev -s 2>/dev/null || true
	log "USB gadget bound to $udc (ncm + acm)"
	return 0
}

rebind_udc() {
	[ -d "$G" ] || return 1
	udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
	[ -n "$udc" ] || {
		reset_dwc3
		udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
	}
	[ -n "$udc" ] || return 1
	log "USB: rebinding UDC $udc"
	echo "" >"$G/UDC" 2>/dev/null || true
	sleep 0.3
	if [ "${1:-}" = hard ]; then
		reset_dwc3
		udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
		[ -n "$udc" ] || return 1
	fi
	echo "$udc" >"$G/UDC" 2>/dev/null || return 1
	sleep 0.5
	mdev -s 2>/dev/null || true
	return 0
}

port_open() {
	# /proc/net/tcp{,6}: local port is last 4 hex digits of local_address (host order)
	# 23 = 0017, 2323 = 0913
	hex=$1
	grep -E ":${hex} " /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -q .
}

start_remote_shells() {
	# If a live listener exists, do nothing.
	if port_open 0017; then
		return 0
	fi

	# Kill stale non-listening telnetd processes
	pkill telnetd 2>/dev/null || true
	sleep 0.2

	# -F: stay in foreground so we can background it ourselves and keep a stable pid
	# -b 0.0.0.0: bind all interfaces (usb0 included)
	# -l /bin/sh: no login(1) required
	(
		exec /bin/busybox telnetd -F -p 23 -b 0.0.0.0 -l /bin/sh
	) >/tmp/telnetd.log 2>&1 &
	echo $! >/tmp/telnetd.pid
	sleep 0.5

	if port_open 0017; then
		log "telnetd LISTENING on 0.0.0.0:23 (pid $(cat /tmp/telnetd.pid))"
	elif kill -0 "$(cat /tmp/telnetd.pid 2>/dev/null)" 2>/dev/null; then
		log "telnetd running but port 23 not visible yet: $(cat /tmp/telnetd.log 2>/dev/null)"
		log "telnetd log/proc: $(tr '\n' ' ' </tmp/telnetd.log 2>/dev/null)"
	else
		log "telnetd DIED: $(cat /tmp/telnetd.log 2>/dev/null)"
		# Last-resort pure-busybox TCP shell if nc applet exists
		if /bin/busybox --list 2>/dev/null | grep -qx nc; then
			(
				while :; do
					/bin/busybox nc -ll -p 23 -e /bin/sh
					sleep 1
				done
			) >/tmp/nc23.log 2>&1 &
			log "spawned nc -ll -p 23 fallback"
		fi
	fi

	# Extra shell on 2323 when nc exists
	if /bin/busybox --list 2>/dev/null | grep -qx nc && ! port_open 0913; then
		(
			while :; do
				/bin/busybox nc -ll -p 2323 -e /bin/sh
				sleep 1
			done
		) >/tmp/nc2323.log 2>&1 &
		log "nc shell on :2323"
	fi
}

setup_net() {
	ifname=
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		for cand in usb0 usb1 eth0; do
			[ -e "/sys/class/net/$cand" ] && ifname=$cand && break
		done
		[ -n "$ifname" ] && break
		for f in /sys/kernel/config/usb_gadget/g1/functions/*/ifname; do
			[ -f "$f" ] || continue
			n=$(cat "$f" 2>/dev/null)
			[ -n "$n" ] && [ -e "/sys/class/net/$n" ] && ifname=$n && break
		done
		[ -n "$ifname" ] && break
		sleep 0.25
	done
	[ -n "$ifname" ] || return 1

	ip link set dev "$ifname" up 2>/dev/null || ifconfig "$ifname" up 2>/dev/null || true
	ip addr flush dev "$ifname" 2>/dev/null || true
	ip addr add 172.16.42.1/24 dev "$ifname" 2>/dev/null || \
		ifconfig "$ifname" 172.16.42.1 netmask 255.255.255.0 up || return 1

	if ! pgrep -x udhcpd >/dev/null 2>&1; then
		printf '%s\n' \
			"start 172.16.42.2" \
			"end 172.16.42.2" \
			"interface $ifname" \
			"option subnet 255.255.255.0" \
			"lease_file /tmp/udhcpd.leases" >/etc/udhcpd.conf
		touch /tmp/udhcpd.leases
		/bin/busybox udhcpd /etc/udhcpd.conf 2>/tmp/udhcpd.err && log "udhcpd started" || \
			log "udhcpd failed (use static 172.16.42.2): $(cat /tmp/udhcpd.err 2>/dev/null)"
	fi

	start_remote_shells
	log "network on $ifname: 172.16.42.1"
	echo "$ifname" >/tmp/usb_ifname
	return 0
}

# ACM: ignore hangups so host open/close of ttyACM0 does not kill the shell forever.
start_acm_shell() {
	(
		while :; do
			mdev -s 2>/dev/null || true
			if [ -c /dev/ttyGS0 ]; then
				log "ttyGS0 present — ACM shell"
				# trap HUP so a host-side hangup does not kill the outer loop instantly
				setsid /bin/busybox sh -c '
					trap "" HUP
					exec <>/dev/ttyGS0 >&0 2>&1
					stty sane 2>/dev/null || true
					echo
					echo "xun-recovery ACM shell (ttyGS0)"
					exec /bin/sh -l
				'
				log "ACM shell exited (will respawn)"
			fi
			sleep 1
		done
	) &
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
	fi
	if command -v e2fsck >/dev/null 2>&1; then
		e2fsck -n "$dev" 2>&1 | head -n 120 | while IFS= read -r line; do log "e2fsck: $line"; done
	fi
	dd if="$dev" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | while IFS= read -r line; do
		log "superblock magic @1080: $line (expect 53 ef)"
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
	log "RO noload failed: $(cat /tmp/mount_ro.err 2>/dev/null)"
	mount -t ext4 -o ro "$dev" /mnt/userdata 2>/tmp/mount_ro2.err && log "mounted $dev RO" && return 0
	log "RO mount failed: $(cat /tmp/mount_ro2.err 2>/dev/null)"
	return 1
}

cat >/etc/profile <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='xun-recovery# '
echo "=== xun temporary recovery shell ==="
alias last_kmsg='cat /tmp/last_kmsg 2>/dev/null || echo no ramoops'
alias diag='dev=$(cat /tmp/userdata_dev 2>/dev/null); [ -n "$dev" ] && dumpe2fs -h "$dev"; [ -n "$dev" ] && e2fsck -n "$dev"'
alias usb_fix='echo hard >/tmp/usb_rebind_req'
EOF

wait_udc() {
	for _ in $(seq "$1"); do
		[ -n "$(ls /sys/class/udc 2>/dev/null)" ] && return 0
		sleep 1
	done
	return 1
}

force_device_role || true
if ! wait_udc 8; then
	reset_dwc3
	wait_udc 10 || true
fi

if setup_gadget; then
	start_acm_shell
	setup_net || { rebind_udc hard || true; setup_net || true; }
else
	log "USB gadget setup failed"
	reset_dwc3
	setup_gadget && start_acm_shell && setup_net || log "USB recovery path failed"
fi

(
	while :; do
		sleep 5
		[ -f /tmp/usb_rebind_req ] && rm -f /tmp/usb_rebind_req && rebind_udc hard && setup_net
		ifname=$(cat /tmp/usb_ifname 2>/dev/null)
		[ -n "$ifname" ] && [ -e "/sys/class/net/$ifname" ] || continue
		ip addr add 172.16.42.1/24 dev "$ifname" 2>/dev/null || true
		# Only restart shells if port 23 is down
		port_open 0017 || start_remote_shells
	done
) &

sleep 1
mdev -s

rootdev=$(find_userdata) || true
if [ -n "$rootdev" ]; then
	echo "$rootdev" >/tmp/userdata_dev
	log "userdata candidate: $rootdev"
	diag_userdata "$rootdev"
	try_mount_ro "$rootdev" || true
fi

log "recovery ready — telnet 172.16.42.1  or  picocom -b 115200 /dev/ttyACM0"

while :; do
	if [ -c /dev/console ]; then
		setsid cttyhack sh -l </dev/console >/dev/console 2>&1 || sh -l
	else
		sleep 5
	fi
	sleep 1
done
