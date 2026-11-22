#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0-only
# Temporary xun recovery init. Flash ONLY boot_b. Do not touch userdata.
#
# USB gadget path follows fix/windows-usb-ncm (tapas-ncm.patch) and
# fix/ncm-network-handoff: NCM+ACM, fixed MACs, ifname from configfs.

/bin/busybox mkdir -p /proc /sys /dev /tmp /etc /mnt /mnt/userdata /sbin /usr/bin /usr/sbin /newroot
/bin/busybox --install -s
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mkdir -p /dev/pts /sys/kernel/config /sys/fs/pstore
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t configfs configfs /sys/kernel/config
mount -t pstore pstore /sys/fs/pstore 2>/dev/null
mount -t tmpfs tmpfs /tmp

[ -c /dev/ptmx ] || mknod -m 666 /dev/ptmx c 5 2
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3

log() {
	echo "xun-recovery: $*" >/dev/kmsg
	echo "xun-recovery: $*"
}

log "recovery init, kernel $(uname -r)"

for a in telnetd udhcpd; do
	/bin/busybox --list 2>/dev/null | grep -qx "$a" && log "applet $a OK" || log "applet $a MISSING"
done

G=/sys/kernel/config/usb_gadget/g1

# Matches build/patches/tapas-ncm.patch (fix/windows-usb-ncm)
setup_gadget() {
	udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
	[ -n "$udc" ] || return 1

	rm -rf "$G" 2>/dev/null
	mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" \
		"$G/functions/ncm.usb0" "$G/functions/acm.usb0"

	echo 0x1d6b >"$G/idVendor"
	echo 0x0104 >"$G/idProduct"
	echo xun-recovery >"$G/strings/0x409/serialnumber"
	echo Xiaomi >"$G/strings/0x409/manufacturer"
	echo "Redmi Pad SE recovery" >"$G/strings/0x409/product"
	echo NCM+ACM >"$G/configs/c.1/strings/0x409/configuration"

	# Same fixed addresses as the working NCM port (host keeps stable iface name)
	echo 02:7a:70:61:73:01 >"$G/functions/ncm.usb0/dev_addr"
	echo 02:7a:70:61:73:02 >"$G/functions/ncm.usb0/host_addr"
	ln -sfn "$G/functions/ncm.usb0" "$G/configs/c.1/ncm.usb0"
	ln -sfn "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"

	echo "" >"$G/UDC" 2>/dev/null
	sleep 0.3
	echo "$udc" >"$G/UDC" || return 1
	sleep 0.5
	log "USB gadget bound to $udc (NCM+ACM)"
	return 0
}

setup_net() {
	# Prefer configfs ifname (tapas-ncm style)
	ifname=$(cat "$G/functions/ncm.usb0/ifname" 2>/dev/null)
	if [ -z "$ifname" ] || [ ! -e "/sys/class/net/$ifname" ]; then
		ifname=
		for cand in usb0 usb1 eth0; do
			[ -e "/sys/class/net/$cand" ] && ifname=$cand && break
		done
	fi
	[ -n "$ifname" ] || return 1

	# ifconfig path is what the original tapas bring-up used successfully
	ifconfig "$ifname" 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null || {
		ip link set dev "$ifname" up
		ip addr add 172.16.42.1/24 dev "$ifname" 2>/dev/null || return 1
	}

	printf '%s\n' \
		"start 172.16.42.2" \
		"end 172.16.42.2" \
		"interface $ifname" \
		"option subnet 255.255.255.0" \
		"lease_file /tmp/udhcpd.leases" >/etc/udhcpd.conf
	touch /tmp/udhcpd.leases
	pkill udhcpd 2>/dev/null || true
	/bin/busybox udhcpd /etc/udhcpd.conf 2>/tmp/udhcpd.err || true

	# Telnet: foreground daemon, explicit bind (needs ptmx)
	pkill telnetd 2>/dev/null || true
	(
		exec /bin/busybox telnetd -F -p 23 -b 0.0.0.0 -l /bin/sh
	) >/tmp/telnetd.log 2>&1 &
	sleep 0.4
	if grep -qE ':0017 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
		log "telnetd LISTENING on :23"
	else
		log "telnetd not listening: $(cat /tmp/telnetd.log 2>/dev/null)"
	fi

	log "network on $ifname: 172.16.42.1 (telnet 172.16.42.1)"
	echo "$ifname" >/tmp/usb_ifname
	return 0
}

start_acm_shell() {
	(
		while :; do
			[ -c /dev/ttyGS0 ] || { mdev -s 2>/dev/null; sleep 1; continue; }
			setsid /bin/busybox sh -c '
				trap "" HUP
				exec <>/dev/ttyGS0 >&0 2>&1
				echo "xun-recovery ACM shell"
				exec /bin/sh -l
			'
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
	log "=== RO diagnostics $dev ==="
	blkid "$dev" 2>/dev/null | while IFS= read -r line; do log "blkid: $line"; done
	command -v dumpe2fs >/dev/null 2>&1 && dumpe2fs -h "$dev" 2>&1 | while IFS= read -r line; do log "dumpe2fs: $line"; done
	command -v e2fsck >/dev/null 2>&1 && e2fsck -n "$dev" 2>&1 | head -n 80 | while IFS= read -r line; do log "e2fsck: $line"; done
}

try_mount_ro() {
	dev=$1
	mkdir -p /mnt/userdata
	mount -t ext4 -o ro,noload "$dev" /mnt/userdata 2>/tmp/m.err && {
		log "mounted $dev RO (noload)"
		return 0
	}
	log "RO noload failed: $(cat /tmp/m.err 2>/dev/null)"
	return 1
}

# Wait for UDC (no dwc3 hard reset — that broke ping)
for _ in $(seq 15); do
	[ -n "$(ls /sys/class/udc 2>/dev/null)" ] && break
	sleep 1
done

if setup_gadget; then
	start_acm_shell
	sleep 1
	setup_net || { sleep 2; setup_net || log "network failed — unplug/replug USB"; }
else
	log "gadget failed; udc=$(ls /sys/class/udc 2>/dev/null)"
fi

# Soft watchdog: keep IP + telnet only (like 80-usb-reconnect.start, no dwc3 unbind)
(
	while :; do
		sleep 3
		ifname=$(cat /tmp/usb_ifname 2>/dev/null)
		[ -n "$ifname" ] || { setup_net 2>/dev/null || true; continue; }
		if [ -e "/sys/class/net/$ifname" ]; then
			ifconfig "$ifname" 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null || \
				ip addr add 172.16.42.1/24 dev "$ifname" 2>/dev/null || true
			grep -qE ':0017 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null || setup_net 2>/dev/null || true
		else
			# Cable unplug/replug: netdev may return with same name
			setup_net 2>/dev/null || true
		fi
	done
) &

mdev -s
rootdev=$(find_userdata) || true
if [ -n "$rootdev" ]; then
	echo "$rootdev" >/tmp/userdata_dev
	diag_userdata "$rootdev"
	try_mount_ro "$rootdev" || true
fi

log "recovery ready — ping/telnet 172.16.42.1  or  picocom /dev/ttyACM0"

while :; do
	[ -c /dev/console ] && setsid cttyhack sh -l </dev/console >/dev/console 2>&1
	sleep 1
done
