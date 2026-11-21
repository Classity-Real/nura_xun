# xun temporary recovery boot

Branch: `recovery/xun-temporary-linux`  
Artifact: `boot-xun-recovery.img`

## Purpose

Boot a **temporary Linux recovery environment** that:

- Does **not** depend on mounting userdata as the system root
- Does **not** format, erase, or auto-repair userdata
- Provides a shell on the framebuffer console and over USB (telnet)
- Attempts a **read-only** mount of userdata for inspection
- Runs **read-only** diagnostics (`dumpe2fs -h`, `e2fsck -n`)

Use this when the normal `boot-xun.img` path hits:

```text
JBD2: no valid journal superblock found
EXT4-fs: Could not load journal inode
```

## Safety

| Action | Allowed? |
|--------|----------|
| Flash `boot_b` with recovery image | Yes |
| Flash / erase / format `userdata` | **No** (not required for recovery boot) |
| `e2fsck -n` (read-only check) | Yes |
| `e2fsck -y` / `-fy` | **No** until root cause is known and a backup exists |
| Repartition | **No** |

Normal GUI / slot-A Android is left alone. Recovery only replaces the boot image on slot B until you flash a normal `boot-xun.img` again.

## Build (CI)

```bash
gh api repos/Classity-Real/nura_xun/actions/workflows/build-xun.yml/dispatches \
  -f ref=recovery/xun-temporary-linux \
  -f 'inputs[target]=recovery'
```

Or: Actions → Build xun kernel → Run workflow → branch `recovery/xun-temporary-linux` → target **recovery**.

Artifact name: **`boot-xun-recovery-img`** → `boot-xun-recovery.img`

## Flash (boot partition only)

```bash
fastboot flash boot_b boot-xun-recovery.img
fastboot set_active b
fastboot reboot
```

Do **not** flash userdata for this test.

## Host access

```bash
# After the tablet enumerates USB NCM/ECM:
ip link          # find the new usb/enx interface
sudo ip addr add 172.16.42.2/24 dev <iface>
sudo ip link set <iface> up
ping -c 3 172.16.42.1
telnet 172.16.42.1
```

Serial ACM (if present): `picocom -b 115200 /dev/ttyACM0`

## On-device checks (in recovery shell)

```sh
cat /tmp/userdata_dev
diag
ls -la /mnt/userdata
dmesg | grep -iE 'jbd2|journal|ext4|dwc3|gadget|usb0'
```

## Return to normal boot image

```bash
fastboot flash boot_b boot-xun.img
fastboot reboot
```

Or set slot A active to return to Android:

```bash
fastboot set_active a
fastboot reboot
```
