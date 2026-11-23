#!/usr/bin/env python3
"""Rewrite FT8203 report path to native panel coords (no in-driver rotate)."""
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "1919 - y" not in text and re.search(r"1919\s*-\s*y", text) is None:
    # Also accept already-native drivers.
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
