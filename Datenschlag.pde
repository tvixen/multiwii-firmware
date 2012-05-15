
#define DS_FRAME_PAYLOAD_SIZE 5
struct ds_frame_t {
	uint8_t cmd; /* command type */
	uint8_t data[DS_FRAME_PAYLOAD_SIZE]; /* payload */
	uint8_t chk; /* checksum (XOR all other fields) */
};

#define DS_FRAME_BUFFER_SIZE 10
/* ring buffer and positions for reader and writer */
static struct ds_frame_t ds_buffer[DS_FRAME_BUFFER_SIZE];
/* nibble position in the current frame */
static uint8_t ds_buffer_pos = 0;
static uint8_t ds_w_pos = 0;
static uint8_t ds_r_pos = 0;

static void decoder_feed(uint8_t input) {
	if (ds_buffer_pos < 2*sizeof(*ds_buffer)) {
		uint8_t *f = (uint8_t *) &ds_buffer[ds_w_pos];
		if (ds_buffer_pos%2 == 0) {
			f[ds_buffer_pos/2] = input&0x0F;
		} else {
			f[ds_buffer_pos/2] |= input<<4;
		}
		ds_buffer_pos++;
		/* finished a complete frame? */
		if (ds_buffer_pos == 2*sizeof(*ds_buffer)) {
			ds_w_pos++;
			ds_buffer_pos = 0;
			if (ds_w_pos == DS_FRAME_BUFFER_SIZE) {
				ds_w_pos = 0;
			}
		}
	}
}

static void decoder_reset(void) {
	ds_buffer_pos = 0;
}

static uint8_t decoder_complete(void) {
	return (DS_FRAME_BUFFER_SIZE+ds_w_pos-ds_r_pos) % DS_FRAME_BUFFER_SIZE;
}

static uint8_t decoder_get_frame(struct ds_frame_t *f) {
	if (decoder_complete()) {
		cli();
		memcpy(f, &ds_buffer[ds_r_pos], sizeof(*f));
		ds_r_pos = (ds_r_pos+1)%DS_FRAME_BUFFER_SIZE;
		sei();
		return 1;
	} else {
		return 0;
	}
}

static uint8_t decoder_verify_frame(struct ds_frame_t *f) {
	uint8_t sum = 0;
	for (uint8_t i=0; i<sizeof(*f); i++) {
		sum ^= ((uint8_t*)f)[i];
	}
	return (sum==0);
}

/* this code is used to store persistent flight assistance data,
 * e.g. whether the ACC has been enabled by Datensprung frames
 */
#define DATENSPRUNG_FA_ACC 0
#define DATENSPRUNG_FA_BARO 1
#define DATENSPRUNG_FA_MAG 2
#define DATENSPRUNG_FA_HEADFREE 3
#define DATENSPRUNG_FA_GPSHOLD 4
static struct {
	/* only settings masked with 1 are touched by Datensprung */
	uint8_t mask;
	uint8_t values;
} datenschlag_fa_settings = {0,0};

static void datenschlag_apply_setting(uint8_t bit, uint8_t *var) {
	// Do we touch the setting?
	if ( ~datenschlag_fa_settings.mask & 1<<bit) return;

	if (datenschlag_fa_settings.values & 1<<bit) {
		*var = 1;
	} else {
		*var = 0;
	}
}

void datenschlag_apply_fa_settings() {
	datenschlag_apply_setting(DATENSPRUNG_FA_ACC, &rcOptions[BOXACC]);
	datenschlag_apply_setting(DATENSPRUNG_FA_BARO, &rcOptions[BOXBARO]);
	datenschlag_apply_setting(DATENSPRUNG_FA_MAG, &rcOptions[BOXMAG]);
	datenschlag_apply_setting(DATENSPRUNG_FA_HEADFREE, &rcOptions[BOXHEADFREE]);
	datenschlag_apply_setting(DATENSPRUNG_FA_GPSHOLD, &rcOptions[BOXGPSHOLD]);
}

static struct {
	uint16_t min;
	uint16_t max;
} datenschlag_calib = {~0, 0};

void datenschlag_feed(uint16_t value) {
	static uint16_t last_token = 0;
	/* let the calibration decay over time */
	if (datenschlag_calib.min < ~0) datenschlag_calib.min++;
	if (datenschlag_calib.max >  0) datenschlag_calib.max--;
	/* calibrate */
	if (value < datenschlag_calib.min) datenschlag_calib.min = value;
	if (value > datenschlag_calib.max) datenschlag_calib.max = value;

	/* calculate the nibble value of our signal */

	/* we need to map the value in the range from min to max into an
	 * interval from 0 to 0x0F+2:
	 * 0         == minimum calibration (and nibble ack)
	 * 0x0F+2    == maximum calibration (and frame start)
	 * 1-0x0F+1  == payload nibble value (+1)
	 */
	uint32_t input = value-datenschlag_calib.min;
	uint32_t span = datenschlag_calib.max-datenschlag_calib.min;
	uint32_t o_max = 0x0F+2;
	uint16_t v = (input+span/o_max/2)*o_max/span;
	if (v == 0x0F+2) {
		decoder_reset();
	} else if (last_token != v && last_token > 0 && last_token < 0x0F+2) {
		decoder_feed(last_token-1);
	}
	last_token = v;
}

void datenschlag_reset() {
	decoder_reset();
	datenschlag_calib.min = ~0;
	datenschlag_calib.max = 0;
}

void datenschlag_process() {
	struct ds_frame_t frame;
	while (decoder_get_frame(&frame)) {
		if (! decoder_verify_frame(&frame)) continue;

		/* evaluate the received frames */
		switch (frame.cmd) {
			case 0xFA:
				/* flight assistance data has 4 payload bytes:
				 * mask data (which systems do we wish to control?)
				 * mask data mask [sic] (which mask bits do we want to change?)
				 * value data (which systems do we want enabled?)
				 * value data mask (which states do we want to switch?)
				 */
				datenschlag_fa_settings.mask = (datenschlag_fa_settings.mask & ~frame.data[1]) | (frame.data[0] & frame.data[1]);
				datenschlag_fa_settings.values = (datenschlag_fa_settings.values & ~frame.data[3]) | (frame.data[2] & frame.data[3]);
				break;
#if defined(LED_FLASHER)
			case 0x1E:
				led_flasher_set_sequence(frame.data[0]);
				break;
#endif
			case 0xDE:
				/* debugging data */
				debug1 = frame.data[0];
				debug2 = frame.data[1];
				break;
			default:
				break;
		}
	}
}
