#!/usr/bin/env python3
"""FT8203 coordinate policy for xun landscape chassis.

Native portrait reporting did not match the finger on device. Apply a
counter-clockwise map into 1920x1200 landscape space (the inverse of the
old CW map on fix/ft8203-landscape-touch):

  landscape_X = portrait_Y          (0..1919)
  landscape_Y = 1199 - portrait_X   (0..1199)

If the in-tree file is a stub, restore the full driver from the
landscape-touch branch first, then rewrite the report path.
"""
import pathlib
import re
import sys
import urllib.request

FULL_URL = (
    "https://raw.githubusercontent.com/Classity-Real/nura_xun/"
    "fix/ft8203-landscape-touch/build/kernel-touch/ft8203-spi.c"
)

REPORT_NEW = '''		touch = true;
		input_mt_report_slot_state(input, MT_TOOL_FINGER, true);
		/*
		 * CCW map into landscape chassis (1920x1200):
		 *   X = portrait_Y
		 *   Y = 1199 - portrait_X
		 * (Native + CW both missed the finger on device.)
		 */
		x = x * 1200 / FT8203_RAW_WIDTH;
		y = y * 1920 / FT8203_RAW_HEIGHT;
		if (x > 1199)
			x = 1199;
		if (y > 1919)
			y = 1919;
		input_report_abs(input, ABS_MT_POSITION_X, y);
		input_report_abs(input, ABS_MT_POSITION_Y, 1199 - x);'''

ABS_NEW = '''	/* Landscape after CCW map from native 1200x1920 panel space. */
	input_set_abs_params(input, ABS_MT_POSITION_X, 0, 1919, 0, 0);
	input_set_abs_params(input, ABS_MT_POSITION_Y, 0, 1199, 0, 0);'''

path = pathlib.Path(sys.argv[1])
text = path.read_text() if path.exists() else ""

if (not text) or ("ft8203_load_fw" not in text and "firmware" not in text.lower()) or len(text) < 8000:
    print("ft8203: restoring full driver from fix/ft8203-landscape-touch")
    with urllib.request.urlopen(FULL_URL, timeout=60) as r:
        text = r.read().decode()

# Replace any existing report-abs block (CW, native, or previous CCW).
pat_report = re.compile(
    r"\t\ttouch = true;\n"
    r"\t\tinput_mt_report_slot_state\(input, MT_TOOL_FINGER, true\);\n"
    r"\t\t/\*[\s\S]*?\*/\n"
    r"\t\tx = x \* 1200 / FT8203_RAW_WIDTH;\n"
    r"\t\ty = y \* 1920 / FT8203_RAW_HEIGHT;\n"
    r"(?:\t\tif \(x > 1199\)\n\t\t\tx = 1199;\n\t\tif \(y > 1919\)\n\t\t\ty = 1919;\n)?"
    r"\t\tinput_report_abs\(input, ABS_MT_POSITION_X, [^;]+\);\n"
    r"\t\tinput_report_abs\(input, ABS_MT_POSITION_Y, [^;]+\);",
    re.M,
)
text2, n = pat_report.subn(REPORT_NEW, text, count=1)
if n == 0:
    # Fallback: simpler two-line replace for the CW form
    text2, n = re.subn(
        r"input_report_abs\(input, ABS_MT_POSITION_X, 1919 - y\);\s*"
        r"input_report_abs\(input, ABS_MT_POSITION_Y, x\);",
        "input_report_abs(input, ABS_MT_POSITION_X, y);\n"
        "\t\tinput_report_abs(input, ABS_MT_POSITION_Y, 1199 - x);",
        text,
    )

text3, n2 = re.subn(
    r"input_set_abs_params\(input, ABS_MT_POSITION_X, 0, \d+, 0, 0\);\s*"
    r"input_set_abs_params\(input, ABS_MT_POSITION_Y, 0, \d+, 0, 0\);",
    ABS_NEW.replace("\t", "\t"),
    text2,
    count=1,
)
# ABS_NEW already has tabs; ensure clean
text3 = text3.replace(
    ABS_NEW.strip() if False else "",
    "",
    1,
) if False else text3

path.write_text(text3)
print(f"ft8203: CCW landscape applied (report_re={n} abs_re={n2})")
if n == 0:
    sys.exit("failed to rewrite report path")
