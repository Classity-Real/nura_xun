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

G=/sys/kernel/config/usb_gadget/g1

force_device_role() {
	for role in /sys/class/usb_role/*/role /sys/devices/platform/*/usb_role/*/role; do
		[ -e "$role" ] || continue
		echo device >"$role" 2>/dev/null && log "USB role -> device ($role)" && return 0
	done
	return 1
}

# Single, calm gadget bring-up. Do not unbind dwc3 in a loop — that kills NCM.
setup_gadget() {
	force_device_role || true
	udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
	[ -n "$udc" ] || return 1

	if [ -d "$G" ]; then
		# Already configured; just ensure UDC is bound.
		cur=$(cat "$G/UDC" 2>/dev/null || true)
		if [ -z "$cur" ]; then
			echo "$udc" >"$G/UDC" || return 1
			sleep 0.5
		fi
		log "USB gadget already present, UDC=$(cat "$G/UDC" 2>/dev/null)"
		return 0
	fi

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

	echo "" >"$G/UDC" 2>/dev/null || true
	sleep 0.2
	echo "$udc" >"$G/UDC" || return 1
	sleep 0.8
	mdev -s 2>/dev/null || true
	log "USB gadget bound to $udc (ncm + acm)"
	return 0
}

port_open() {
	hex=$1
	grep -E ":${hex} " /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -q .
}

start_remote_shells() {
	if port_open 0017; then
		return 0
	fi

	pkill telnetd 2>/dev/null || true
	sleep 0.2

	(
		exec /bin/busybox telnetd -F -p 23 -b 0.0.0.0 -l /bin/sh
	) >/tmp/telnetd.log 2>&1 &
	echo $! >/tmp/telnetd.pid
	sleep 0.6

	if port_open 0017; then
		log "telnetd LISTENING on :23 (pid $(cat /tmp/telnetd.pid))"
	elif kill -0 "$(cat /tmp/telnetd.pid 2>/dev/null)" 2>/dev/null; then
		log "telnetd alive but :23 not in proc: $(cat /tmp/telnetd.log 2>/dev/null)"
	else
		log "telnetd DIED: $(cat /tmp/telnetd.log 2>/dev/null)"
	fi
}

setup_net() {
	ifname=
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
		for cand in usb0 usb1 eth0; do
			[ -e "/sys/class/net/$cand" ] && ifname=$cand && break
		done
		[ -n "$ifname" ] && break
		for f in "$G"/functions/*/ifname; do
			[ -f "$f" ] || continue
			n=$(cat "$f" 2>/dev/null)
			[ -n "$n" ] && [ -e "/sys/class/net/$n" ] && ifname=$n && break
		done
		[ -n "$ifname" ] && break
		sleep 0.2
	done
	[ -n "$ifname" ] || {
		log "no usb netdev yet"
		return 1
	}

	ip link set dev "$ifname" up 2>/dev/null || ifconfig "$ifname" up 2>/dev/null || true
	# Do not flush if address already correct — avoids brief black holes
	if ! ip addr show dev "$ifname" 2>/dev/null | grep -q '172.16.42.1/24'; then
		ip addr add 172.16.42.1/24 dev "$ifname" 2>/dev/null || \
			ifconfig "$ifname" 172.16.42.1 netmask 255.255.255.0 up || return 1
	fi

	if ! pgrep -x udhcpd >/dev/null 2>&1; then
		printf '%s\n' \
			"start 172.16.42.2" \
			"end 172.16.42.2" \
			"interface $ifname" \
			"option subnet 255.255.255.0" \
			"lease_file /tmp/udhcpd.leases" >/etc/udhcpd.conf
		touch /tmp/udhcpd.leases
		/bin/busybox udhcpd /etc/udhcpd.conf 2>/tmp/udhcpd.err && log "udhcpd ok" || \
			log "udhcpd skip: $(cat /tmp/udhcpd.err 2>/dev/null)"
	fi

	start_remote_shells
	log "network on $ifname: 172.16.42.1/24"
	echo "$ifname" >/tmp/usb_ifname
	return 0
}

start_acm_shell() {
	(
		while :; do
			mdev -s 2>/dev/null || true
			if [ -c /dev/ttyGS0 ]; then
				log "ACM shell on ttyGS0"
				setsid /bin/busybox sh -c '
					trap "" HUP
					exec <>/dev/ttyGS0 >&0 2>&1
					stty sane 2>/dev/null || true
					echo "xun-recovery ACM shell"
					exec /bin/sh -l
				'
				log "ACM shell exited; respawn"
			fi
			sleep 1
		done
	) &
}

find_userdata() {
	for b in /sys/class/block/*; do
		dev=/dev/${b##*/}
		[ -b "$dev" ] || continue
		[ "$(sed -n 's/^PARTNAME=//p' "$b/uevent" 2>/dev/null)" = userdata ] || continue
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
	command -v dumpe2fs >/dev/null 2>&1 && dumpe2fs -h "$dev" 2>&1 | while IFS= read -r line; do log "dumpe2fs: $line"; done
	command -v e2fsck >/dev/null 2>&1 && e2fsck -n "$dev" 2>&1 | head -n 120 | while IFS= read -r line; do log "e2fsck: $line"; done
}

try_mount_ro() {
	dev=$1
	mkdir -p /mnt/userdata
	mount -t ext4 -o ro,noload "$dev" /mnt/userdata 2>/tmp/m.err && {
		log "mounted $dev RO (noload)"
		ls -la /mnt/userdata | head -n 15 | while IFS= read -r line; do log "ls: $line"; done
		return 0
	}
	log "RO noload failed: $(cat /tmp/m.err 2>/dev/null)"
	mount -t ext4 -o ro "$dev" /mnt/userdata 2>/tmp/m2.err && log "mounted $dev RO" && return 0
	log "RO mount failed: $(cat /tmp/m2.err 2>/dev/null)"
	return 1
}

cat >/etc/profile <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='xun-recovery# '
alias diag='dev=$(cat /tmp/userdata_dev 2>/dev/null); [ -n "$dev" ] && dumpe2fs -h "$dev"; [ -n "$dev" ] && e2fsck -n "$dev"'
EOF

# Wait for UDC without resetting the controller
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	[ -n "$(ls /sys/class/udc 2>/dev/null)" ] && break
	sleep 1
done

if setup_gadget; then
	start_acm_shell
	# Give the host a moment to enumerate before configuring IP
	sleep 1
	setup_net || {
		log "netdev not ready, waiting…"
		sleep 3
		setup_net || log "network setup failed — unplug/replug USB cable once"
	}
else
	log "USB gadget setup failed; udc='$(ls /sys/class/udc 2>/dev/null)'"
fi

# Gentle watchdog: refresh IP + telnet only. Never unbind dwc3 here.
(
	while :; do
		sleep 5
		ifname=$(cat /tmp/usb_ifname 2>/dev/null)
		if [ -n "$ifname" ] && [ -e "/sys/class/net/$ifname" ]; then
			ip link set dev "$ifname" up 2>/dev/null || true
			ip addr add 172.16.42.1/24 dev "$ifname" 2>/dev/null || true
			port_open 0017 || start_remote_shells
		else
			# Interface vanished (cable unplug); try to re-setup net only
			setup_net 2>/dev/null || true
		fi
	done
) &

mdev -s
rootdev=$(find_userdata) || true
if [ -n "$rootdev" ]; then
	echo "$rootdev" >/tmp/userdata_dev
	log "userdata candidate: $rootdev"
	diag_userdata "$rootdev"
	try_mount_ro "$rootdev" || true
fi

log "recovery ready — ping 172.16.42.1 then telnet 172.16.42.1"
log "if ping fails: unplug USB 3s, replug; host: ip addr add 172.16.42.2/24 dev <iface>"

while :; do
	if [ -c /dev/console ]; then
		setsid cttyhack sh -l </dev/console >/dev/console 2>&1 || sh -l
	else
		sleep 5
	fi
	sleep 1
done
