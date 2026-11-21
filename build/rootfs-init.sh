#!/bin/sh
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH
# /sbin/init of the Alpine rootfs installed on the tablet.
#
# The initramfs keeps the USB NCM gadget and Telnet recovery connection alive
# across switch_root. This script mounts what the desktop needs, brings up
# udev (without it logind has no seat and mutter does not start), starts SSH,
# and then hands over to busybox init, which runs /etc/inittab and the
# /etc/local.d/*.start scripts.
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mkdir -p /sys/kernel/config /dev/pts /var/log /var/lib/misc /run
mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
# elogind, GDM and dbus want a writable /run
mountpoint -q /run || mount -t tmpfs -o size=128M,mode=0755,nosuid,nodev tmpfs /run
mkdir -p /run/systemd/seats /run/user

# Keep transient files in RAM while the userdata-backed root stays persistent.
mkdir -p /tmp /var/tmp /dev/shm
mountpoint -q /tmp || mount -t tmpfs -o size=384M,mode=1777,nosuid,nodev tmpfs /tmp
mountpoint -q /var/tmp || mount -t tmpfs -o size=128M,mode=1777,nosuid,nodev tmpfs /var/tmp
mountpoint -q /dev/shm || mount -t tmpfs -o size=128M,mode=1777,nosuid,nodev tmpfs /dev/shm

# udev: devtmpfs only creates the nodes, the seat devices have to be coldplugged
if command -v udevd >/dev/null 2>&1; then
	udevd --daemon
	udevadm trigger --action=add
	udevadm settle --timeout=30
fi

# The initramfs already owns the NCM gadget and its udhcpd service.
# Keep the link and address, but do not rebind the UDC or start a second DHCP
# server from the rootfs; the existing Telnet session remains available.
if [ -e /sys/class/net/usb0 ]; then
	ip link set usb0 up 2>/dev/null
	ip addr replace 172.16.42.1/24 dev usb0 2>/dev/null
fi

if [ -x /usr/sbin/sshd ]; then
	ssh-keygen -A 2>/dev/null
	mkdir -p /run/sshd
	/usr/sbin/sshd 2>/dev/null
fi

exec /bin/busybox init
