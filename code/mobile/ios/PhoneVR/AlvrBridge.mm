#import "AlvrBridge.h"
#import "alvr_client_core.h"
#import <Foundation/Foundation.h>
#include <math.h>

static uint64_t HEAD_ID = 0;

void pvr_ios_initialize(uint32_t view_width, uint32_t view_height, float refresh_rate) {
    HEAD_ID = alvr_path_string_to_id("/user/head");

    float refresh_rates[1] = { refresh_rate };

    AlvrClientCapabilities caps = {};
    caps.default_view_width = view_width;
    caps.default_view_height = view_height;
    /* iOS uses external_decoder: ALVR delivers raw NAL data via alvr_poll_nal(),
       and we decode it ourselves with VideoToolbox. */
    caps.external_decoder = true;
    caps.refresh_rates = refresh_rates;
    caps.refresh_rates_count = 1;
    caps.foveated_encoding = false;
    caps.encoder_high_profile = true;
    caps.encoder_10_bits = false;
    caps.encoder_av1 = false;

    alvr_initialize(caps);
    NSLog(@"[PhoneVR] ALVR initialized – view %ux%u @ %.0f Hz", view_width, view_height, refresh_rate);
}

void pvr_ios_destroy(void) {
    alvr_destroy();
}

void pvr_ios_resume(void) {
    alvr_resume();
}

void pvr_ios_pause(void) {
    alvr_pause();
}

bool pvr_ios_poll_event(AlvrEvent *out_event) {
    return alvr_poll_event(out_event);
}

uint64_t pvr_ios_poll_nal(uint64_t *out_timestamp_ns,
                           AlvrViewParams *out_view_params,
                           uint8_t *out_buf) {
    return alvr_poll_nal(out_timestamp_ns, out_view_params, (char *)out_buf);
}

void pvr_ios_send_tracking(uint64_t target_timestamp_ns,
                            float ox, float oy, float oz, float ow,
                            float fov_left, float fov_right, float fov_up, float fov_down) {
    /* Default symmetric FOV when the server hasn't sent one yet. */
    const float kDefaultFovRad = 45.0f * (float)M_PI / 180.0f;

    AlvrQuat orientation = { ox, oy, oz, ow };
    AlvrPose headPose = {};
    headPose.orientation = orientation;

    float eyeOffset = 0.032f; /* 64 mm IPD / 2 */

    AlvrFov fov = {};
    fov.left  = (fov_left  != 0.0f) ? fov_left  : -kDefaultFovRad;
    fov.right = (fov_right != 0.0f) ? fov_right :  kDefaultFovRad;
    fov.up    = (fov_up    != 0.0f) ? fov_up    :  kDefaultFovRad;
    fov.down  = (fov_down  != 0.0f) ? fov_down  : -kDefaultFovRad;

    AlvrViewParams viewParams[2] = {};
    /* Left eye */
    viewParams[0].pose = headPose;
    viewParams[0].pose.position[0] = -eyeOffset;
    viewParams[0].fov = fov;
    /* Right eye */
    viewParams[1].pose = headPose;
    viewParams[1].pose.position[0] = eyeOffset;
    viewParams[1].fov = fov;

    AlvrDeviceMotion headMotion = {};
    headMotion.device_id = HEAD_ID;
    headMotion.pose = headPose;

    alvr_send_tracking(target_timestamp_ns,
                       viewParams,
                       &headMotion, 1,
                       NULL, NULL);
}

void pvr_ios_send_battery(float level, bool is_plugged) {
    alvr_send_battery(HEAD_ID, level, is_plugged);
}

uint64_t pvr_ios_head_id(void) {
    return HEAD_ID;
}
