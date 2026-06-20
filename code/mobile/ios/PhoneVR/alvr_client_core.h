/* ALVR is licensed under the MIT license. https://github.com/alvr-org/ALVR/blob/master/LICENSE */
/* Hand-crafted C header derived from cbindgen output of alvr_client_core/src/c_api.rs */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AlvrQuat {
    float x;
    float y;
    float z;
    float w;
} AlvrQuat;

typedef struct AlvrPose {
    AlvrQuat orientation;
    float position[3];
} AlvrPose;

typedef struct AlvrFov {
    float left;
    float right;
    float up;
    float down;
} AlvrFov;

typedef struct AlvrViewParams {
    AlvrPose pose;
    AlvrFov fov;
} AlvrViewParams;

typedef struct AlvrDeviceMotion {
    uint64_t device_id;
    AlvrPose pose;
    float linear_velocity[3];
    float angular_velocity[3];
} AlvrDeviceMotion;

typedef struct AlvrClientCapabilities {
    uint32_t default_view_width;
    uint32_t default_view_height;
    bool external_decoder;
    const float *refresh_rates;
    int32_t refresh_rates_count;
    bool foveated_encoding;
    bool encoder_high_profile;
    bool encoder_10_bits;
    bool encoder_av1;
} AlvrClientCapabilities;

typedef enum AlvrCodec_Tag {
    ALVR_CODEC_H264 = 0,
    ALVR_CODEC_HEVC = 1,
    ALVR_CODEC_A_V1 = 2,
} AlvrCodec_Tag;

typedef enum AlvrEvent_Tag {
    ALVR_EVENT_HUD_MESSAGE_UPDATED,
    ALVR_EVENT_STREAMING_STARTED,
    ALVR_EVENT_STREAMING_STOPPED,
    ALVR_EVENT_HAPTICS,
    ALVR_EVENT_DECODER_CONFIG,
    ALVR_EVENT_FRAME_READY,
} AlvrEvent_Tag;

typedef struct AlvrEvent_STREAMING_STARTED_Body {
    uint32_t view_width;
    uint32_t view_height;
    float refresh_rate_hint;
    bool enable_foveated_encoding;
} AlvrEvent_STREAMING_STARTED_Body;

typedef struct AlvrEvent_HAPTICS_Body {
    uint64_t device_id;
    float duration_s;
    float frequency;
    float amplitude;
} AlvrEvent_HAPTICS_Body;

typedef struct AlvrEvent_DECODER_CONFIG_Body {
    AlvrCodec_Tag codec;
} AlvrEvent_DECODER_CONFIG_Body;

typedef union AlvrEvent_Payload {
    AlvrEvent_STREAMING_STARTED_Body STREAMING_STARTED;
    AlvrEvent_HAPTICS_Body HAPTICS;
    AlvrEvent_DECODER_CONFIG_Body DECODER_CONFIG;
} AlvrEvent_Payload;

typedef struct AlvrEvent {
    AlvrEvent_Tag tag;
    AlvrEvent_Payload payload;
} AlvrEvent;

typedef enum AlvrLogLevel {
    ALVR_LOG_LEVEL_ERROR,
    ALVR_LOG_LEVEL_WARN,
    ALVR_LOG_LEVEL_INFO,
    ALVR_LOG_LEVEL_DEBUG,
} AlvrLogLevel;

typedef enum AlvrButtonValue_Tag {
    ALVR_BUTTON_VALUE_BINARY,
    ALVR_BUTTON_VALUE_SCALAR,
} AlvrButtonValue_Tag;

typedef struct AlvrButtonValue {
    AlvrButtonValue_Tag tag;
    union {
        struct { bool binary; } BINARY;
        struct { float scalar; } SCALAR;
    };
} AlvrButtonValue;

uint64_t alvr_path_string_to_id(const char *path);
void alvr_log(AlvrLogLevel level, const char *message);

void alvr_initialize(AlvrClientCapabilities capabilities);
void alvr_destroy(void);
void alvr_resume(void);
void alvr_pause(void);

bool alvr_poll_event(AlvrEvent *out_event);

/* Returns byte count of next NAL. Pass null out_nal to peek size without consuming. */
uint64_t alvr_poll_nal(uint64_t *out_timestamp_ns,
                       AlvrViewParams *out_views_params,
                       char *out_nal);

uint64_t alvr_hud_message(char *message_buffer);
uint64_t alvr_get_settings_json(char *buffer);

/* view_params: array of 2; device_motions: array of device_motions_count */
void alvr_send_tracking(uint64_t target_timestamp_ns,
                        const AlvrViewParams *view_params,
                        const AlvrDeviceMotion *device_motions,
                        uint64_t device_motions_count,
                        const AlvrPose *const *hand_skeletons,
                        const AlvrPose *const *eye_gazes);

void alvr_send_battery(uint64_t device_id, float gauge_value, bool is_plugged);
void alvr_send_playspace(float width, float height);

uint64_t alvr_hostname(char *hostname_buffer);
uint64_t alvr_protocol_id(char *protocol_buffer);
uint64_t alvr_mdns_service(char *service_buffer);

#ifdef __cplusplus
}
#endif
