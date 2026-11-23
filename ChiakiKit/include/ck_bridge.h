// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Small, Swift-friendly C API over chiaki-ng's core library.
//
// chiaki-ng's own structs change layout depending on compile-time crypto
// options, so the app never sees them. Everything here is opaque handles,
// plain value structs and C callbacks. All callbacks fire on chiaki's internal
// threads; the caller is responsible for hopping to the right queue.

#ifndef CK_BRIDGE_H
#define CK_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

    // ---------------------------------------------------------------- library

    /// Must be called once before anything else. Returns 0 on success.
    int ck_lib_init(void);

    typedef void (*CKLogCallback)(void *user, int level, const char *message);

    /// Optional global log sink for discovery/registration (sessions take their own).
    void ck_set_log_callback(CKLogCallback cb, void *user);

#ifdef CK_INPUT_LATENCY_PROBE
    // Available only in the isolated device probe. Times are Mach absolute ticks.
    uint64_t ck_latency_ticks(void);
    double ck_latency_seconds(uint64_t ticks);
    uint64_t ck_latency_begin(double age_seconds, uint64_t entry_ticks, bool pressed);
    void ck_latency_exit(uint64_t id);
    void ck_latency_arm(uint64_t id);
    void ck_latency_disarm(void);
    void ck_latency_invalid(void);
    void ck_latency_masked(void);
    void ck_latency_reset(void);
    void ck_latency_report(void);
#endif

    // ----------------------------------------------------------------- codecs

    typedef enum
    {
        CK_CODEC_H264 = 0,
        CK_CODEC_H265 = 1,
        CK_CODEC_H265_HDR = 2,
    } CKCodec;

    // -------------------------------------------------------- host discovery

    typedef enum
    {
        CK_HOST_STATE_UNKNOWN = 0,
        CK_HOST_STATE_READY = 1,
        CK_HOST_STATE_STANDBY = 2,
    } CKHostState;

    typedef struct
    {
        CKHostState state;
        bool ps5;
        char host_addr[64];
        char host_name[64];
        char host_id[32];
        char system_version[32];
        char running_app_name[128];
        char running_app_titleid[32];
    } CKHostStatus;

    typedef struct CKHostMonitor CKHostMonitor;
    /// Called whenever the console answers (or stops answering, with state UNKNOWN).
    typedef void (*CKHostStatusCallback)(void *user, const CKHostStatus *status);

    /// Polls a single console by unicast. No multicast entitlement required.
    CKHostMonitor *ck_host_monitor_start(const char *host, CKHostStatusCallback cb, void *user);
    void ck_host_monitor_stop(CKHostMonitor *monitor);

    /// Sends a wake packet. regist_key is the 16-byte key from registration.
    int ck_wakeup(const char *host, const uint8_t regist_key[16], bool ps5);

    typedef struct CKDiscovery CKDiscovery;
    /// Finds PS5s on the local subnet by sweeping it with unicast search packets
    /// every few seconds (no multicast entitlement needed). The callback fires
    /// on a background thread for every reply, so expect repeats.
    CKDiscovery *ck_discovery_start(CKHostStatusCallback cb, void *user);
    /// Stops and joins; no callbacks after this returns.
    void ck_discovery_stop(CKDiscovery *discovery);

    // ------------------------------------------------------------ registration

    typedef struct
    {
        bool ps5;
        char server_nickname[32];
        uint8_t server_mac[6];
        uint8_t regist_key[16]; // rp_regist_key
        uint8_t rp_key[16];     // a.k.a. "morning"
        uint32_t rp_key_type;
        int target; // ChiakiTarget value
    } CKRegisteredHost;

    typedef void (*CKRegistCallback)(void *user, bool success, const CKRegisteredHost *host, const char *error);

    typedef struct CKRegist CKRegist;

    /// psn_account_id: 8 raw bytes (base64-decode the value from PSN).
    /// pin: 8-digit code shown on the PS5 under Remote Play > Link Device.
    CKRegist *ck_regist_start(const char *host, bool ps5, const uint8_t psn_account_id[8], uint32_t pin,
                              CKRegistCallback cb, void *user);
    /// Cancels if still running and frees. Safe to call after the callback fired.
    void ck_regist_destroy(CKRegist *regist);

    // ----------------------------------------------------------------- session

    typedef enum
    {
        CK_EVENT_CONNECTED = 0,
        CK_EVENT_QUIT = 1,
        CK_EVENT_LOGIN_PIN_REQUEST = 2,
        CK_EVENT_NICKNAME = 3,
        /// A text box opened on the console. message: its current text (may be NULL).
        CK_EVENT_KEYBOARD_OPEN = 4,
        /// The console changed the text. message: the new text.
        CK_EVENT_KEYBOARD_TEXT = 5,
        /// The console closed the text box.
        CK_EVENT_KEYBOARD_CLOSE = 6,
    } CKEventType;

    /// The console's DualSense effect intensity settings (Settings > Accessories > Controllers).
    typedef enum
    {
        CK_INTENSITY_OFF = 0,
        CK_INTENSITY_WEAK = 1,
        CK_INTENSITY_MEDIUM = 2,
        CK_INTENSITY_STRONG = 3,
    } CKIntensity;

    /// Controller state the console asks for. Only changes are reported.
    typedef enum
    {
        /// a, b, c: lightbar red, green, blue
        CK_PAD_INFO_LIGHTBAR = 0,
        /// a: player number the console assigned (1-based, 0 = none)
        CK_PAD_INFO_PLAYER = 1,
        /// a: CKIntensity for vibration/haptics
        CK_PAD_INFO_HAPTIC_INTENSITY = 2,
        /// a: CKIntensity for trigger effects
        CK_PAD_INFO_TRIGGER_INTENSITY = 3,
    } CKPadInfoType;

    typedef struct
    {
        /// One encoded access unit in Annex-B format. Return false to request an IDR.
        bool (*on_video)(void *user, const uint8_t *buf, size_t size, int32_t frames_lost, bool frame_recovered);
        /// code: quit reason for CK_EVENT_QUIT, pin_incorrect (0/1) for LOGIN_PIN_REQUEST.
        void (*on_event)(void *user, CKEventType type, int code, const char *message);
        void (*on_rumble)(void *user, uint8_t left, uint8_t right);
        void (*on_trigger_effects)(void *user, uint8_t type_left, const uint8_t left[10], uint8_t type_right, const uint8_t right[10]);
        /// DualSense haptics as 16-bit stereo PCM at 3 kHz.
        void (*on_haptics)(void *user, const int16_t *samples, size_t frames);
        /// Lightbar colour, player LEDs and effect intensity settings (see CKPadInfoType).
        /// Motion resets are handled inside the bridge.
        void (*on_pad_info)(void *user, CKPadInfoType type, uint8_t a, uint8_t b, uint8_t c);
        CKLogCallback on_log;
        void *user;
    } CKSessionCallbacks;

    typedef struct
    {
        const char *host;
        bool ps5;
        uint8_t regist_key[16];
        uint8_t rp_key[16];
        unsigned int width;
        unsigned int height;
        unsigned int max_fps;
        unsigned int bitrate_kbps;
        CKCodec codec;
        bool enable_dualsense;
        /// Ask the console to hand text boxes to us (CK_EVENT_KEYBOARD_*).
        bool enable_keyboard;
        /// Upstream default is 0.05 (5%).
        double packet_loss_max;
        bool verbose_log;
        /// Experimental: offer Takion v20 to a PS5 when connecting. The console picks the
        /// version; without an answer the stream stays on v12. Off keeps the stock v12 path.
        bool enable_takion_v20;
        /// Optional: ride out network hitches. Waits longer for late video packets when
        /// they turn up late (16-40 ms, adapting), and keeps decoding while a lost frame's
        /// replacement keyframe is on its way instead of freezing (patches/0002).
        bool network_smoothing;
    } CKSessionConfig;

    typedef struct CKSession CKSession;

    CKSession *ck_session_create(const CKSessionConfig *config, const CKSessionCallbacks *callbacks);
    int ck_session_start(CKSession *session);
    /// Asks the session to stop; CK_EVENT_QUIT follows.
    void ck_session_stop(CKSession *session);
    /// Stops, joins and frees. Never call from inside a session callback.
    void ck_session_destroy(CKSession *session);

    int ck_session_request_idr(CKSession *session);
    int ck_session_set_login_pin(CKSession *session, const char *pin);
    int ck_session_goto_bed(CKSession *session);
    double ck_session_measured_bitrate_mbps(CKSession *session);
    /// Fraction (0...1) of packets lost over the last congestion-control interval.
    double ck_session_packet_loss(CKSession *session);
    /// Round trip time measured while connecting, in milliseconds.
    double ck_session_rtt_ms(CKSession *session);
    /// Takion protocol version the stream is using (12, or 20 when the experimental mode
    /// was accepted), 0 before the stream connection is up.
    int ck_session_takion_version(CKSession *session);

    /// Running totals since the stream connected (zeros before that).
    typedef struct
    {
        /// Video packets that arrived after we'd given up waiting for them
        uint32_t packets_late;
        /// Video packets given up on (lost, or later than the wait)
        uint32_t packets_skipped;
        /// Frames error correction couldn't rebuild. Without network smoothing, each one
        /// freezes the picture until the console sends a keyframe.
        uint32_t fec_failures;
        /// Frames decoded against an older frame because the one they needed was lost
        uint32_t frames_patched;
        /// Current wait for a missing video packet, in milliseconds
        double reorder_wait_ms;
    } CKNetStats;

    void ck_session_net_stats(CKSession *session, CKNetStats *out);

    /// Text input for a console text box: send the whole text on every change,
    /// then accept (submit) or reject (cancel).
    int ck_session_keyboard_set_text(CKSession *session, const char *text);
    int ck_session_keyboard_accept(CKSession *session);
    int ck_session_keyboard_reject(CKSession *session);

    // Controller ---------------------------------------------------------------

    /// Same bit values as chiaki's ChiakiControllerButton.
    typedef enum
    {
        CK_BUTTON_CROSS = 1 << 0,
        CK_BUTTON_MOON = 1 << 1,
        CK_BUTTON_BOX = 1 << 2,
        CK_BUTTON_PYRAMID = 1 << 3,
        CK_BUTTON_DPAD_LEFT = 1 << 4,
        CK_BUTTON_DPAD_RIGHT = 1 << 5,
        CK_BUTTON_DPAD_UP = 1 << 6,
        CK_BUTTON_DPAD_DOWN = 1 << 7,
        CK_BUTTON_L1 = 1 << 8,
        CK_BUTTON_R1 = 1 << 9,
        CK_BUTTON_L3 = 1 << 10,
        CK_BUTTON_R3 = 1 << 11,
        CK_BUTTON_OPTIONS = 1 << 12,
        CK_BUTTON_SHARE = 1 << 13,
        CK_BUTTON_TOUCHPAD = 1 << 14,
        CK_BUTTON_PS = 1 << 15,
    } CKButton;

    typedef struct
    {
        uint32_t buttons;
        uint8_t l2;
        uint8_t r2;
        int16_t left_x, left_y, right_x, right_y;
    } CKPadState;

    /// Sends buttons/sticks/triggers. Motion and touch state are kept.
    void ck_session_set_pad(CKSession *session, const CKPadState *pad);

    /// Feeds motion. gyro in rad/s, accel in g, both in DualSense axes
    /// (x right, y up, z towards the player). timestamp_us is monotonic.
    void ck_session_set_motion(CKSession *session, float gx, float gy, float gz, float ax, float ay, float az, uint32_t timestamp_us);

    /// Touchpad. x in [0, 1919], y in [0, 1079]. Returns the touch id, or -1.
    int ck_session_touch_start(CKSession *session, uint16_t x, uint16_t y);
    void ck_session_touch_move(CKSession *session, int id, uint16_t x, uint16_t y);
    void ck_session_touch_stop(CKSession *session, int id);

    // Audio --------------------------------------------------------------------

    /// Pulls decoded game audio as interleaved stereo int16 at 48 kHz.
    /// Fills silence for any shortfall and returns the number of real frames.
    size_t ck_session_audio_read(CKSession *session, int16_t *out, size_t frames);
    /// Number of audio frames currently buffered.
    size_t ck_session_audio_buffered(CKSession *session);

    // Microphone ---------------------------------------------------------------

    /// Mutes or unmutes the remote mic. The first unmute tells the console a mic is
    /// attached. Only works once CK_EVENT_CONNECTED has fired; returns non-zero otherwise.
    int ck_session_mic_set_muted(CKSession *session, bool muted);
    /// Feeds mono int16 mic audio at 48 kHz, any chunk size. Encoded and sent in 10 ms
    /// frames; dropped while muted or before the stream connects. Thread-safe.
    void ck_session_mic_push(CKSession *session, const int16_t *samples, size_t frames);

#ifdef __cplusplus
}
#endif

#endif // CK_BRIDGE_H
