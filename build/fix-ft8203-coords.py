#!/usr/bin/env python3
"""Ensure FT8203 reports native panel coords (no in-driver landscape rotate)."""
import pathlib
import re
import sys
import urllib.request

FULL_URL = (
    "https://raw.githubusercontent.com/Classity-Real/nura_xun/"
    "fix/ft8203-landscape-touch/build/kernel-touch/ft8203-spi.c"
)

path = pathlib.Path(sys.argv[1])
text = path.read_text() if path.exists() else ""

# Stub left by an interrupted edit: restore full upstream driver first.
if (not text) or ("ft8203_load_fw" not in text and "firmware" not in text.lower()) or len(text) < 8000:
    print("ft8203: restoring full driver from fix/ft8203-landscape-touch")
    with urllib.request.urlopen(FULL_URL, timeout=60) as r:
        text = r.read().decode()
    path.write_text(text)

if "1919 - y" not in text and not re.search(r"1919\s*-\s*y", text):
    if "ABS_MT_POSITION_X, 0, 1199" in text:
        print("ft8203: already native coords")
        sys.exit(0)

text2, n = re.subn(
    r"input_report_abs\(input, ABS_MT_POSITION_X, 1919 - y\);\s*"
    r"input_report_abs\(input, ABS_MT_POSITION_Y, x\);",
    "if (x > 1199)\n\t\t\tx = 1199;\n\t\tif (y > 1919)\n\t\t\ty = 1919;\n"
    "\t\tinput_report_abs(input, ABS_MT_POSITION_X, x);\n"
    "\t\tinput_report_abs(input, ABS_MT_POSITION_Y, y);",
    text,
)
text3, n2 = re.subn(
    r"input_set_abs_params\(input, ABS_MT_POSITION_X, 0, 1919, 0, 0\);\s*"
    r"input_set_abs_params\(input, ABS_MT_POSITION_Y, 0, 1199, 0, 0\);",
    "input_set_abs_params(input, ABS_MT_POSITION_X, 0, 1199, 0, 0);\n"
    "\tinput_set_abs_params(input, ABS_MT_POSITION_Y, 0, 1919, 0, 0);",
    text2,
)
path.write_text(text3)
print(f"ft8203: fixed coords (report={n} abs={n2})")
if n == 0 and "1919 - y" in text:
    sys.exit("failed to rewrite report abs")
