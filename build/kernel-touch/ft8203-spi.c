// SPDX-License-Identifier: GPL-2.0-only
/*
 * FocalTech FT8203 touchscreen on SPI.
 *
 * Coordinates are reported in the panel native portrait space (1200x1920).
 * No rotation or inversion in-driver.
 *
 * The FT8203 has no onboard flash: its operating firmware lives in PRAM,
 * which is volatile and is wiped by every reset/power cycle. Stock Android
 * re-uploads it on every boot before relying on the chip; this driver never
 * did, which left the chip running uncalibrated (reports noisy/ghost
 * touches). ft8203_load_firmware() below ports that upload over: enter the
 * masked ROM bootloader, write the image into PRAM, verify it with the
 * chip's own checksum engine, then start the application and confirm it is
 * actually scanning before letting probe() continue. Protocol modeled on
 * the public GPL FT8203 SPI driver for the Samsung Galaxy Tab S7 FE Lite
 * (same silicon, different host), which documents the same ROM bootloader
 * command set FocalTech uses across FT8203 products.
 */

#include <linux/delay.h>
#include <linux/firmware.h>
#include <linux/gpio/consumer.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>
#include <linux/spi/spi.h>
#include <linux/sysfs.h>
#include <linux/unaligned.h>

#define FT8203_MAX_TOUCH	10
#define FT8203_FRAME_BYTES	(2 + FT8203_MAX_TOUCH * 6)
#define FT8203_RAW_WIDTH	1600
#define FT8203_RAW_HEIGHT	2560

/* ROM bootloader protocol (ft8203_boot_xfer_*, used only during firmware
 * upload). Distinct from the app-mode 0xF3-prefixed framing ft8203_read()/
 * ft8203_write() use for steady-state touch reports below.
 */
#define FT8203_BOOT_CMD_WRITE		0x00
#define FT8203_BOOT_CMD_READ		0xa0
#define FT8203_BOOT_DUMMY_LEN		3
#define FT8203_BOOT_CRC_LEN		2
#define FT8203_BOOT_XFER_RETRIES	3

#define FT8203_REG_ROM_ENTER		0x55
#define FT8203_REG_ROM_ID		0x90
#define FT8203_ROM_ID0			0x82
#define FT8203_ROM_ID1			0x01

/*
 * FocalTech's actual production driver (focaltech_touch/focaltech_flash.c,
 * from Google's Nest kernel tree -- real vendor code, not reverse
 * engineered) arms bootloader mode with a two-write unlock sequence before
 * anything else: write 0xAA then 0x55 to the chip's soft-reset/upgrade
 * register, each followed by a short settle. This 0xFC/0xAA/0x55 sequence
 * is the one widely documented across many FocalTech touch controller
 * generations, not something specific to one chip family. Our previous
 * ft8203_enter_boot() only ever wrote bare FT8203_REG_ROM_ENTER (0x55) with
 * no payload and polled for the ROM ID -- it never sent this unlock
 * sequence at all, which may be why entry never actually succeeded on real
 * xun hardware (confirmed via dmesg: ft8203_enter_boot returned -ENODEV).
 */
#define FT8203_REG_SOFT_RESET		0xFC
#define FT8203_SOFT_RESET_AA		0xAA
#define FT8203_SOFT_RESET_55		0x55
#define FT8203_REG_PRAM_ADDR		0xad
#define FT8203_REG_PRAM_DATA		0xae
#define FT8203_PRAM_CHUNK		4092
#define FT8203_REG_ECC_RANGE		0xcc
#define FT8203_REG_ECC_STATUS		0xce
#define FT8203_ECC_STATUS_DONE		0xa5
#define FT8203_REG_ECC_VALUE		0xcd
#define FT8203_REG_START_APP		0x08
#define FT8203_REG_RUN_STATE		0xa3
#define FT8203_RUN_STATE_APP		0x82
#define FT8203_REG_FW_VERSION		0xa6

#define FT8203_FW_HDR_OFFSET		0x100
#define FT8203_FW_MIN_SIZE		0x120

static const char * const ft8203_fw_names[] = {
	"focaltech_ts_fw_boe_ft8203.bin",
	"focaltech_ts_fw_huaxing_ft8203.bin",
};

struct ft8203 {
	struct spi_device *spi;
	struct input_dev *input;
	struct input_dev *wake_input;
	struct gpio_desc *reset_gpio;
	struct regulator *vdd;	/* optional AVDD-style rail, not yet in DT */
	struct regulator *vcc;	/* "vcc-supply" -- IO rail, pm6125_l9, always-on */
	struct mutex lock;
	bool gesture;
	struct delayed_work follower_work;
	struct device_link *panel_link;

	/* Raw-command sysfs debug interface (see ft8203_debug_group below). */
	u8 dbg_buf[64];
	size_t dbg_len;
	int dbg_ret;

	/* Relative "mouse simulation" mode state -- see mouse_mode param. */
	bool mouse;		/* snapshot of mouse_mode taken at probe time */
	int prev_x, prev_y;
	bool have_prev;
	bool btn_down;
};

/*
 * Report touch as relative pointer movement (REL_X/REL_Y + BTN_LEFT) instead
 * of absolute touchscreen coordinates (ABS_MT_POSITION_X/Y). A swipe moves
 * the cursor rather than needing exact position-to-pixel mapping, so this
 * sidesteps rotation/calibration entirely -- useful for confirming the chip
 * is reporting usable deltas at all before chasing exact absolute alignment.
 *
 * This is a BOOT-TIME choice, not a live runtime switch: the input device's
 * registered capabilities are fixed in probe() to match whichever mode is
 * selected at that point, because a single input device advertising BOTH
 * absolute multitouch (ABS_MT_*) and relative pointer (REL_X/REL_Y +
 * BTN_LEFT) capabilities confuses libinput/compositors into treating it as
 * a mouse even while it's reporting absolute touch -- that's what caused
 * "there's a mouse cursor but drag doesn't work" with mouse mode off.
 * Flip it via the kernel command line (ft8203_spi.mouse_mode=1, wired up in
 * build-xun.sh via the workflow's "Touch mode" input) or, before the driver
 * has probed, via:
 *   echo 1 > /sys/module/ft8203_spi/parameters/mouse_mode
 * Changing it after probe has already run has no effect until the next
 * probe (reboot, or unbind/rebind the spi device).
 */
static bool mouse_mode;
module_param(mouse_mode, bool, 0644);
MODULE_PARM_DESC(mouse_mode,
		  "report touch as relative mouse movement (REL_X/REL_Y + BTN_LEFT) "
		  "instead of absolute touchscreen coordinates -- boot-time only, "
		  "see comment above for why");

/* CRC-16 (reflected CCITT, poly 0x8408), bit-by-bit over 8-bit SPI read
 * bytes. Used to validate boot-mode read replies against their trailing
 * 2-byte CRC.
 */
static u16 ft8203_crc16_bytes(u16 crc, const u8 *data, size_t len)
{
	size_t i;
	int b;

	for (i = 0; i < len; i++) {
		crc ^= data[i];
		for (b = 0; b < 8; b++) {
			if (crc & 1)
				crc = (crc >> 1) ^ 0x8408;
			else
				crc >>= 1;
		}
	}
	return crc;
}

/* Same polynomial, applied big-endian-16-bit-word-at-a-time over the
 * firmware image, matching the chip's own PRAM checksum engine
 * (ft8203_ecc_chip()) so the two can be compared directly.
 */
static u16 ft8203_ecc_host(const u8 *data, size_t len)
{
	u16 ecc = 0;
	size_t i;
	int b;

	for (i = 0; i + 1 < len; i += 2) {
		ecc ^= ((u16)data[i] << 8) | data[i + 1];
		for (b = 0; b < 16; b++) {
			if (ecc & 1)
				ecc = (ecc >> 1) ^ 0x8408;
			else
				ecc >>= 1;
		}
	}
	return ecc;
}

static int ft8203_boot_write(struct ft8203 *ts, u8 addr, const u8 *buf, u16 len)
{
	u8 hdr[4 + FT8203_BOOT_DUMMY_LEN] = {
		addr, FT8203_BOOT_CMD_WRITE, len >> 8, len & 0xff,
	};
	struct spi_transfer xfers[2] = {
		{ .tx_buf = hdr, .len = sizeof(hdr) },
		{ .tx_buf = buf, .len = len },
	};
	struct spi_message msg;
	int ret, tries;

	for (tries = 0; tries < FT8203_BOOT_XFER_RETRIES; tries++) {
		spi_message_init_with_transfers(&msg, xfers, len ? 2 : 1);
		ret = spi_sync(ts->spi, &msg);
		if (!ret)
			return 0;
		usleep_range(150, 200);
	}
	return ret;
}

/*
 * Raw, unwrapped SPI primitives -- no address/command-type/length/dummy
 * header at all, unlike ft8203_boot_write/read above. The real Xiaomi
 * vendor driver's bootloader-entry handshake (fts_hardware_reset_to_boot(),
 * ported into ft8203_enter_boot_new() below) sends exactly the bytes given
 * with nothing added, so it needs these instead of the wrapped versions.
 */
static int ft8203_raw_write(struct ft8203 *ts, const u8 *buf, size_t len)
{
	return spi_write(ts->spi, buf, len);
}

static int ft8203_raw_read(struct ft8203 *ts, const u8 *cmd, size_t cmd_len,
			    u8 *resp, size_t resp_len)
{
	struct spi_transfer xfers[2] = {
		{ .tx_buf = cmd, .len = cmd_len },
		{ .rx_buf = resp, .len = resp_len },
	};
	struct spi_message msg;

	spi_message_init_with_transfers(&msg, xfers, 2);
	return spi_sync(ts->spi, &msg);
}

static int ft8203_boot_read(struct ft8203 *ts, u8 addr, u8 *buf, u16 len)
{
	u8 hdr[4 + FT8203_BOOT_DUMMY_LEN] = {
		addr, FT8203_BOOT_CMD_READ, len >> 8, len & 0xff,
	};
	u8 rx[64 + FT8203_BOOT_CRC_LEN];
	struct spi_transfer xfers[2] = {
		{ .tx_buf = hdr, .len = sizeof(hdr) },
		{ .rx_buf = rx, .len = len + FT8203_BOOT_CRC_LEN },
	};
	struct spi_message msg;
	int ret, tries;
	u16 crc_calc, crc_rx;

	if (len + FT8203_BOOT_CRC_LEN > sizeof(rx))
		return -EINVAL;

	for (tries = 0; tries < FT8203_BOOT_XFER_RETRIES; tries++) {
		spi_message_init_with_transfers(&msg, xfers, 2);
		ret = spi_sync(ts->spi, &msg);
		if (ret) {
			usleep_range(150, 200);
			continue;
		}
		if (rx[0] & 0xa0) {
			ret = -EIO;
			usleep_range(150, 200);
			continue;
		}
		crc_calc = ft8203_crc16_bytes(0xffff, rx, len);
		crc_rx = rx[len] | ((u16)rx[len + 1] << 8);
		if (crc_calc != crc_rx) {
			ret = -EIO;
			usleep_range(150, 200);
			continue;
		}
		memcpy(buf, rx, len);
		return 0;
	}
	return ret;
}

/* Defined further down; forward-declared so ft8203_enter_boot() can share
 * the same vendor-matched reset/settle timing as probe() and the debug
 * "reset" sysfs attribute instead of its own much shorter one.
 */
static void ft8203_reset_pulse(struct ft8203 *ts);

/* Defined further down (steady-state touch-report framing); forward-declared
 * so ft8203_enter_boot_f3() below can use them too. See that function's
 * comment for why: manual sysfs testing on real hardware showed this is the
 * only framing that gets ANY live response out of this chip at all -- the
 * raw/unwrapped bytes ft8203_enter_boot_new() sends, and the length+CRC
 * "boot mode" header ft8203_enter_boot_old() sends via ft8203_boot_write/
 * read, both come back as flat zeros or CRC failures every time, regardless
 * of SPI clock mode (0-3, all tried). Writing the old path's register-0xFC
 * AA/55 unlock through this 0xF3-wrapped framing instead, by hand via the
 * app_write debug sysfs attribute, visibly changed the chip's run_state
 * register (0xa3) from 0xff to 0x00 -- the only state change any protocol
 * attempt has produced on real xun hardware so far.
 */
static int ft8203_read(struct ft8203 *ts, u8 reg, u8 *buf, size_t len);
static int ft8203_write(struct ft8203 *ts, u8 reg, const u8 *buf, size_t len);

/*
 * "New"-generation entry path, ported from the actual Xiaomi SM6225 vendor
 * kernel's fts_hardware_reset_to_boot() (qcom/opensource/touch-drivers/
 * focaltech_touch/focaltech_flash.c, android_kernel_xiaomi_sm6225-modules --
 * real shipped vendor driver source, not reverse engineered). This is the
 * path FocalTech's generic driver picks for newer chips (upgspec_version >=
 * UPGRADE_SPEC_V_1_0); FT8203 being one of the newer FT8xxx-generation
 * chips, this is the more likely match, and its timing is dramatically
 * shorter than the "old"-path register-0xFC AA/55 sequence we tried first
 * (which is kept below as ft8203_enter_boot_old(), as a fallback):
 *   reset, settle ~10ms
 *   write raw {0x55, 0xAA} as ONE transaction (not two separate writes),
 *     settle ~8-9ms
 *   write/read ROM ID (0x90 + 3 dummy bytes -> 2 response bytes)
 *   retry up to 20x, with a short ~1-2ms gap between tries and a full
 *     reset again halfway through (attempt 10)
 * The real driver only checks response byte [1] against a chip-specific
 * constant (0xB2 for the FT3518 this tree ships); we keep checking both
 * bytes against FT8203_ROM_ID0/1 (0x82, 0x01), sourced from the actual
 * same-silicon Tab S7 FE Lite driver, since that pair is chip-specific to
 * FT8203 itself rather than to this particular Xiaomi tree's chip.
 *
 * The key bug this fixes vs. our previous attempt: the unlock write needs
 * a non-empty one-byte payload (0xAA) alongside the 0x55 -- "reg=0x55,
 * buf=NULL, len=0" (what we had) puts only a single byte on the wire,
 * while "reg=0x55, buf={0xAA}, len=1" puts the full two-byte {0x55, 0xAA}
 * sequence the real chip expects.
 */
static int ft8203_enter_boot_new(struct ft8203 *ts)
{
	int attempt;
	u8 id[2] = { 0, 0 };
	u8 unlock_cmd[2] = { 0x55, 0xAA };
	u8 id_cmd[4] = { FT8203_REG_ROM_ID, 0x00, 0x00, 0x00 };

	ft8203_reset_pulse(ts);

	for (attempt = 0; attempt < 20; attempt++) {
		int wret, rret;

		wret = ft8203_raw_write(ts, unlock_cmd, sizeof(unlock_cmd));
		if (wret)
			goto retry;
		usleep_range(8000, 9000);

		rret = ft8203_raw_read(ts, id_cmd, sizeof(id_cmd), id, sizeof(id));
		if (attempt < 3 || attempt == 19)
			dev_info(&ts->spi->dev,
				 "ft8203: enter_boot_new attempt %d: wret=%d rret=%d id=%02x %02x\n",
				 attempt, wret, rret, id[0], id[1]);
		if (rret)
			goto retry;
		if (id[0] == FT8203_ROM_ID0 && id[1] == FT8203_ROM_ID1)
			return 0;
retry:
		usleep_range(1000, 2000);
		if (attempt == 10)
			ft8203_reset_pulse(ts);
	}
	return -ENODEV;
}

/*
 * "Old"-generation entry path: FocalTech's register-0xFC AA/55 unlock
 * sequence (fts_fwupg_reset_to_boot() in the same vendor source), kept as a
 * fallback in case FT8203 actually needs this path instead of the "new"
 * one above.
 */
static int ft8203_enter_boot_old(struct ft8203 *ts)
{
	int attempt, poll;
	u8 id[2];
	u8 unlock;

	for (attempt = 0; attempt < 30; attempt++) {
		ft8203_reset_pulse(ts);

		unlock = FT8203_SOFT_RESET_AA;
		if (ft8203_boot_write(ts, FT8203_REG_SOFT_RESET, &unlock, 1))
			goto next_attempt;
		msleep(10);
		unlock = FT8203_SOFT_RESET_55;
		if (ft8203_boot_write(ts, FT8203_REG_SOFT_RESET, &unlock, 1))
			goto next_attempt;
		msleep(80);	/* FTS_DELAY_UPGRADE_RESET from the real driver */

		for (poll = 0; poll < 30; poll++) {
			if (ft8203_boot_write(ts, FT8203_REG_ROM_ENTER, NULL, 0))
				goto next_attempt;
			msleep(8);
			if (ft8203_boot_read(ts, FT8203_REG_ROM_ID, id, sizeof(id)))
				goto next_attempt;
			if (id[0] == FT8203_ROM_ID0 && id[1] == FT8203_ROM_ID1)
				return 0;
			usleep_range(1000, 2000);
		}
next_attempt:
		;
	}
	return -ENODEV;
}

/*
 * Same logical unlock+poll sequence as ft8203_enter_boot_old() (register-
 * 0xFC AA/55 unlock, then repeatedly write FT8203_REG_ROM_ENTER and poll the
 * ROM ID), but sent through the 0xF3-wrapped ft8203_write()/ft8203_read()
 * framing instead of the length+CRC "boot mode" header -- see the forward
 * declaration comment above for why: that framing is the only one observed
 * to actually move anything on this chip.
 */
static int ft8203_enter_boot_f3(struct ft8203 *ts)
{
	int attempt, poll;
	u8 id[2] = { 0, 0 };
	u8 unlock;

	for (attempt = 0; attempt < 30; attempt++) {
		ft8203_reset_pulse(ts);

		unlock = FT8203_SOFT_RESET_AA;
		if (ft8203_write(ts, FT8203_REG_SOFT_RESET, &unlock, 1))
			goto next_attempt;
		msleep(10);
		unlock = FT8203_SOFT_RESET_55;
		if (ft8203_write(ts, FT8203_REG_SOFT_RESET, &unlock, 1))
			goto next_attempt;
		msleep(80);	/* FTS_DELAY_UPGRADE_RESET from the real driver */

		for (poll = 0; poll < 30; poll++) {
			if (ft8203_write(ts, FT8203_REG_ROM_ENTER, NULL, 0))
				goto next_attempt;
			msleep(8);
			if (ft8203_read(ts, FT8203_REG_ROM_ID, id, sizeof(id)))
				goto next_attempt;
			if (attempt == 0 && poll < 5)
				dev_info(&ts->spi->dev,
					 "ft8203: enter_boot_f3 attempt %d poll %d: id=%02x %02x\n",
					 attempt, poll, id[0], id[1]);
			if (id[0] == FT8203_ROM_ID0 && id[1] == FT8203_ROM_ID1)
				return 0;
			usleep_range(1000, 2000);
		}
next_attempt:
		;
	}
	return -ENODEV;
}

static int ft8203_enter_boot(struct ft8203 *ts)
{
	int ret = ft8203_enter_boot_f3(ts);

	if (!ret)
		return 0;

	dev_info(&ts->spi->dev,
		 "ft8203: F3-wrapped boot entry failed (%d), trying the \"new\" "
		 "raw-byte path\n", ret);
	ret = ft8203_enter_boot_new(ts);
	if (!ret)
		return 0;

	dev_info(&ts->spi->dev,
		 "ft8203: \"new\"-path boot entry failed (%d), trying the "
		 "\"old\"-path register-0xFC sequence\n", ret);
	return ft8203_enter_boot_old(ts);
}

static int ft8203_write_pram(struct ft8203 *ts, const u8 *img, u32 off, u32 len)
{
	u32 sent = 0;

	while (sent < len) {
		u32 chunk = min_t(u32, FT8203_PRAM_CHUNK, len - sent);
		u32 addr = off + sent;
		u8 addr_be[3] = { addr >> 16, addr >> 8, addr };
		int ret;

		ret = ft8203_boot_write(ts, FT8203_REG_PRAM_ADDR, addr_be, 3);
		if (ret)
			return ret;
		ret = ft8203_boot_write(ts, FT8203_REG_PRAM_DATA, img + sent, chunk);
		if (ret)
			return ret;
		sent += chunk;
	}
	return 0;
}

static int ft8203_ecc_chip(struct ft8203 *ts, u32 off, u32 len, u16 *ecc_out)
{
	u8 range[6] = {
		off >> 16, off >> 8, off, len >> 16, len >> 8, len,
	};
	u8 status, ecc_be[2];
	int ret, poll;

	ret = ft8203_boot_write(ts, FT8203_REG_ECC_RANGE, range, sizeof(range));
	if (ret)
		return ret;
	msleep(3);

	for (poll = 0; poll < 100; poll++) {
		ret = ft8203_boot_read(ts, FT8203_REG_ECC_STATUS, &status, 1);
		if (!ret && status == FT8203_ECC_STATUS_DONE)
			break;
		usleep_range(1000, 2000);
	}
	if (poll == 100)
		return -ETIMEDOUT;

	ret = ft8203_boot_read(ts, FT8203_REG_ECC_VALUE, ecc_be, 2);
	if (ret)
		return ret;
	*ecc_out = ((u16)ecc_be[0] << 8) | ecc_be[1];
	return 0;
}

static int ft8203_start_app(struct ft8203 *ts)
{
	int ret, poll;
	u8 state;

	ret = ft8203_boot_write(ts, FT8203_REG_START_APP, NULL, 0);
	if (ret)
		return ret;
	msleep(100);

	for (poll = 0; poll < 20; poll++) {
		ret = ft8203_boot_read(ts, FT8203_REG_RUN_STATE, &state, 1);
		if (!ret && state == FT8203_RUN_STATE_APP)
			break;
		msleep(50);
	}
	if (poll == 20)
		return -ETIMEDOUT;

	return 0;
}

static int ft8203_try_one_firmware(struct ft8203 *ts, const struct firmware *fw)
{
	u16 len_be, len_inv, byte_len, ecc_host, ecc_chip;
	int ret;

	if (fw->size < FT8203_FW_MIN_SIZE)
		return -EINVAL;

	len_be = get_unaligned_be16(fw->data + FT8203_FW_HDR_OFFSET);
	len_inv = get_unaligned_be16(fw->data + FT8203_FW_HDR_OFFSET + 2);
	if ((u16)(len_be + len_inv) != 0xffff)
		return -EINVAL;
	byte_len = len_be * 2;
	if (byte_len == 0 || byte_len > fw->size)
		return -EINVAL;

	ret = ft8203_enter_boot(ts);
	if (ret)
		return ret;

	ret = ft8203_write_pram(ts, fw->data, 0, byte_len);
	if (ret)
		return ret;

	ecc_host = ft8203_ecc_host(fw->data, byte_len);
	ret = ft8203_ecc_chip(ts, 0, byte_len, &ecc_chip);
	if (ret)
		return ret;
	if (ecc_host != ecc_chip)
		return -EIO;

	return ft8203_start_app(ts);
}

/* Upload firmware into the FT8203's volatile PRAM. Must run before any
 * touch IRQ is enabled, and before relying on ft8203_read() for touch
 * reports: without this, the chip runs uncalibrated. Firmware files were
 * confirmed byte-identical to the real device's /odm/firmware images; the
 * BOE/Huaxing panel variant fitted isn't known in code, so both are tried
 * in turn and whichever one's checksum verifies wins. Failure here is
 * logged but does not fail probe(): the touchscreen stays non-functional
 * rather than blocking boot.
 */
static void ft8203_load_firmware(struct ft8203 *ts)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(ft8203_fw_names); i++) {
		const struct firmware *fw;
		int ret;

		ret = request_firmware(&fw, ft8203_fw_names[i], &ts->spi->dev);
		if (ret) {
			dev_warn(&ts->spi->dev, "ft8203: %s not found (%d)\n",
				 ft8203_fw_names[i], ret);
			continue;
		}

		ret = ft8203_try_one_firmware(ts, fw);
		release_firmware(fw);
		if (!ret) {
			dev_info(&ts->spi->dev,
				 "ft8203: firmware loaded (%s)\n",
				 ft8203_fw_names[i]);
			return;
		}
		dev_warn(&ts->spi->dev,
			 "ft8203: %s rejected by chip (%d), trying next\n",
			 ft8203_fw_names[i], ret);
	}

	dev_err(&ts->spi->dev,
		"ft8203: no firmware variant loaded; touch will be uncalibrated\n");
}

/*
 * Single-shot, low-risk recovery attempt: the failed firmware-load attempts
 * (see ft8203_load_firmware() above, no longer called from probe()) wrote
 * FT8203_REG_ROM_ENTER (0x55) up to 1800 times without ever completing a
 * firmware write or sending the "start application" command. If that left
 * the chip sitting in its ROM bootloader waiting for either, it should
 * still respond to the one command that gets it back out: write
 * FT8203_REG_START_APP (0x08) with no payload. Unlike ft8203_load_firmware(),
 * this performs no reset pulse (so it doesn't risk re-triggering whatever
 * caused the original problem) and no firmware write -- a single short SPI
 * write plus one status read, using the same boot-mode framing. Logged
 * either way; never fails probe().
 */
static void ft8203_try_exit_bootloader(struct ft8203 *ts)
{
	u8 state = 0;
	int ret;

	ret = ft8203_boot_write(ts, FT8203_REG_START_APP, NULL, 0);
	if (ret) {
		dev_info(&ts->spi->dev,
			 "ft8203: start-app write failed (%d), chip likely not in bootloader\n",
			 ret);
		return;
	}
	msleep(100);

	ret = ft8203_boot_read(ts, FT8203_REG_RUN_STATE, &state, 1);
	if (!ret && state == FT8203_RUN_STATE_APP)
		dev_info(&ts->spi->dev,
			 "ft8203: chip acked start-app (state=0x%02x); was likely stuck in bootloader\n",
			 state);
	else
		dev_info(&ts->spi->dev,
			 "ft8203: start-app write sent, no bootloader ack (ret=%d state=0x%02x) -- chip probably wasn't in bootloader\n",
			 ret, state);
}

static int ft8203_read(struct ft8203 *ts, u8 reg, u8 *buf, size_t len)
{
	u8 cmd[2] = { 0xF3, 0x01 };
	struct spi_transfer xfers[3] = {
		{ .tx_buf = cmd, .len = 2 },
		{ .tx_buf = &reg, .len = 1 },
		{ .rx_buf = buf, .len = len },
	};
	struct spi_message msg;

	spi_message_init_with_transfers(&msg, xfers, 3);
	return spi_sync(ts->spi, &msg);
}

static int ft8203_write(struct ft8203 *ts, u8 reg, const u8 *buf, size_t len)
{
	u8 cmd[2] = { 0xF3, 0x00 };
	struct spi_transfer xfers[3] = {
		{ .tx_buf = cmd, .len = 2 },
		{ .tx_buf = &reg, .len = 1 },
		{ .tx_buf = buf, .len = len },
	};
	struct spi_message msg;

	spi_message_init_with_transfers(&msg, xfers, 3);
	return spi_sync(ts->spi, &msg);
}

/*
 * Quick "is anything alive on the bus" check, logged clearly so liveness
 * doesn't have to be inferred from /proc/interrupts after the fact. Reads
 * the run-state register (0xa3) in app-mode framing; FT8203_RUN_STATE_APP
 * (0x82) means the application firmware is up and scanning. Any other
 * non-error value still means *something* answered on SPI, which rules
 * out a dead/unpowered/miswired chip even if the value isn't the expected
 * one yet.
 */
static void ft8203_log_presence(struct ft8203 *ts)
{
	u8 state = 0xff;
	int ret = ft8203_read(ts, FT8203_REG_RUN_STATE, &state, 1);

	if (ret)
		dev_info(&ts->spi->dev,
			 "ft8203: presence check failed (%d) -- chip not answering on SPI\n",
			 ret);
	else if (state == FT8203_RUN_STATE_APP)
		dev_info(&ts->spi->dev,
			 "ft8203: presence check ok, run_state=0x%02x (app running)\n",
			 state);
	else
		dev_info(&ts->spi->dev,
			 "ft8203: chip answered but run_state=0x%02x (not the expected 0x%02x)\n",
			 state, FT8203_RUN_STATE_APP);
}

/*
 * Reset-pulse + settle timing, unified across every call site (probe, the
 * sysfs "reset" debug attribute). Matches the pattern used by FocalTech's
 * own vendor drivers for sibling chips in the same family
 * (focaltech_touch_ft8201, ft8716/focaltech_core.c): assert reset, release
 * it, then settle for ~200ms before the first bus transaction, plus
 * another ~200ms "soft reset" settle on top of that. We were previously
 * only waiting 50ms total here, well short of what FocalTech's own
 * drivers rely on.
 */
static void ft8203_reset_pulse(struct ft8203 *ts)
{
	if (!ts->reset_gpio)
		return;

	gpiod_set_value_cansleep(ts->reset_gpio, 1);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ts->reset_gpio, 0);
	msleep(200);
	msleep(200);
}

static void ft8203_report(struct ft8203 *ts, const u8 *buf)
{
	struct input_dev *input = ts->input;
	unsigned int points = buf[1] & 0x0f;
	bool touch = false;
	bool mouse = ts->mouse;	/* fixed at probe time, see struct ft8203::mouse */
	bool mouse_point_seen = false;
	unsigned int i;

	if (points > FT8203_MAX_TOUCH)
		return;

	for (i = 0; i < FT8203_MAX_TOUCH; i++) {
		const u8 *p = &buf[2 + i * 6];
		unsigned int event = p[0] >> 6;
		unsigned int id = p[2] >> 4;
		unsigned int x, y;
		int lx, ly;

		if (id >= FT8203_MAX_TOUCH)
			break;

		if (!mouse) {
			input_mt_slot(input, id);

			if (event == 1 || (p[0] & 0x10)) {
				input_mt_report_slot_state(input, MT_TOOL_FINGER, false);
				continue;
			}
		} else if (event == 1 || (p[0] & 0x10)) {
			continue;
		}
		if (event != 0 && event != 2)
			continue;

		x = ((p[0] & 0x0f) << 8) | p[1];
		y = ((p[2] & 0x0f) << 8) | p[3];
		if (x >= FT8203_RAW_WIDTH || y >= FT8203_RAW_HEIGHT)
			continue;

		touch = true;

		/*
		 * CCW map into landscape chassis (1920x1200):
		 *   X = portrait_Y
		 *   Y = 1199 - portrait_X
		 * (Panel's native space is portrait 1200x1920; the chassis
		 * and the DTS's forced display rotation are landscape.)
		 */
		x = x * 1200 / FT8203_RAW_WIDTH;
		y = y * 1920 / FT8203_RAW_HEIGHT;
		if (x > 1199)
			x = 1199;
		if (y > 1919)
			y = 1919;
		lx = y;
		ly = 1199 - (int)x;

		if (!mouse) {
			input_mt_report_slot_state(input, MT_TOOL_FINGER, true);
			input_report_abs(input, ABS_MT_POSITION_X, lx);
			input_report_abs(input, ABS_MT_POSITION_Y, ly);
			continue;
		}

		/*
		 * Mouse-simulation mode: only the first touch point drives the
		 * cursor (relative deltas), everything else is ignored. A
		 * fresh touch-down just anchors the start position -- no jump
		 * on first contact.
		 */
		if (mouse_point_seen)
			continue;
		mouse_point_seen = true;

		if (ts->have_prev) {
			int dx = lx - ts->prev_x;
			int dy = ly - ts->prev_y;

			if (dx)
				input_report_rel(input, REL_X, dx);
			if (dy)
				input_report_rel(input, REL_Y, dy);
		}
		ts->prev_x = lx;
		ts->prev_y = ly;
		ts->have_prev = true;
	}

	if (mouse) {
		if (touch != ts->btn_down) {
			input_report_key(input, BTN_LEFT, touch);
			ts->btn_down = touch;
		}
		if (!touch)
			ts->have_prev = false;
	} else {
		input_report_key(input, BTN_TOUCH, touch);
		input_mt_sync_frame(input);
	}
	input_sync(input);
}

static irqreturn_t ft8203_irq(int irq, void *dev_id)
{
	struct ft8203 *ts = dev_id;
	u8 buf[FT8203_FRAME_BYTES];
	int ret;

	mutex_lock(&ts->lock);
	ret = ft8203_read(ts, 0x01, buf, sizeof(buf));
	mutex_unlock(&ts->lock);
	if (ret)
		return IRQ_HANDLED;

	ft8203_report(ts, buf);
	return IRQ_HANDLED;
}

/*
 * Raw-command sysfs debug interface. Lets userspace try SPI commands/
 * addresses directly over SSH/telnet without a kernel rebuild per attempt --
 * every protocol guess so far has cost a full build+flash+reboot cycle just
 * to find out it was wrong. After this lands once, further iteration is:
 *
 *   echo "55" > boot_write          # write FT8203_REG_ROM_ENTER, no payload
 *   echo "90 2" > boot_read; cat boot_read   # read 2 bytes from 0x90
 *   echo 1 > reset                  # pulse the reset GPIO
 *   cat enter_boot                  # run ft8203_enter_boot(), see the result
 *
 * boot_write/boot_read use the ROM-bootloader framing (ft8203_boot_write/
 * read); app_write/app_read use the steady-state 0xF3-prefixed framing
 * (ft8203_write/read) that ft8203_irq() uses for touch reports.
 */
static ssize_t ft8203_hex_bytes_store(const char *buf, size_t count,
				       u8 *first, u8 *rest, size_t rest_max,
				       size_t *rest_len)
{
	unsigned int val;
	int n, consumed = 0;
	size_t i = 0;

	if (sscanf(buf, "%x%n", &val, &n) != 1)
		return -EINVAL;
	*first = val;
	consumed = n;

	while (i < rest_max) {
		int used;

		if (sscanf(buf + consumed, "%x%n", &val, &used) != 1)
			break;
		rest[i++] = val;
		consumed += used;
	}
	*rest_len = i;
	return count;
}

static ssize_t boot_write_store(struct device *dev, struct device_attribute *a,
				 const char *buf, size_t count)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	u8 addr, payload[61];
	size_t len;
	ssize_t ret = ft8203_hex_bytes_store(buf, count, &addr, payload,
					     sizeof(payload), &len);
	if (ret < 0)
		return ret;
	ts->dbg_ret = ft8203_boot_write(ts, addr, len ? payload : NULL, len);
	dev_info(dev, "ft8203-dbg: boot_write(0x%02x, len=%zu) = %d\n",
		 addr, len, ts->dbg_ret);
	return count;
}
static DEVICE_ATTR_WO(boot_write);

static ssize_t boot_read_store(struct device *dev, struct device_attribute *a,
				const char *buf, size_t count)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	unsigned int addr, len;

	if (sscanf(buf, "%x %u", &addr, &len) != 2 || len > sizeof(ts->dbg_buf))
		return -EINVAL;
	ts->dbg_len = len;
	ts->dbg_ret = ft8203_boot_read(ts, addr, ts->dbg_buf, len);
	dev_info(dev, "ft8203-dbg: boot_read(0x%02x, len=%u) = %d\n",
		 addr, len, ts->dbg_ret);
	return count;
}
static ssize_t boot_read_show(struct device *dev, struct device_attribute *a,
			       char *buf)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	ssize_t off = 0;
	size_t i;

	off += sysfs_emit_at(buf, off, "ret=%d data=", ts->dbg_ret);
	for (i = 0; i < ts->dbg_len; i++)
		off += sysfs_emit_at(buf, off, "%02x ", ts->dbg_buf[i]);
	off += sysfs_emit_at(buf, off, "\n");
	return off;
}
static DEVICE_ATTR_RW(boot_read);

static ssize_t app_write_store(struct device *dev, struct device_attribute *a,
				const char *buf, size_t count)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	u8 reg, payload[61];
	size_t len;
	ssize_t ret = ft8203_hex_bytes_store(buf, count, &reg, payload,
					     sizeof(payload), &len);
	if (ret < 0)
		return ret;
	ts->dbg_ret = ft8203_write(ts, reg, payload, len);
	dev_info(dev, "ft8203-dbg: app_write(0x%02x, len=%zu) = %d\n",
		 reg, len, ts->dbg_ret);
	return count;
}
static DEVICE_ATTR_WO(app_write);

static ssize_t app_read_store(struct device *dev, struct device_attribute *a,
			       const char *buf, size_t count)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	unsigned int reg, len;

	if (sscanf(buf, "%x %u", &reg, &len) != 2 || len > sizeof(ts->dbg_buf))
		return -EINVAL;
	ts->dbg_len = len;
	ts->dbg_ret = ft8203_read(ts, reg, ts->dbg_buf, len);
	dev_info(dev, "ft8203-dbg: app_read(0x%02x, len=%u) = %d\n",
		 reg, len, ts->dbg_ret);
	return count;
}
static ssize_t app_read_show(struct device *dev, struct device_attribute *a,
			      char *buf)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	ssize_t off = 0;
	size_t i;

	off += sysfs_emit_at(buf, off, "ret=%d data=", ts->dbg_ret);
	for (i = 0; i < ts->dbg_len; i++)
		off += sysfs_emit_at(buf, off, "%02x ", ts->dbg_buf[i]);
	off += sysfs_emit_at(buf, off, "\n");
	return off;
}
static DEVICE_ATTR_RW(app_read);

static ssize_t reset_store(struct device *dev, struct device_attribute *a,
			    const char *buf, size_t count)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));

	ft8203_reset_pulse(ts);
	dev_info(dev, "ft8203-dbg: reset pulsed\n");
	return count;
}
static DEVICE_ATTR_WO(reset);

/*
 * Every protocol attempt so far (register-0xFC AA/55, raw {0x55,0xAA}+ID
 * read) sends successfully (no SPI bus errors) but never gets the expected
 * reply bytes back -- consistent with every bit being sampled on the wrong
 * clock edge rather than with the command sequence itself being wrong. Our
 * devicetree touch node sets no spi-cpha/spi-cpol, so the controller runs
 * SPI Mode 0 by default; if FT8203 actually needs Mode 1/2/3, that alone
 * would explain every attempt failing identically. This lets us try all
 * four without a rebuild+flash per mode:
 *   echo 0 > spi_mode; cat enter_boot    # Mode 0 (CPOL=0 CPHA=0) -- default
 *   echo 1 > spi_mode; cat enter_boot    # Mode 1 (CPOL=0 CPHA=1)
 *   echo 2 > spi_mode; cat enter_boot    # Mode 2 (CPOL=1 CPHA=0)
 *   echo 3 > spi_mode; cat enter_boot    # Mode 3 (CPOL=1 CPHA=1)
 * Watch dmesg after each: ft8203_enter_boot_new logs the actual id[] bytes
 * it gets back on its first few attempts, so even a non-matching mode shows
 * real data to compare against 82 01 instead of just a bare failure.
 */
static ssize_t spi_mode_show(struct device *dev, struct device_attribute *a,
			      char *buf)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	unsigned int mode = ts->spi->mode & 0x3;

	return sysfs_emit(buf, "%u (CPOL=%d CPHA=%d)\n", mode,
			   !!(mode & SPI_CPOL), !!(mode & SPI_CPHA));
}
static ssize_t spi_mode_store(struct device *dev, struct device_attribute *a,
			       const char *buf, size_t count)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	unsigned int mode;
	int ret;

	if (kstrtouint(buf, 0, &mode) || mode > 3)
		return -EINVAL;

	ts->spi->mode = (ts->spi->mode & ~0x3u) | mode;
	ret = spi_setup(ts->spi);
	if (ret) {
		dev_warn(dev, "ft8203-dbg: spi_setup(mode=%u) failed (%d)\n",
			 mode, ret);
		return ret;
	}

	dev_info(dev, "ft8203-dbg: spi mode set to %u (CPOL=%d CPHA=%d)\n",
		 mode, !!(mode & SPI_CPOL), !!(mode & SPI_CPHA));
	return count;
}
static DEVICE_ATTR_RW(spi_mode);

static ssize_t enter_boot_show(struct device *dev, struct device_attribute *a,
				char *buf)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));
	int ret = ft8203_enter_boot(ts);

	return sysfs_emit(buf, "ft8203_enter_boot() = %d\n", ret);
}
static DEVICE_ATTR_RO(enter_boot);

static ssize_t exit_boot_show(struct device *dev, struct device_attribute *a,
			       char *buf)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));

	ft8203_try_exit_bootloader(ts);
	return sysfs_emit(buf, "see dmesg for result\n");
}
static DEVICE_ATTR_RO(exit_boot);

/*
 * Manual trigger only -- NOT called automatically in probe(). The last time
 * this ran unconditionally at every boot it regressed touch from
 * noisy/ghost to completely unresponsive, before the real root cause (the
 * missing devicetree node, then the dwc3 default-host-mode bug) was found.
 * Now that enter_boot has the real FocalTech unlock sequence, this lets it
 * be tried interactively -- cat enter_boot first to confirm the ROM ID
 * actually acks, then cat load_firmware -- without needing a rebuild+flash
 * per attempt.
 */
static ssize_t load_firmware_show(struct device *dev,
				   struct device_attribute *a, char *buf)
{
	struct ft8203 *ts = spi_get_drvdata(to_spi_device(dev));

	ft8203_load_firmware(ts);
	return sysfs_emit(buf, "see dmesg for result\n");
}
static DEVICE_ATTR_RO(load_firmware);

static struct attribute *ft8203_debug_attrs[] = {
	&dev_attr_boot_write.attr,
	&dev_attr_boot_read.attr,
	&dev_attr_app_write.attr,
	&dev_attr_app_read.attr,
	&dev_attr_reset.attr,
	&dev_attr_spi_mode.attr,
	&dev_attr_enter_boot.attr,
	&dev_attr_exit_boot.attr,
	&dev_attr_load_firmware.attr,
	NULL,
};
static const struct attribute_group ft8203_debug_group = {
	.name = "ft8203_debug",
	.attrs = ft8203_debug_attrs,
};

static int ft8203_probe(struct spi_device *spi)
{
	struct ft8203 *ts;
	struct input_dev *input;
	u8 high = 0, low = 0;
	int ret;

	ts = devm_kzalloc(&spi->dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	ts->spi = spi;
	mutex_init(&ts->lock);
	spi_set_drvdata(spi, ts);

	ret = sysfs_create_group(&spi->dev.kobj, &ft8203_debug_group);
	if (ret)
		dev_warn(&spi->dev,
			 "ft8203: failed to create debug sysfs group (%d)\n", ret);

	/*
	 * Power the chip's rails before touching reset/SPI at all -- this is
	 * the order FocalTech's own vendor drivers use for sibling chips
	 * (focaltech_touch_ft8201, ft8716/focaltech_core.c): enable supplies
	 * first, *then* run the reset sequence. "vcc" (pm6125_l9, the panel's
	 * I/O rail) is already regulator-always-on in our DT so this mostly
	 * just makes the dependency explicit, but "vdd" is requested as
	 * optional in case a dedicated AVDD-style rail gets added to the DT
	 * later -- we couldn't confirm one from the hardware we have access
	 * to, so it's not wired up in the DTS yet.
	 */
	ts->vcc = devm_regulator_get(&spi->dev, "vcc");
	if (IS_ERR(ts->vcc))
		return PTR_ERR(ts->vcc);
	ret = regulator_enable(ts->vcc);
	if (ret)
		return ret;

	ts->vdd = devm_regulator_get_optional(&spi->dev, "vdd");
	if (IS_ERR(ts->vdd)) {
		if (PTR_ERR(ts->vdd) != -ENODEV)
			return PTR_ERR(ts->vdd);
		ts->vdd = NULL;
	} else {
		ret = regulator_enable(ts->vdd);
		if (ret)
			return ret;
		dev_info(&spi->dev, "ft8203: vdd rail found in DT and enabled\n");
	}
	usleep_range(1000, 2000);

	ts->reset_gpio = devm_gpiod_get_optional(&spi->dev, "reset",
						 GPIOD_OUT_HIGH);
	if (IS_ERR(ts->reset_gpio))
		return PTR_ERR(ts->reset_gpio);

	ft8203_reset_pulse(ts);

	/*
	 * Confirm (and log) whether the chip answers on SPI at all right
	 * after the new, longer reset settle -- rather than only inferring
	 * liveness later from /proc/interrupts.
	 */
	ft8203_log_presence(ts);

	/*
	 * ft8203_load_firmware() is NOT called here. On real xun hardware it
	 * reliably fails to enter the ROM bootloader at all (ft8203_enter_boot
	 * returns -ENODEV for both firmware variants -- confirmed via dmesg),
	 * and the repeated resets + unrecognized write/read attempts that
	 * involves appear to leave the chip in a worse state afterward than
	 * doing nothing: touch went from noisy/uncalibrated to completely
	 * unresponsive once this was wired in. The ROM-bootloader command set
	 * ported from the Tab S7 FE Lite driver (same silicon, different
	 * host) does not match how this chip actually responds here, so the
	 * whole handshake needs re-deriving before it's safe to call. Leaving
	 * the implementation in place below for whoever picks this back up.
	 *
	 * ft8203_try_exit_bootloader() is a single, low-risk recovery attempt
	 * for a chip that may have been left sitting in that bootloader by
	 * the failed attempts above (device confirmed: interrupt count does
	 * not move at all when the screen is tapped, which did not happen
	 * before firmware-loading was ever wired in). One short write, no
	 * reset pulse, no firmware write.
	 */
	ft8203_try_exit_bootloader(ts);

	/*
	 * Snapshot once, here, and use ts->mouse everywhere from now on
	 * (ft8203_report() does the same) -- see the big comment above the
	 * mouse_mode module_param for why this isn't a live runtime switch.
	 */
	ts->mouse = READ_ONCE(mouse_mode);

	input = devm_input_allocate_device(&spi->dev);
	if (!input)
		return -ENOMEM;
	ts->input = input;
	input->name = ts->mouse ? "Focaltech FT8203 Touchscreen (mouse sim)"
				 : "Focaltech FT8203 Touchscreen";
	input->id.bustype = BUS_SPI;
	input->dev.parent = &spi->dev;

	if (ts->mouse) {
		input_set_capability(input, EV_REL, REL_X);
		input_set_capability(input, EV_REL, REL_Y);
		input_set_capability(input, EV_KEY, BTN_LEFT);
	} else {
		/* Landscape after CCW map from native 1200x1920 panel space. */
		input_set_abs_params(input, ABS_MT_POSITION_X, 0, 1919, 0, 0);
		input_set_abs_params(input, ABS_MT_POSITION_Y, 0, 1199, 0, 0);
		input_set_capability(input, EV_KEY, BTN_TOUCH);

		ret = input_mt_init_slots(input, FT8203_MAX_TOUCH,
					  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
		if (ret)
			return ret;
	}

	ret = input_register_device(input);
	if (ret)
		return ret;

	ret = devm_request_threaded_irq(&spi->dev, spi->irq, NULL, ft8203_irq,
					IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
					"ft8203", ts);
	if (ret)
		return ret;

	dev_info(&spi->dev, "FT8203 touch ready (CCW landscape 1920x1200)\n");
	return 0;
}

static const struct of_device_id ft8203_of_match[] = {
	{ .compatible = "focaltech,ft8203" },
	{ }
};
MODULE_DEVICE_TABLE(of, ft8203_of_match);

static struct spi_driver ft8203_driver = {
	.driver = {
		.name = "ft8203-spi",
		.of_match_table = ft8203_of_match,
	},
	.probe = ft8203_probe,
};
module_spi_driver(ft8203_driver);

MODULE_AUTHOR("Redmi Pad SE bring-up");
MODULE_DESCRIPTION("FocalTech FT8203 SPI touchscreen");
MODULE_LICENSE("GPL");
