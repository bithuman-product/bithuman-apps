## Unreleased

* **Migrated to OpenAI Realtime GA** — the beta endpoint was retired
  upstream and now refuses connections with close code 4000
  (`invalid_request_error.beta_api_shape_disabled`). Changes:
  * Drop the `OpenAI-Beta: realtime=v1` header.
  * Default `model` flipped from `gpt-4o-realtime-preview-2024-12-17`
    to `gpt-realtime`.
  * `session.update` payload rewritten to the GA shape: top-level
    `type: 'realtime'`, `output_modalities: ['audio']`, audio config
    nested under `audio.input` / `audio.output`, `voice` lives inside
    `audio.output`, `turn_detection` inside `audio.input`, format
    object `{type: 'audio/pcm', rate: 24000}` (was the string `'pcm16'`).
  * Inbound event renames: `response.audio.delta` →
    `response.output_audio.delta`, and `response.audio_transcript.delta`
    → `response.output_audio_transcript.delta`.
* **Reconnect-backoff fix** — the WebSocket reconnect counter now resets
  on the first inbound server event rather than on TCP-dial success.
  Without this, server-side close-after-handshake (auth rejected, schema
  rejected, beta deprecation) looped forever in `connecting` instead of
  surfacing `RealtimeStatus.error`; the max-retries ceiling was
  unreachable because every dial reset the counter to zero.

## 0.0.1

* TODO: Describe initial release.
