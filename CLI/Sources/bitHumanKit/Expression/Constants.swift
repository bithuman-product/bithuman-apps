/// Pipeline constants matching the Python config.py.
/// These are architectural constants derived from the model design.

import Foundation

// MARK: - Pipeline Constants

/// Frames per generation chunk (33 pixel frames = 5 latent frames)
internal let FRAME_NUM = 33

/// Number of motion frames in latent space carried between chunks
internal let MOTION_FRAMES_LATENT_NUM = 2

/// Diffusion timestep shift parameter
internal let SAMPLE_SHIFT: Float = 5.0

/// Target video frame rate
internal let TGT_FPS = 25

/// Audio sample rate (Hz) for wav2vec2
internal let SAMPLE_RATE = 16000

/// Maximum diffusion timesteps
internal let NUM_TIMESTEPS = 1000

// MARK: - Derived Constants

/// VAE temporal stride (8x compression: 33 pixel frames → 5 latent frames)
internal let VAE_STRIDE_T = 8

/// Motion frames in pixel space: (2-1)*8 + 1 = 9
internal let MOTION_FRAMES_NUM = (MOTION_FRAMES_LATENT_NUM - 1) * VAE_STRIDE_T + 1

/// New frames generated per chunk after motion overlap: 33 - 9 = 24
internal let NEW_FRAMES_PER_CHUNK = FRAME_NUM - MOTION_FRAMES_NUM

// MARK: - Model Dimensions

/// DiT hidden dimension
internal let DIT_DIM = 1536

/// DiT number of attention heads
internal let DIT_NUM_HEADS = 12

/// DiT head dimension
internal let DIT_HEAD_DIM = DIT_DIM / DIT_NUM_HEADS  // = 128

/// DiT number of transformer layers
internal let DIT_NUM_LAYERS = 30

/// DiT FFN intermediate dimension
internal let DIT_FFN_DIM = 8960

/// DiT output/latent channels
internal let DIT_OUT_DIM = 128

/// Audio context tokens per video frame
internal let AUDIO_CONTEXT_TOKENS = 32

/// Audio embedding dimension (from wav2vec2)
internal let AUDIO_EMB_DIM = 768

/// Audio hidden state layers (from wav2vec2)
internal let AUDIO_NUM_LAYERS = 12

/// Audio sliding window size (frames before/after center)
internal let AUDIO_WINDOW_SIZE = 5
