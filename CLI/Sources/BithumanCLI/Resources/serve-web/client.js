/* bitHuman serve-web — LiveKit client glue
 *
 * Topology: a single LiveKit room with three identities:
 *   - "user"    — this browser tab (publishes mic, subscribes brain audio + avatar video)
 *   - "brain"   — Swift bridge process (publishes bot audio)
 *   - "avatar"  — essence-server (publishes avatar video)
 *
 * The CLI substitutes __LIVEKIT_URL__ / __LIVEKIT_TOKEN__ / __ROOM_NAME__ in
 * index.html before serving. We read them off window.__BITHUMAN_CONFIG__.
 */

(function () {
  "use strict";

  // The UMD build exposes itself as `LivekitClient` (capital L). It also
  // historically exposed `LiveKitClient` on some builds, so be defensive.
  const LK = window.LivekitClient || window.LiveKitClient;
  if (!LK) {
    document.getElementById("errorLine").textContent =
      "Failed to load LiveKit client SDK.";
    return;
  }

  const { Room, RoomEvent, Track, ConnectionState } = LK;

  const cfg = window.__BITHUMAN_CONFIG__ || {};
  const LIVEKIT_URL = cfg.livekitUrl;
  const LIVEKIT_TOKEN = cfg.livekitToken;
  const ROOM_NAME = cfg.roomName;

  // DOM
  const els = {
    connectBtn: document.getElementById("connectBtn"),
    muteBtn: document.getElementById("muteBtn"),
    disconnectBtn: document.getElementById("disconnectBtn"),
    statusPill: document.getElementById("statusPill"),
    statusLabel: document.getElementById("statusLabel"),
    logLine: document.getElementById("logLine"),
    errorLine: document.getElementById("errorLine"),
    avatarVideo: document.getElementById("avatarVideo"),
    botAudio: document.getElementById("botAudio"),
    stageOverlay: document.getElementById("stageOverlay"),
    roomName: document.getElementById("roomName"),
  };

  // ---------- state ----------
  /** @type {Room | null} */
  let room = null;
  let micEnabled = false;
  let botAudioActive = false; // remote brain audio track present + unmuted
  let avatarVideoActive = false;
  let attachedAudioTracks = new Set();
  let attachedVideoTracks = new Set();
  let connState = "idle"; // idle | connecting | connected | disconnected | error

  // ---------- helpers ----------
  function setState(state, label) {
    connState = state;
    els.statusPill.dataset.state = state;
    if (label) els.statusLabel.textContent = label;
  }

  function refreshStatusLabel() {
    if (connState === "connecting") {
      setState("connecting", "Connecting…");
      return;
    }
    if (connState === "error") {
      setState("error", "Error");
      return;
    }
    if (connState === "disconnected" || connState === "idle") {
      setState(connState, "Disconnected");
      return;
    }
    // connected: derive bot state from audio activity
    if (botAudioActive) {
      setState("speaking", "Speaking");
    } else {
      setState("listening", "Listening");
    }
  }

  function log(msg) {
    els.logLine.textContent = msg;
    // eslint-disable-next-line no-console
    console.log("[bithuman]", msg);
  }

  function showError(msg) {
    els.errorLine.textContent = msg;
    // eslint-disable-next-line no-console
    console.error("[bithuman]", msg);
  }

  function clearError() {
    els.errorLine.textContent = "";
  }

  function setOverlay(visible, title, sub) {
    if (visible) {
      els.stageOverlay.classList.remove("hidden");
      if (title) els.stageOverlay.querySelector(".overlay-title").textContent = title;
      if (sub) els.stageOverlay.querySelector(".overlay-sub").textContent = sub;
    } else {
      els.stageOverlay.classList.add("hidden");
    }
  }

  function setControlsConnected(connected) {
    els.connectBtn.disabled = connected;
    els.connectBtn.textContent = connected ? "Connected" : "Connect";
    els.muteBtn.disabled = !connected;
    els.disconnectBtn.disabled = !connected;
  }

  function refreshMuteBtn() {
    if (!room) {
      els.muteBtn.textContent = "Mute";
      els.muteBtn.dataset.active = "false";
      return;
    }
    if (micEnabled) {
      els.muteBtn.textContent = "Mute";
      els.muteBtn.dataset.active = "false";
    } else {
      els.muteBtn.textContent = "Unmute";
      els.muteBtn.dataset.active = "true";
    }
  }

  // ---------- track handling ----------
  function handleTrackSubscribed(track, publication, participant) {
    const identity = participant?.identity || "?";
    log(`subscribed: ${identity}/${track.kind}`);

    if (track.kind === Track.Kind.Audio) {
      // Brain bot audio. (Avatar identity sometimes also publishes silence —
      // attach any remote audio so we don't miss it; the brain identity is
      // the source of truth for "speaking" state.)
      try {
        track.attach(els.botAudio);
        attachedAudioTracks.add(track);
      } catch (e) {
        showError(`audio attach failed: ${e?.message || e}`);
      }
      if (identity === "brain") {
        botAudioActive = !publication?.isMuted;
        refreshStatusLabel();
      }
    } else if (track.kind === Track.Kind.Video) {
      try {
        track.attach(els.avatarVideo);
        attachedVideoTracks.add(track);
        avatarVideoActive = true;
        setOverlay(false);
      } catch (e) {
        showError(`video attach failed: ${e?.message || e}`);
      }
    }

    // wire per-track mute/unmute for "speaking" state
    if (track.kind === Track.Kind.Audio && identity === "brain") {
      track.on("muted", () => {
        botAudioActive = false;
        refreshStatusLabel();
      });
      track.on("unmuted", () => {
        botAudioActive = true;
        refreshStatusLabel();
      });
    }
  }

  function handleTrackUnsubscribed(track, publication, participant) {
    const identity = participant?.identity || "?";
    log(`unsubscribed: ${identity}/${track.kind}`);
    try {
      track.detach();
    } catch (_e) {
      /* noop */
    }
    if (track.kind === Track.Kind.Audio) {
      attachedAudioTracks.delete(track);
      if (identity === "brain") {
        botAudioActive = false;
        refreshStatusLabel();
      }
    } else if (track.kind === Track.Kind.Video) {
      attachedVideoTracks.delete(track);
      if (attachedVideoTracks.size === 0) {
        avatarVideoActive = false;
        setOverlay(true, "Waiting for avatar…", "The avatar feed will appear here.");
      }
    }
  }

  function handleTrackMuted(publication, participant) {
    if (
      participant?.identity === "brain" &&
      publication?.kind === Track.Kind.Audio
    ) {
      botAudioActive = false;
      refreshStatusLabel();
    }
  }

  function handleTrackUnmuted(publication, participant) {
    if (
      participant?.identity === "brain" &&
      publication?.kind === Track.Kind.Audio
    ) {
      botAudioActive = true;
      refreshStatusLabel();
    }
  }

  // ---------- connect / disconnect ----------
  async function connect() {
    clearError();
    // Detect un-substituted placeholders without writing the literal token here
    // (the CLI's text replacement would rewrite our guard string too). We sniff
    // the leading underscores instead.
    const looksUnsubstituted = (v) =>
      typeof v !== "string" || v.length === 0 || /^__[A-Z_]+__$/.test(v);
    if (looksUnsubstituted(LIVEKIT_URL)) {
      showError("LiveKit URL not configured (CLI did not substitute placeholder).");
      return;
    }
    if (looksUnsubstituted(LIVEKIT_TOKEN)) {
      showError("LiveKit token not configured (CLI did not substitute placeholder).");
      return;
    }

    setState("connecting", "Connecting…");
    setOverlay(true, "Connecting…", "Negotiating with LiveKit room.");
    els.connectBtn.disabled = true;

    room = new Room({
      adaptiveStream: true,
      dynacast: true,
    });

    room
      .on(RoomEvent.TrackSubscribed, handleTrackSubscribed)
      .on(RoomEvent.TrackUnsubscribed, handleTrackUnsubscribed)
      .on(RoomEvent.TrackMuted, handleTrackMuted)
      .on(RoomEvent.TrackUnmuted, handleTrackUnmuted)
      .on(RoomEvent.Disconnected, (reason) => {
        log(`disconnected${reason !== undefined ? ` (${reason})` : ""}`);
        teardown();
      })
      .on(RoomEvent.ConnectionStateChanged, (state) => {
        log(`conn state: ${state}`);
        if (state === ConnectionState.Connected) {
          connState = "connected";
          refreshStatusLabel();
          setControlsConnected(true);
        } else if (state === ConnectionState.Reconnecting) {
          setState("connecting", "Reconnecting…");
        } else if (state === ConnectionState.Disconnected) {
          connState = "disconnected";
          refreshStatusLabel();
          setControlsConnected(false);
        }
      });

    try {
      await room.connect(LIVEKIT_URL, LIVEKIT_TOKEN);
      log(`joined room: ${room.name}`);
      els.roomName.textContent = room.name || ROOM_NAME || "";

      // Enable mic. Browser will prompt for permission on this call.
      try {
        await room.localParticipant.setMicrophoneEnabled(true);
        micEnabled = true;
        refreshMuteBtn();
        log("microphone enabled");
      } catch (e) {
        showError(`mic error: ${e?.message || e}`);
        micEnabled = false;
        refreshMuteBtn();
      }

      // If avatar/brain were already publishing before we joined, their tracks
      // come via TrackSubscribed automatically once we connect. Nothing extra needed.
      setOverlay(true, "Waiting for avatar…", "The avatar feed will appear here.");
    } catch (err) {
      showError(`connect failed: ${err?.message || err}`);
      setState("error", "Error");
      setControlsConnected(false);
      try {
        await room?.disconnect();
      } catch (_e) {
        /* noop */
      }
      room = null;
    }
  }

  async function disconnect() {
    if (!room) return;
    els.disconnectBtn.disabled = true;
    try {
      await room.disconnect();
    } catch (e) {
      showError(`disconnect error: ${e?.message || e}`);
    }
    // teardown() runs from the Disconnected event
  }

  function teardown() {
    // detach any tracks we still hold
    for (const t of attachedAudioTracks) {
      try {
        t.detach();
      } catch (_e) {
        /* noop */
      }
    }
    for (const t of attachedVideoTracks) {
      try {
        t.detach();
      } catch (_e) {
        /* noop */
      }
    }
    attachedAudioTracks.clear();
    attachedVideoTracks.clear();
    botAudioActive = false;
    avatarVideoActive = false;
    micEnabled = false;
    room = null;

    connState = "disconnected";
    setState("disconnected", "Disconnected");
    setControlsConnected(false);
    refreshMuteBtn();
    setOverlay(true, "Disconnected", "Click Connect to rejoin.");
  }

  async function toggleMute() {
    if (!room) return;
    const next = !micEnabled;
    els.muteBtn.disabled = true;
    try {
      await room.localParticipant.setMicrophoneEnabled(next);
      micEnabled = next;
      log(next ? "microphone enabled" : "microphone muted");
    } catch (e) {
      showError(`mic toggle failed: ${e?.message || e}`);
    } finally {
      els.muteBtn.disabled = false;
      refreshMuteBtn();
    }
  }

  // ---------- bootstrap ----------
  function init() {
    const looksUnsubstituted = (v) =>
      typeof v !== "string" || v.length === 0 || /^__[A-Z_]+__$/.test(v);
    if (ROOM_NAME && !looksUnsubstituted(ROOM_NAME)) {
      els.roomName.textContent = ROOM_NAME;
    } else {
      els.roomName.textContent = "";
    }

    setState("idle", "Disconnected");
    setControlsConnected(false);
    refreshMuteBtn();
    setOverlay(true, "Ready when you are", "Click Connect and allow microphone access.");

    els.connectBtn.addEventListener("click", () => {
      connect().catch((e) => showError(`connect threw: ${e?.message || e}`));
    });
    els.muteBtn.addEventListener("click", () => {
      toggleMute().catch((e) => showError(`mute threw: ${e?.message || e}`));
    });
    els.disconnectBtn.addEventListener("click", () => {
      disconnect().catch((e) => showError(`disconnect threw: ${e?.message || e}`));
    });

    window.addEventListener("beforeunload", () => {
      if (room) {
        // best-effort; browser may not await this
        room.disconnect().catch(() => {});
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
