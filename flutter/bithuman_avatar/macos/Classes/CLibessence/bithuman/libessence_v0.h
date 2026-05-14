/* bitHuman Essence Core — portable C ABI (v0 spike).
 *
 * SCOPE: minimum-viable surface for cross-platform algorithmic-core validation.
 *   .imx in  →  audio chunk fed  →  audio embedding + KNN cluster_idx out.
 *
 *   v0 deliberately STOPS at cluster_idx. The downstream steps — patch lookup
 *   (bases/patches blob), JPEG mask decode (HDF5), H.264 base-frame decode
 *   (videos / mp4), and alpha-blend composition — are out of scope until the
 *   audio-frontend / ONNX-encoder / KNN layer is bit-exact across macOS + iOS
 *   + Android. v1 will expand the API to return composited BGR frames.
 *
 * WHY START HERE: the algorithmic-risky bits are the audio frontend (STFT/mel
 * with specific Hann/Slaney/dB conventions) and the ONNX encoder (cross-EP
 * numerical drift). The rest is decode + arithmetic on indexed assets. If
 * embedding + cluster_idx match Python golden values, the rest is mechanical.
 *
 * AUDIENCE: Swift (via C interop) on Apple targets; JNI on Android.
 *   Every exported symbol is extern "C". Handles are opaque to callers.
 *   Internals may be C++; the ABI is not.
 *
 * COMPATIBILITY:
 *   - ABI version = BE_ABI_VERSION. Bumped on any breaking change to this header.
 *   - v0 is explicitly unstable. No promises across patch tags until v1.
 */

#ifndef BITHUMAN_LIBESSENCE_V0_H
#define BITHUMAN_LIBESSENCE_V0_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BE_ABI_VERSION 6   /* v6: streaming-first API — be_runtime_push_audio,
                            * be_runtime_pull_frame, be_runtime_ticks_available,
                            * be_runtime_reset_stream. O(1) per-tick cost,
                            * suitable for live PCM sources (WebRTC, mic, etc.).
                            * The batched be_runtime_tick_compose entry point is
                            * preserved for backward compatibility (same
                            * semantics, no behavior change).
                            * v5 added be_audio_decode_file/bytes + be_audio_free
                            * (canonical PCM-input path; eliminates per-binding
                            * resample drift).
                            * v4 added be_runtime_tick_compose_to_size +
                            * be_compose_size_t (720p auto-fit / letterbox).
                            * v3 introduced be_auth_* + BE_ERR_NO_AUTH. */

/* ---------------------------------------------------------------- */
/*  Versioning                                                      */
/* ---------------------------------------------------------------- */

const char* be_library_version(void);  /* compiled lib version (semver-ish) */
uint32_t    be_abi_version(void);      /* returns BE_ABI_VERSION lib compiled against */

/* ---------------------------------------------------------------- */
/*  Result codes                                                    */
/* ---------------------------------------------------------------- */

typedef enum be_status {
  BE_OK = 0,
  BE_ERR_INVALID_ARG       = 1,
  BE_ERR_FILE_NOT_FOUND    = 2,
  BE_ERR_FILE_CORRUPT      = 3,   /* .imx magic/version/TOC mismatch */
  BE_ERR_MODEL_LOAD_FAILED = 4,   /* audio_encoder.onnx failed to load */
  BE_ERR_OUT_OF_MEMORY     = 5,
  BE_ERR_AUDIO_FORMAT      = 6,   /* wrong sample count for tick */
  BE_ERR_BUFFER_TOO_SMALL  = 7,
  BE_ERR_INFERENCE_FAILED  = 8,
  BE_ERR_INTERNAL          = 9,
  BE_ERR_NOT_IMPLEMENTED   = 10,
  BE_ERR_NO_AUTH           = 11,  /* be_runtime_tick* called before successful be_auth_authenticate */
  BE_ERR_AUTH_FATAL        = 12,  /* heartbeat hit HTTP 402 / 403 — session terminated */
} be_status;

/* Thread-local last-error message. Stable until next libessence call on this thread. */
const char* be_last_error_message(void);

/* ---------------------------------------------------------------- */
/*  Execution provider                                              */
/* ---------------------------------------------------------------- */
/* CPU is the canonical baseline used by the differential test suite.
 * HW EPs are perf opt-ins and gated by a PSNR/L2 check vs. CPU output;
 * they are NOT guaranteed bit-exact across platforms. */

typedef enum be_ep {
  BE_EP_CPU        = 0,   /* canonical baseline; always available */
  BE_EP_AUTO       = 1,   /* pick fastest EP that passes drift gate */
  BE_EP_COREML     = 2,   /* Apple only; ignored elsewhere */
  BE_EP_NNAPI      = 3,   /* Android only; ignored elsewhere */
  BE_EP_QNN        = 4,   /* Qualcomm Adreno/Hexagon; Android only */
} be_ep;

/* ---------------------------------------------------------------- */
/*  Opaque handles                                                  */
/* ---------------------------------------------------------------- */
/* Two distinct types — load-bearing. Many runtimes per fixture preserves
 * the v0.19.0 shared-fixture pattern (1 fixture ~344 MB + N runtimes ~36 MB
 * each → 5.6× memory efficiency at N=10 on Apple silicon). The C ABI keeps
 * the shape from day one even though v0 runtimes are nearly stateless. */

typedef struct be_fixture be_fixture_t;   /* read-only, thread-safe, refcounted */
typedef struct be_runtime be_runtime_t;   /* per-conversation, single-threaded use */

/* ---------------------------------------------------------------- */
/*  Fixture: load .imx once, share across runtimes                  */
/* ---------------------------------------------------------------- */

typedef struct be_fixture_options {
  uint32_t abi_version;        /* set to BE_ABI_VERSION */
  be_ep    preferred_ep;       /* BE_EP_CPU for canonical / differential tests */
  uint32_t intra_op_threads;   /* ORT intra-op thread pool size. 0 or 1 = single-thread
                                * (matches Python reference, minimal latency variance).
                                * Higher values cut per-tick mean significantly on
                                * many-core hosts (M5: threads=4 cuts encode 45%). On
                                * mobile (Snapdragon 8 Gen 2), gains taper after 2
                                * threads and p99 may grow due to big.LITTLE scheduling. */
  uint32_t reserved[7];
} be_fixture_options_t;

/* Loads + parses .imx (custom TOC; magic "IMX\0", version 2), pulls out
 * audio_encoder.onnx and audio/feature_centers.npz, and prepares the shared
 * ONNX session. Caller owns the returned handle. */
be_status be_fixture_load(const char*                   imx_path,
                          const be_fixture_options_t*   opts,
                          be_fixture_t**                out_fixture);

typedef struct be_fixture_info {
  uint32_t audio_sample_rate;   /* 16000 for current Essence models */
  uint32_t audio_samples_per_tick; /* 640 (= 16000 / 25 fps) */
  uint32_t mel_bins;            /* 80 */
  uint32_t mel_frames_per_chunk;/* 16 — ONNX input is (1,1,mel_bins,mel_frames) */
  uint32_t embedding_dim;       /* model-dependent; read from ONNX output shape */
  uint32_t cluster_count;       /* number of KNN centroids; 183 on sample fixture */
  be_ep    active_ep;           /* what EP was actually selected */
  uint32_t frame_width;         /* composed BGR frame width (e.g., 1248) */
  uint32_t frame_height;        /* composed BGR frame height (e.g., 704)  */
  uint32_t source_frame_count;  /* number of base video frames for the cursor */
  uint32_t reserved[5];
} be_fixture_info_t;

be_status be_fixture_get_info(const be_fixture_t* f, be_fixture_info_t* out);

void be_fixture_retain(be_fixture_t* f);
void be_fixture_release(be_fixture_t* f);

/* ---------------------------------------------------------------- */
/*  Runtime: per-conversation                                       */
/* ---------------------------------------------------------------- */
/* v0 runtime holds the audio history buffer needed for STFT framing (pre/post
 * pad windows) and the audio cursor. The encoder itself is stateless. v1 will
 * fold in the video-graph state (action triggers, clip transitions). */

typedef struct be_runtime_options {
  uint32_t abi_version;        /* set to BE_ABI_VERSION */
  uint32_t reserved[8];
} be_runtime_options_t;

be_status be_runtime_create(be_fixture_t*                fixture,
                            const be_runtime_options_t*  opts,
                            be_runtime_t**               out_runtime);

void be_runtime_destroy(be_runtime_t* r);

/* ---------------------------------------------------------------- */
/*  Per-tick: audio → embedding + cluster_idx                       */
/* ---------------------------------------------------------------- */
/* Caller feeds exactly be_fixture_info.audio_samples_per_tick mono PCM float32
 * samples at audio_sample_rate (PCM expected in [-1.0, +1.0]; rescale is
 * applied internally to match the Python reference).
 *
 * Library produces:
 *   - embedding_out: float32 buffer of be_fixture_info.embedding_dim values
 *                    (caller-owned; pass NULL to skip emitting)
 *   - cluster_idx_out: nearest centroid index in [0, cluster_count)
 *
 * Synchronous; runs on the calling thread; no internal threading exposed. */

typedef struct be_tick_result {
  uint32_t cluster_idx;
  uint32_t embedding_floats_written;
  uint32_t reserved[4];
} be_tick_result_t;

be_status be_runtime_tick(be_runtime_t*       r,
                          const float*        audio_pcm_f32,
                          size_t              audio_sample_count,
                          float*              embedding_out,        /* may be NULL */
                          size_t              embedding_capacity,    /* in floats */
                          be_tick_result_t*   out_result);

/* v1: full tick that composes a BGR uint8 frame.
 *
 * Runs the v0 path (audio -> embedding -> cluster_idx) AND additionally:
 *   1. Picks frame_idx = (caller-provided or runtime cursor) % source_frame_count
 *   2. Reconstructs the lip image (base + per-cluster patch) from the .imx
 *   3. Resizes lip + face_mask to the per-frame bbox
 *   4. Alpha-blends into a copy of the H.264 base frame
 *   5. Writes the result into frame_bgr_out (caller-owned buffer, must be
 *      frame_width * frame_height * 3 bytes).
 *
 * If frame_idx is < 0, runtime uses its internal cursor (advances by 1 per
 * tick, wraps at source_frame_count). To pin to a specific source frame,
 * pass frame_idx >= 0.
 */

typedef struct be_compose_result {
  uint32_t cluster_idx;
  uint32_t frame_idx_used;       /* base-video frame_idx actually composited */
  uint32_t bytes_written;        /* should equal frame_width * frame_height * 3 */
  uint32_t reserved[4];
} be_compose_result_t;

be_status be_runtime_tick_compose(be_runtime_t*        r,
                                  const float*         audio_pcm_f32,
                                  size_t               audio_sample_count,
                                  int32_t              frame_idx_hint, /* <0 = use cursor */
                                  uint8_t*             frame_bgr_out,
                                  size_t               frame_capacity_bytes,
                                  be_compose_result_t* out_result);

/* ---------------------------------------------------------------- */
/*  Streaming API (since ABI 6 / libessence v1.16)                  */
/* ---------------------------------------------------------------- */
/* Producer/consumer pattern for live audio sources (WebRTC, mic, TTS
 * over network, etc.):
 *
 *   - be_runtime_push_audio(r, pcm, n): O(n) work — extends the
 *     runtime's internal mel buffer by exactly the new STFT frames
 *     produced by the n new PCM samples. Cost is INDEPENDENT of how
 *     much audio has already been pushed in this stream.
 *
 *   - be_runtime_pull_frame(r, hint, out, cap, result): O(1) work
 *     for the audio side — consumes one tick worth of cached mel and
 *     produces a composed BGR frame. Returns BE_ERR_AUDIO_FORMAT if
 *     no tick is pull-ready yet (caller should push more audio).
 *
 *   - be_runtime_ticks_available(r): how many ticks can be pulled
 *     right now without pushing more audio. = pull-ready frame count.
 *
 *   - be_runtime_reset_stream(r): clears the stream state (mel buf,
 *     STFT overlap, preemphasis history, cursor). Cheap, no model
 *     reload. Call between sessions (mic toggle, conversation start).
 *
 * Threading: single-threaded per runtime. push_audio and pull_frame
 * can be on different threads if external synchronization is provided
 * (e.g. caller's render loop owns pull_frame; sink thread calls
 * push_audio under a lock).
 *
 * Output mel values are bit-exact identical with be_runtime_tick_compose
 * for the same audio (verified vs sine_sweep_5s + speech_5s goldens).
 * The wrap-around tick that batched mode emits at start = T-16 is
 * absent in streaming mode by design (the stream is unbounded).
 */

/* Push n_new PCM samples (16 kHz mono float32) into the runtime's
 * stream. Extends the internal mel cache by approximately
 * n_new/HOP_SIZE new frames. Cost: O(n_new). */
be_status be_runtime_push_audio(be_runtime_t* r,
                                const float*  new_pcm,
                                size_t        n_new_samples);

/* Pull one composed frame at the runtime's internal compose cursor.
 * frame_idx_hint = -1: auto-cycle through source frames (recommended).
 * frame_idx_hint >= 0: force a specific source frame.
 *
 * Returns BE_ERR_AUDIO_FORMAT if not enough audio has been pushed yet
 * (check be_runtime_ticks_available before calling).
 *
 * On success, advances the runtime's compose cursor by 1 and populates
 * out_result. */
be_status be_runtime_pull_frame(be_runtime_t*        r,
                                int32_t              frame_idx_hint,
                                uint8_t*             frame_bgr_out,
                                size_t               frame_capacity_bytes,
                                be_compose_result_t* out_result);

/* How many ticks are pull-ready right now (i.e., n_cached_mel_ticks -
 * stream_compose_cursor). 0 means caller should push more audio. */
size_t be_runtime_ticks_available(const be_runtime_t* r);

/* Reset the streaming state. Cheap. Use between conversations or after
 * disconnect to drop accumulated mel + STFT history. */
void be_runtime_reset_stream(be_runtime_t* r);

/* Target output canvas for be_runtime_tick_compose_to_size. The runtime
 * aspect-preserving-resizes the native composed frame into this canvas
 * and pads any remaining margins to (fill_b, fill_g, fill_r) — default
 * 0x000000 black (uninitialized struct, no _pad usage).
 *
 * Pass NULL (or target_width == 0) for "no resize, native size" —
 * equivalent to be_runtime_tick_compose.
 *
 * Phase 2.0e contract: the consolidated CLI pins target to 1280x720
 * (landscape) or 720x1280 (portrait) regardless of .imx source resolution.
 */
typedef struct be_compose_size_t {
  uint32_t target_width;     /* 0 = no resize (use native) */
  uint32_t target_height;    /* 0 = no resize (use native) */
  uint8_t  fill_b;           /* canvas fill color, B channel */
  uint8_t  fill_g;           /* canvas fill color, G channel */
  uint8_t  fill_r;           /* canvas fill color, R channel */
  uint8_t  _pad;             /* keep struct 4-byte-aligned */
} be_compose_size_t;

/* Like be_runtime_tick_compose but pastes the avatar into a target-sized
 * canvas with aspect-preserving fit + letterbox/pillarbox padding.
 *
 * frame_capacity_bytes MUST be >= target_width * target_height * 3 (when
 * size is non-NULL and non-zero), else >= native frame_width * frame_height
 * * 3 for the pass-through behavior.
 *
 * out_result.bytes_written reflects the target canvas size, not the
 * native compose size.
 *
 * Aspect math: source aspect = native_w / native_h, target aspect =
 *   target_w / target_h. If source is wider, the avatar is scaled to
 *   target_w x (target_w / src_aspect) and centered vertically with
 *   letterbox bars. If source is taller, the avatar is scaled to
 *   (target_h * src_aspect) x target_h and centered horizontally with
 *   pillarbox bars. Aspect match (or trivial 1-px rounding) = no padding.
 *
 * Resize uses libswscale SWS_BILINEAR — same backend as the H.264 decoder
 * path, cached per (native_w, native_h, target_w, target_h) on the runtime.
 *
 * Single-threaded per runtime, same as be_runtime_tick_compose.
 */
be_status be_runtime_tick_compose_to_size(
    be_runtime_t*              r,
    const float*               audio_pcm_f32,
    size_t                     audio_sample_count,
    int32_t                    frame_idx_hint,
    const be_compose_size_t*   size,            /* NULL = native, no resize */
    uint8_t*                   frame_bgr_out,
    size_t                     frame_capacity_bytes,
    be_compose_result_t*       out_result);

/* ---------------------------------------------------------------- */
/*  Differential-test hooks (debug build only)                      */
/* ---------------------------------------------------------------- */
/* Captures the intermediate tensor from the MOST RECENT tick. Used to
 * byte-compare against Python/Swift goldens during bring-up. Returns
 * BE_ERR_NOT_IMPLEMENTED in release builds.
 *
 * Tap dtype/shape contract:
 *   MEL_COEFFS         float32, [mel_bins × mel_frames_per_chunk]
 *   STFT_MAG           float32, [(n_fft/2+1) × mel_frames_per_chunk]
 *   ENCODER_LOGITS     float32, [embedding_dim] (pre-normalize, raw ONNX out)
 *   CLUSTER_DISTANCES  float32, [cluster_count] (L2 to each centroid; argmin = cluster_idx)
 */

typedef enum be_diag_tap {
  BE_TAP_MEL_COEFFS        = 1,
  BE_TAP_STFT_MAG          = 2,
  BE_TAP_ENCODER_LOGITS    = 3,
  BE_TAP_CLUSTER_DISTANCES = 4,
} be_diag_tap;

be_status be_runtime_capture(be_runtime_t* r,
                             be_diag_tap   which,
                             void*         out_buf,
                             size_t        capacity_bytes,
                             size_t*       out_bytes_written);

/* ---------------------------------------------------------------- */
/*  Logging hook                                                    */
/* ---------------------------------------------------------------- */

typedef enum be_log_level {
  BE_LOG_OFF   = 0,
  BE_LOG_ERROR = 1,
  BE_LOG_WARN  = 2,
  BE_LOG_INFO  = 3,
  BE_LOG_DEBUG = 4,
} be_log_level;

typedef void (*be_log_fn)(be_log_level level, const char* msg, void* user_ctx);

void be_set_log_callback(be_log_fn fn, void* user_ctx, be_log_level min_level);

/* ---------------------------------------------------------------- */
/*  Heartbeat / auth                                                */
/* ---------------------------------------------------------------- */
/* The libessence-side mirror of the Python lib / bitHumanKit Swift
 * SDK heartbeat. ONE process-wide client; the wrapper calls
 * be_auth_init once at startup with the developer api_secret, then
 * be_auth_authenticate (synchronous first roundtrip), then
 * be_auth_start_heartbeat to spawn the background thread.
 *
 * be_runtime_tick_compose returns BE_ERR_NO_AUTH if auth_state is
 * Unconfigured or has fallen out of the 300 s offline grace window.
 * It returns BE_ERR_AUTH_FATAL on HTTP 402 / 403 — the session is
 * terminal at that point; the wrapper must surface this to the user
 * and decline further pushAudio calls.
 *
 * Set BITHUMAN_UNMETERED=1 in the env (dev only) to bypass the gate;
 * production wrappers must error out if this is present. */

typedef enum be_auth_state {
  BE_AUTH_UNCONFIGURED    = 0,
  BE_AUTH_AUTHENTICATING  = 1,
  BE_AUTH_OK              = 2,
  BE_AUTH_OFFLINE         = 3,  /* recent net failure but within grace */
  BE_AUTH_FATAL_BALANCE   = 4,  /* HTTP 402 */
  BE_AUTH_FATAL_SUSPENDED = 5,  /* HTTP 403 */
} be_auth_state;

typedef struct be_auth_config_t {
  uint32_t    abi_version;          /* must equal BE_ABI_VERSION */
  const char* api_secret;           /* required */
  const char* billing_type;         /* e.g. "self-hosted-essence-model" */
  const char* tags;                 /* free-form, surfaced in usage reports */
  const char* fingerprint;          /* exactly 32 chars; NULL = library default */
  const char* endpoint_url;         /* NULL = default api.bithuman.ai */
  int32_t     interval_seconds;     /* 0 = default 60 s */
  int32_t     offline_grace_seconds;/* 0 = default 300 s */
} be_auth_config_t;

/* Configure the singleton client. Repeated calls reset config but
 * keep any running heartbeat thread alive (caller should stop+start). */
be_status be_auth_init(const be_auth_config_t* cfg);

/* Synchronous first heartbeat. Returns BE_OK, BE_ERR_AUTH_FATAL, or
 * BE_ERR_NO_AUTH (network failed on initial attempt). */
be_status be_auth_authenticate(void);

/* Start / stop the background 60 s heartbeat thread. Idempotent. */
be_status be_auth_start_heartbeat(void);
void      be_auth_stop_heartbeat(void);

/* Atomic state read. */
be_auth_state be_auth_get_state(void);

/* Last error from this thread / from the most recent failed
 * heartbeat. Stable until the next libessence call on this thread. */
const char* be_auth_last_error(void);

/* Frees the singleton client + any running thread. */
void be_auth_shutdown(void);

/* ---------------------------------------------------------------- */
/*  Audio decode (canonical PCM input — ABI v5)                     */
/* ---------------------------------------------------------------- */
/* Decode any libavformat-supported audio source (WAV / MP3 / AAC /
 * FLAC / OGG / Opus / MP4-with-audio) to canonical 16 kHz mono float32
 * PCM — the engine's tick input format. Centralizing this in libessence
 * eliminates the per-binding resampling drift that creeps in when
 * Python/Swift/Kotlin/Rust each pick their own resampler with subtly
 * different anti-alias filters.
 *
 * Mixing policy:
 *   - multi-channel input is downmixed to mono via libswresample
 *     (default matrix: average of channels)
 *   - any sample rate is resampled to 16 kHz via libswresample's
 *     soxr-equivalent SWR_FILTER_TYPE_KAISER kernel
 *   - output sample format is f32 in the range [-1.0, 1.0]
 *
 * Memory ownership:
 *   On BE_OK the caller owns *out_pcm and MUST free it via be_audio_free.
 *   *out_samples is the f32 sample count (== seconds * 16000).
 *   Both out-pointers are unchanged on non-OK return.
 *
 * Errors:
 *   BE_ERR_INVALID_ARG     — null args
 *   BE_ERR_FILE_NOT_FOUND  — path can't be opened
 *   BE_ERR_FILE_CORRUPT    — libavformat couldn't parse, or no audio stream
 *   BE_ERR_AUDIO_FORMAT    — codec missing in this libessence build
 *   BE_ERR_OUT_OF_MEMORY   — allocation failed
 *   BE_ERR_INTERNAL        — libavcodec/libswresample failure (see be_last_error_message) */
be_status be_audio_decode_file(const char* path,
                               float**     out_pcm,
                               size_t*     out_samples);

be_status be_audio_decode_bytes(const uint8_t* data,
                                size_t         len,
                                float**        out_pcm,
                                size_t*        out_samples);

/* Free a buffer allocated by be_audio_decode_file / be_audio_decode_bytes.
 * NULL-safe. After this call the pointer is dangling — do not dereference. */
void be_audio_free(float* pcm);

/* ---------------------------------------------------------------- */
/*  Session render (drive compose loop in C — ABI v5)               */
/* ---------------------------------------------------------------- */
/* Callback signature: invoked once per composed BGR frame. Return 0 to
 * continue the loop, non-zero to abort. The frame buffer is owned by
 * libessence (the same buffer is reused next tick) — copy if you need
 * to retain it across the callback boundary.
 *
 * frame_idx: 0-based tick index, monotonically increasing.
 * cluster_idx: which audio cluster the engine picked for this frame.
 * frame_idx_used: the source-video frame index the engine composited
 *                 against (advances cyclically modulo num_source_frames). */
typedef int (*be_frame_callback)(uint32_t       frame_idx,
                                 uint32_t       cluster_idx,
                                 uint32_t       frame_idx_used,
                                 const uint8_t* bgr_data,
                                 uint32_t       bgr_w,
                                 uint32_t       bgr_h,
                                 void*          user);

/* Drive the full compose loop over a PCM buffer. Slices the input into
 * 40 ms ticks (640 samples @ 16 kHz), calls be_runtime_tick_compose_to_size
 * on each, and invokes `cb` with the result.
 *
 * Trailing samples (count not divisible by 640) are zero-padded to one
 * final tick. This matches the Python reference's "last_chunk=True" flush
 * semantics and ensures audio shorter than `audio_duration_floor(640)`
 * still produces at least one frame. (Without this, callers re-implement
 * the EOS handling — see fix 0543a10 in the Rust CLI.)
 *
 * `size` is the same be_compose_size_t accepted by
 * be_runtime_tick_compose_to_size; pass NULL or {0, 0} for the engine's
 * native resolution (no resize / canvas).
 *
 * Return: BE_OK on full success, BE_ERR_NO_AUTH if heartbeat isn't
 * configured, BE_ERR_AUTH_FATAL if it's terminal, or the callback's
 * non-zero return code (passed back as BE_ERR_INTERNAL if positive). */
be_status be_session_render_pcm(be_runtime_t*            rt,
                                const float*             pcm,
                                size_t                   sample_count,
                                const be_compose_size_t* size,   /* nullable */
                                be_frame_callback        cb,
                                void*                    user);

/* ---------------------------------------------------------------- */
/*  Video encoder + one-shot session record (ABI v5)                */
/* ---------------------------------------------------------------- */
/* Opens a libavformat-backed H.264 + AAC MP4 sink. Encoder dispatch
 * is automatic by platform: h264_videotoolbox on Apple (hardware),
 * h264_mediacodec on Android (hardware), libx264 on Linux/Windows.
 * Audio track is optional — pass NULL `audio_src` for a video-only file.
 *
 * Output: MP4 with H.264 video (yuv420p), AAC audio, +faststart. */

typedef enum be_encoder_quality {
  BE_QUALITY_LOW    = 0,  /* libx264 -preset veryfast -crf 28 */
  BE_QUALITY_MEDIUM = 1,  /* libx264 -preset medium   -crf 23 (default) */
  BE_QUALITY_HIGH   = 2,  /* libx264 -preset slower   -crf 18 */
} be_encoder_quality;

/* Opaque encoder handle. */
typedef struct be_video_encoder be_video_encoder_t;

/* Open an MP4 sink at `path`. After this returns BE_OK, the caller pushes
 * BGR frames via be_video_encoder_write_frame at the rate implied by `fps`
 * and finalizes by calling be_video_encoder_close. */
be_status be_video_encoder_open(const char*          path,
                                uint32_t             w,
                                uint32_t             h,
                                uint32_t             fps,
                                be_encoder_quality   quality,
                                be_video_encoder_t** out);

/* Push one BGR24 frame (w*h*3 bytes). Frames must be sized to match the
 * (w, h) passed to open. Returns BE_ERR_BUFFER_TOO_SMALL if the caller
 * passes the wrong number of bytes. */
be_status be_video_encoder_write_frame(be_video_encoder_t* enc,
                                       const uint8_t*      bgr,
                                       size_t              bgr_len);

/* Mux audio into the MP4 from a libavformat-readable source. Must be
 * called after the LAST write_frame and before close. Pass NULL to
 * finalize without audio. The source can be anything libavformat
 * decodes (WAV / MP3 / AAC / FLAC / OGG / Opus / MP4-with-audio). */
be_status be_video_encoder_attach_audio(be_video_encoder_t* enc,
                                        const char*         audio_src);

/* Flush remaining frames, write the moov atom, free the encoder. */
be_status be_video_encoder_close(be_video_encoder_t* enc);

/* One-shot helper: render a PCM buffer through the runtime AND mux the
 * audio source into an MP4 in a single call. Combines be_session_render_pcm
 * with be_video_encoder_open / write_frame / attach_audio / close. The
 * audio path goes through be_audio_decode_file(audio_src) → engine ticks;
 * the same `audio_src` is muxed verbatim into the output MP4 track.
 *
 * This collapses what was ~250 lines of orchestration code in each binding
 * (Rust `cmd/generate.rs`, Swift `bithuman-render`) to a single C call. */
be_status be_session_record_mp4(be_runtime_t*            rt,
                                const char*              audio_src,
                                const be_compose_size_t* size,   /* nullable */
                                const char*              out_mp4,
                                be_encoder_quality       quality);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* BITHUMAN_LIBESSENCE_V0_H */
