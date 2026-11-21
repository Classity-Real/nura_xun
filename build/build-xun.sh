#!/bin/bash
# Recovery-aware entry for xun boot images.
# When XUN_RECOVERY=1, embeds recovery-init.sh and writes boot-xun-recovery.img.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)

FULL="$ROOT/build-xun.full.sh"
if [ ! -f "$FULL" ]; then
  echo "fetching build-xun.full.sh from main..."
  curl -fL --retry 5 --retry-delay 2 \
    -o "$FULL" \
    "https://raw.githubusercontent.com/Classity-Real/nura_xun/main/build/build-xun.sh"
fi

WORK_SCRIPT="$ROOT/work/build-xun.generated.sh"
mkdir -p "$ROOT/work"
cp "$FULL" "$WORK_SCRIPT"

# Force ROOT to this build/ directory. The generated script lives under
# build/work/, so its own dirname "$0" would otherwise point at work/ and
# look for src/ under the wrong tree.
python3 - "$WORK_SCRIPT" "$ROOT" <<'PY'
import sys
path, root = sys.argv[1], sys.argv[2]
text = open(path).read()
old = 'ROOT=$(cd "$(dirname "$0")" && pwd)'
new = f'ROOT="{root}"  # fixed by recovery wrapper'
if old not in text:
    raise SystemExit('ROOT assignment not found for recovery hook')
text = text.replace(old, new, 1)
open(path, 'w').write(text)
PY

python3 - "$WORK_SCRIPT" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = '''cat >"$WORK/initramfs.list" <<EOF
dir /bin 755 0 0
file /bin/busybox $BUSYBOX 755 0 0
file /init $ROOT/tapas-bringup/initramfs/init 755 0 0
dir /dev 755 0 0
dir /sbin 755 0 0
dir /etc 755 0 0
nod /dev/console 600 0 0 c 5 1
EOF'''
new = '''# XUN_RECOVERY_HOOK_V1
if [ "${XUN_RECOVERY:-0}" = "1" ]; then
	INIT_FILE=$ROOT/recovery-init.sh
	[ -f "$INIT_FILE" ] || { echo "missing $INIT_FILE" >&2; exit 1; }
	chmod 755 "$INIT_FILE" || true
	echo "building RECOVERY initramfs ($INIT_FILE)"
else
	INIT_FILE=$ROOT/tapas-bringup/initramfs/init
fi
cat >"$WORK/initramfs.list" <<EOF
dir /bin 755 0 0
file /bin/busybox $BUSYBOX 755 0 0
file /init $INIT_FILE 755 0 0
dir /dev 755 0 0
dir /sbin 755 0 0
dir /etc 755 0 0
nod /dev/console 600 0 0 c 5 1
EOF'''
if old not in text:
    raise SystemExit('initramfs block not found for recovery hook')
open(path, 'w').write(text.replace(old, new, 1))
PY

python3 - "$WORK_SCRIPT" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = '''python3 "$ROOT/tapas-bringup/scripts/mkbootimg.py" --header_version 4 \\
	--kernel "$WORK/shim-xun.bin" --ramdisk "$WORK/empty.cpio.gz" \\
	--os_version 13.0.0 --os_patch_level 2026-10 \\
	--cmdline "" --output "$OUT/boot-xun.img" | tail -1
ls -l "$OUT/boot-xun.img"'''
new = '''if [ "${XUN_RECOVERY:-0}" = "1" ]; then
	BOOT_OUT=$OUT/boot-xun-recovery.img
else
	BOOT_OUT=$OUT/boot-xun.img
fi
python3 "$ROOT/tapas-bringup/scripts/mkbootimg.py" --header_version 4 \\
	--kernel "$WORK/shim-xun.bin" --ramdisk "$WORK/empty.cpio.gz" \\
	--os_version 13.0.0 --os_patch_level 2026-10 \\
	--cmdline "" --output "$BOOT_OUT" | tail -1
ls -l "$BOOT_OUT"'''
if old not in text:
    raise SystemExit('mkbootimg block not found for recovery hook')
open(path, 'w').write(text.replace(old, new, 1))
PY

bash "$WORK_SCRIPT"
