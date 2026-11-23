// SPDX-License-Identifier: GPL-2.0-only
/*
 * FocalTech FT8203 touchscreen on SPI.
 *
 * Coordinates are reported in panel native portrait space (1200x1920)
 * with both axes inverted to cancel the 180° mirror seen with
 * panel_orientation=left_side_up. Do not also rotate in userspace.
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
#include <linux/unaligned.h>

#define FT8203_MAX_TOUCH	10
#define FT8203_FRAME_BYTES	(2 + FT8203_MAX_TOUCH * 6)
#define FT8203_RAW_WIDTH	1600
#define FT8203_RAW_HEIGHT	2560

struct ft8203 {
	struct spi_device *spi;
	struct input_dev *input;
	struct input_dev *wake_input;
	struct gpio_desc *reset_gpio;
	struct regulator *vdd;
	struct regulator *vcc_i2c;
	struct mutex lock;
	bool gesture;
	struct delayed_work follower_work;
	struct device_link *panel_link;
};

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

static void ft8203_report(struct ft8203 *ts, const u8 *buf)
{
	struct input_dev *input = ts->input;
	unsigned int points = buf[1] & 0x0f;
	bool touch = false;
	unsigned int i;

	if (points > FT8203_MAX_TOUCH)
		return;

	for (i = 0; i < FT8203_MAX_TOUCH; i++) {
		const u8 *p = &buf[2 + i * 6];
		unsigned int event = p[0] >> 6;
		unsigned int id = p[2] >> 4;
		unsigned int x, y;

		if (id >= FT8203_MAX_TOUCH)
			break;

		input_mt_slot(input, id);

		if (event == 1 || (p[0] & 0x10)) {
			input_mt_report_slot_state(input, MT_TOOL_FINGER, false);
			continue;
		}
		if (event != 0 && event != 2)
			continue;

		x = ((p[0] & 0x0f) << 8) | p[1];
		y = ((p[2] & 0x0f) << 8) | p[3];
		if (x >= FT8203_RAW_WIDTH || y >= FT8203_RAW_HEIGHT)
			continue;

		touch = true;
		input_mt_report_slot_state(input, MT_TOOL_FINGER, true);

		/* scale to panel pixels */
		x = x * 1200 / FT8203_RAW_WIDTH;
		y = y * 1920 / FT8203_RAW_HEIGHT;
		if (x > 1199)
			x = 1199;
		if (y > 1919)
			y = 1919;

		/* invert both axes (fixes 180° mirror with left_side_up) */
		x = 1199 - x;
		y = 1919 - y;

		input_report_abs(input, ABS_MT_POSITION_X, x);
		input_report_abs(input, ABS_MT_POSITION_Y, y);
	}

	input_report_key(input, BTN_TOUCH, touch);
	input_mt_sync_frame(input);
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

	ts->reset_gpio = devm_gpiod_get_optional(&spi->dev, "reset",
						 GPIOD_OUT_HIGH);
	if (IS_ERR(ts->reset_gpio))
		return PTR_ERR(ts->reset_gpio);

	if (ts->reset_gpio) {
		gpiod_set_value_cansleep(ts->reset_gpio, 1);
		usleep_range(10000, 11000);
		gpiod_set_value_cansleep(ts->reset_gpio, 0);
		msleep(50);
	}

	input = devm_input_allocate_device(&spi->dev);
	if (!input)
		return -ENOMEM;
	ts->input = input;
	input->name = "Focaltech FT8203 Touchscreen";
	input->id.bustype = BUS_SPI;
	input->dev.parent = &spi->dev;

	input_set_abs_params(input, ABS_MT_POSITION_X, 0, 1199, 0, 0);
	input_set_abs_params(input, ABS_MT_POSITION_Y, 0, 1919, 0, 0);
	input_set_capability(input, EV_KEY, BTN_TOUCH);

	ret = input_mt_init_slots(input, FT8203_MAX_TOUCH,
				  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
	if (ret)
		return ret;

	ret = input_register_device(input);
	if (ret)
		return ret;

	ret = devm_request_threaded_irq(&spi->dev, spi->irq, NULL, ft8203_irq,
					IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
					"ft8203", ts);
	if (ret)
		return ret;

	dev_info(&spi->dev, "FT8203 touch ready (1200x1920, both axes inverted)\n");
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
