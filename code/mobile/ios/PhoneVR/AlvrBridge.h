#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "alvr_client_core.h"

/* Zero-initialise an AlvrEvent safely (Swift cannot synthesize init() for
   structs that contain a C union field). */
static inline AlvrEvent pvr_make_empty_event(void) {
    AlvrEvent e;
    memset(&e, 0, sizeof(e));
    return e;
}

#ifdef __cplusplus
extern "C" {
#endif

/* Wraps alvr_initialize with iOS-appropriate capabilities. */
void pvr_ios_initialize(uint32_t view_width, uint32_t view_height, float refresh_rate);

void pvr_ios_destroy(void);
void pvr_ios_resume(void);
void pvr_ios_pause(void);

/* Returns true and fills *event if a new event is ready. */
bool pvr_ios_poll_event(AlvrEvent *out_event);

/* Returns byte count of next NAL (0 = queue empty).
   Peek with out_buf == NULL to learn the size first, then call again to consume. */
uint64_t pvr_ios_poll_nal(uint64_t *out_timestamp_ns,
                           AlvrViewParams *out_view_params,
                           uint8_t *out_buf);

/* Send head-pose tracking. orientation is [x,y,z,w]. */
void pvr_ios_send_tracking(uint64_t target_timestamp_ns,
                            float ox, float oy, float oz, float ow,
                            float fov_left, float fov_right, float fov_up, float fov_down);

void pvr_ios_send_battery(float level, bool is_plugged);

uint64_t pvr_ios_head_id(void);

/* Copies ALVR's current HUD/status message into out_buf and returns its byte
   length. Pass out_buf == NULL to query the length first. */
uint64_t pvr_ios_hud_message(char *out_buf);

#ifdef __cplusplus
}
#endif
