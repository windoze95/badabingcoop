/* =========================================================================
   The Bada Bing — Coop Cam player
   --------------------------------------------------------------------------
   Strategy:
     1. Try low-latency WebRTC via MediaMTX's WHEP endpoint  (<path>/whep).
     2. On failure / unsupported browser, fall back to HLS    (<path>/index.m3u8)
        using hls.js, or native HLS on Safari.
     3. Live connection-status indicator + auto-reconnect with backoff.
     4. Snapshot button grabs the current frame to a downloadable PNG.

   The WHEP exchange below mirrors MediaMTX's own internal/servers/webrtc
   /reader.js (the MediaMTXWebRTCReader class), confirmed against upstream:
     - OPTIONS <whep>             -> ICE servers from the `Link` response header
     - POST    <whep>  app/sdp    -> 201 Created; SDP answer in body,
                                      session URL in the `Location` header
     - PATCH   <session> trickle  -> local ICE candidates as an SDP fragment,
                                      Content-Type application/trickle-ice-sdpfrag,
                                      If-Match: "*"
     - DELETE  <session>          -> tear the session down on close
   Everything else is vanilla JS. No framework.
   ========================================================================= */

(() => {
  "use strict";

  /* ----------------------------- Config ------------------------------ */
  // The stream path as configured in mediamtx.yml. Same-origin by default:
  // nginx serves these static files and proxies 8889 (WebRTC) + 8888 (HLS),
  // OR you point these at the MediaMTX ports directly. Adjust to taste.
  const CONFIG = {
    streamPath: "coop",
    // Base for the WHEP endpoint. If MediaMTX is reverse-proxied under the
    // same origin at /coop/whep, leave WEBRTC_BASE = "". Otherwise set it to
    // e.g. "https://cam.example.com:8889".
    webrtcBase: "",
    // Base for HLS. Same logic; default same-origin.
    hlsBase: "",
    // Reconnect backoff (ms): starts here, doubles, capped at maxBackoff.
    baseBackoff: 1500,
    maxBackoff: 20000,
    // How long to wait for first media before declaring a WebRTC attempt dead.
    webrtcTimeout: 12000,
    // After this many WebRTC failures in a row, prefer HLS for a while.
    webrtcFailLimit: 2,
  };

  const whepUrl = () =>
    `${CONFIG.webrtcBase}/${CONFIG.streamPath}/whep`;
  const hlsUrl = () =>
    `${CONFIG.hlsBase}/${CONFIG.streamPath}/index.m3u8`;

  /* ----------------------------- DOM -------------------------------- */
  const video = document.getElementById("video");
  const frame = video.closest(".player__frame");
  const statusEl = document.getElementById("status");
  const statusLabel = document.getElementById("statusLabel");
  const statusMode = document.getElementById("statusMode");
  const closedEl = document.getElementById("closed");
  const closedSub = document.getElementById("closedSub");
  const unmuteBtn = document.getElementById("unmute");
  const captureBtn = document.getElementById("capture");
  const reconnectBtn = document.getElementById("reconnect");
  const retryNowBtn = document.getElementById("retryNow");
  const downloadLink = document.getElementById("downloadLink");
  const techLine = document.getElementById("techLine");

  /* ------------------------- Player state --------------------------- */
  const State = Object.freeze({
    CONNECTING: "connecting",
    LIVE: "live",
    RECONNECTING: "reconnecting",
    OFFLINE: "offline",
    ERROR: "error",
  });

  let backoff = CONFIG.baseBackoff;
  let retryTimer = null;
  let webrtcFails = 0;
  let preferHls = false;
  let destroyed = false; // page is being torn down

  // Live engine handles, cleaned up on every (re)connect attempt.
  let pc = null;          // RTCPeerConnection (WebRTC)
  let hls = null;         // Hls instance (HLS fallback)
  let sessionUrl = null;  // WHEP session URL from Location header
  let abortCtl = null;    // AbortController for in-flight fetches
  let mediaWatchdog = null;

  /* --------------------------- UI helpers --------------------------- */
  function setStatus(state, label, mode) {
    statusEl.dataset.state = state;
    statusLabel.textContent = label;
    statusMode.textContent = mode || "";
  }

  function showClosed(show, subText) {
    closedEl.hidden = !show;
    if (subText) closedSub.textContent = subText;
  }

  function setLive(mode) {
    webrtcFails = 0;
    backoff = CONFIG.baseBackoff;
    setStatus(State.LIVE, "Live", mode);
    showClosed(false);
    captureBtn.disabled = false;
    maybeShowUnmute();
  }

  function maybeShowUnmute() {
    // Browsers force muted autoplay; offer a one-tap unmute once we're playing.
    unmuteBtn.hidden = !(video.muted && !video.paused);
  }

  /* ------------------------- Teardown ------------------------------- */
  function clearWatchdog() {
    if (mediaWatchdog) {
      clearTimeout(mediaWatchdog);
      mediaWatchdog = null;
    }
  }

  function teardown() {
    clearWatchdog();
    if (abortCtl) {
      try { abortCtl.abort(); } catch (_) {}
      abortCtl = null;
    }
    if (pc) {
      // Best-effort WHEP session delete; fire-and-forget.
      if (sessionUrl) {
        try {
          fetch(sessionUrl, { method: "DELETE", keepalive: true });
        } catch (_) {}
      }
      try { pc.ontrack = pc.onicecandidate = pc.oniceconnectionstatechange = null; } catch (_) {}
      try { pc.close(); } catch (_) {}
      pc = null;
    }
    sessionUrl = null;
    if (hls) {
      try { hls.destroy(); } catch (_) {}
      hls = null;
    }
    captureBtn.disabled = true;
  }

  /* ----------------------- Reconnect / backoff ---------------------- */
  function scheduleReconnect(reason) {
    teardown();
    if (destroyed) return;
    if (retryTimer) return; // already scheduled

    const wait = backoff;
    backoff = Math.min(backoff * 2, CONFIG.maxBackoff);

    setStatus(State.RECONNECTING, "Reconnecting…", reason || "");
    // After a couple of attempts with nothing, surface the "closed" panel so
    // the page doesn't just sit there looking broken.
    if (webrtcFails >= 1 || preferHls) {
      showClosed(
        true,
        "Stream is offline. Knocking again in " + Math.round(wait / 1000) + "s…"
      );
    }

    retryTimer = setTimeout(() => {
      retryTimer = null;
      connect();
    }, wait);
  }

  function reconnectNow() {
    if (retryTimer) {
      clearTimeout(retryTimer);
      retryTimer = null;
    }
    backoff = CONFIG.baseBackoff;
    connect();
  }

  /* ============================ WebRTC (WHEP) ======================= */

  // Parse the `Link` response header into RTCIceServer[]. Mirrors
  // MediaMTXWebRTCReader.#linkToIceServers.
  function linkToIceServers(linkHeader) {
    if (!linkHeader) return [];
    return linkHeader.split(", ").map((link) => {
      const m = link.match(
        /^<(.+?)>; rel="ice-server"(; username="(.*?)"; credential="(.*?)"; credential-type="password")?/i
      );
      if (!m) return null;
      const server = { urls: [m[1]] };
      if (m[3] !== undefined) {
        server.username = unquote(m[3]);
        server.credential = unquote(m[4]);
        server.credentialType = "password";
      }
      return server;
    }).filter(Boolean);
  }

  function unquote(s) {
    return s.replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }

  // Parse offer SDP for the bits we need to build trickle-ICE fragments.
  function parseOffer(sdp) {
    const ret = { iceUfrag: "", icePwd: "", medias: [] };
    for (const line of sdp.split("\r\n")) {
      if (line.startsWith("m=")) {
        ret.medias.push(line.slice(2));
      } else if (ret.iceUfrag === "" && line.startsWith("a=ice-ufrag:")) {
        ret.iceUfrag = line.slice("a=ice-ufrag:".length);
      } else if (ret.icePwd === "" && line.startsWith("a=ice-pwd:")) {
        ret.icePwd = line.slice("a=ice-pwd:".length);
      }
    }
    return ret;
  }

  // Build the SDP fragment for a batch of local candidates.
  // Mirrors MediaMTXWebRTCReader.#generateSdpFragment.
  function generateSdpFragment(offerData, candidates) {
    const byMedia = {};
    for (const c of candidates) {
      const mid = c.sdpMLineIndex;
      if (mid === null || mid === undefined) continue;
      (byMedia[mid] = byMedia[mid] || []).push(c);
    }
    let frag =
      "a=ice-ufrag:" + offerData.iceUfrag + "\r\n" +
      "a=ice-pwd:" + offerData.icePwd + "\r\n";
    let mid = 0;
    for (const media of offerData.medias) {
      if (byMedia[mid] !== undefined) {
        frag += "m=" + media + "\r\n" + "a=mid:" + mid + "\r\n";
        for (const c of byMedia[mid]) {
          frag += "a=" + c.candidate + "\r\n";
        }
      }
      mid++;
    }
    return frag;
  }

  async function connectWebRTC() {
    if (!("RTCPeerConnection" in window)) {
      throw new Error("no-webrtc");
    }
    setStatus(State.CONNECTING, "Connecting…", "WebRTC");

    abortCtl = new AbortController();
    const signal = abortCtl.signal;

    // 1) OPTIONS -> ICE servers from the Link header.
    let iceServers = [];
    try {
      const opt = await fetch(whepUrl(), { method: "OPTIONS", signal });
      iceServers = linkToIceServers(opt.headers.get("Link"));
    } catch (_) {
      // OPTIONS is best-effort; MediaMTX works with an empty ICE list (host
      // candidates / LAN) so we continue regardless.
    }

    pc = new RTCPeerConnection({ iceServers });

    // recvonly transceivers + a data channel, exactly like the reference client.
    pc.addTransceiver("video", { direction: "recvonly" });
    pc.addTransceiver("audio", { direction: "recvonly" });
    pc.createDataChannel("");

    pc.ontrack = (evt) => {
      if (video.srcObject !== evt.streams[0]) {
        video.srcObject = evt.streams[0];
      }
    };

    pc.oniceconnectionstatechange = () => {
      if (!pc) return;
      const s = pc.iceConnectionState;
      if (s === "connected" || s === "completed") {
        clearWatchdog();
        setLive("WebRTC · low latency");
        video.play().catch(() => {});
      } else if (s === "failed" || s === "disconnected" || s === "closed") {
        webrtcFails++;
        if (webrtcFails >= CONFIG.webrtcFailLimit) preferHls = true;
        scheduleReconnect("WebRTC dropped");
      }
    };

    // 2) Create offer, POST it to the WHEP endpoint.
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    const offerData = parseOffer(offer.sdp);

    const res = await fetch(whepUrl(), {
      method: "POST",
      headers: { "Content-Type": "application/sdp" },
      body: offer.sdp,
      signal,
    });

    if (res.status !== 201) {
      throw new Error("whep-post-" + res.status);
    }

    sessionUrl = makeAbsolute(res.headers.get("Location"), whepUrl());
    const answerSdp = await res.text();
    await pc.setRemoteDescription({ type: "answer", sdp: answerSdp });

    // 3) Trickle local ICE candidates to the session via PATCH.
    let candidateQueue = [];
    let patchInFlight = false;

    const flushCandidates = async () => {
      if (patchInFlight || candidateQueue.length === 0 || !sessionUrl) return;
      patchInFlight = true;
      const batch = candidateQueue;
      candidateQueue = [];
      try {
        await fetch(sessionUrl, {
          method: "PATCH",
          headers: {
            "Content-Type": "application/trickle-ice-sdpfrag",
            "If-Match": "*",
          },
          body: generateSdpFragment(offerData, batch),
          signal,
        });
      } catch (_) {
        // Non-fatal: connection may still complete with already-sent candidates.
      } finally {
        patchInFlight = false;
        if (candidateQueue.length) flushCandidates();
      }
    };

    pc.onicecandidate = (evt) => {
      if (evt.candidate && evt.candidate.candidate !== "") {
        candidateQueue.push(evt.candidate);
        flushCandidates();
      }
    };

    // Watchdog: if ICE never connects, treat as failure and fall back.
    mediaWatchdog = setTimeout(() => {
      if (!pc) return;
      const s = pc.iceConnectionState;
      if (s !== "connected" && s !== "completed") {
        webrtcFails++;
        preferHls = true; // first stall pushes us toward HLS
        scheduleReconnect("WebRTC timed out");
      }
    }, CONFIG.webrtcTimeout);
  }

  function makeAbsolute(loc, base) {
    if (!loc) return null;
    try {
      return new URL(loc, new URL(base, location.href)).href;
    } catch (_) {
      return loc;
    }
  }

  /* ============================== HLS ============================== */

  function nativeHlsSupported() {
    return video.canPlayType("application/vnd.apple.mpegurl") !== "";
  }

  // hls.js is loaded with `defer`, so on the very first connect it may not be
  // on window yet. Wait (briefly) for it before deciding HLS is unsupported.
  function whenHlsReady(timeoutMs) {
    if (window.Hls || nativeHlsSupported()) return Promise.resolve();
    return new Promise((resolve) => {
      const start = Date.now();
      const tick = () => {
        if (window.Hls || nativeHlsSupported() || Date.now() - start > timeoutMs) {
          resolve();
        } else {
          setTimeout(tick, 150);
        }
      };
      tick();
    });
  }

  function connectHls() {
    setStatus(State.CONNECTING, "Connecting…", "HLS");
    const url = hlsUrl();

    // Native HLS (Safari / iOS) — simplest path, no library needed.
    if (nativeHlsSupported() && !(window.Hls && window.Hls.isSupported())) {
      video.srcObject = null;
      video.src = url;
      const onPlaying = () => { setLive("HLS · native"); };
      const onError = () => { scheduleReconnect("HLS error"); };
      video.addEventListener("playing", onPlaying, { once: true });
      video.addEventListener("error", onError, { once: true });
      // Stall watchdog for native HLS.
      mediaWatchdog = setTimeout(() => {
        if (video.readyState < 2) scheduleReconnect("HLS stalled");
      }, CONFIG.webrtcTimeout);
      video.play().catch(() => {});
      return;
    }

    if (!(window.Hls && window.Hls.isSupported())) {
      // No WebRTC, no MSE, no native HLS — nothing left to try.
      setStatus(State.ERROR, "Unsupported", "");
      showClosed(true, "Your browser can’t play this stream. Try a recent Chrome, Firefox, or Safari.");
      return;
    }

    video.srcObject = null;
    video.removeAttribute("src");

    hls = new window.Hls({
      lowLatencyMode: true,
      backBufferLength: 30,
      liveSyncDurationCount: 3,
      manifestLoadingTimeOut: CONFIG.webrtcTimeout,
      manifestLoadingMaxRetry: 2,
    });

    hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
      video.play().catch(() => {});
    });

    hls.on(window.Hls.Events.FRAG_BUFFERED, () => {
      setLive("HLS");
    });

    hls.on(window.Hls.Events.ERROR, (_evt, data) => {
      if (!data.fatal) return;
      // For fatal media errors, hls.js can sometimes recover in place; for
      // network/manifest errors, schedule a full reconnect.
      switch (data.type) {
        case window.Hls.ErrorTypes.MEDIA_ERROR:
          try { hls.recoverMediaError(); return; } catch (_) {}
          scheduleReconnect("HLS media error");
          break;
        case window.Hls.ErrorTypes.NETWORK_ERROR:
        default:
          scheduleReconnect("HLS offline");
          break;
      }
    });

    hls.loadSource(url);
    hls.attachMedia(video);

    mediaWatchdog = setTimeout(() => {
      if (video.readyState < 2) scheduleReconnect("HLS stalled");
    }, CONFIG.webrtcTimeout + 4000);
  }

  /* ========================= Connect orchestration ================= */
  async function connect() {
    teardown();
    if (destroyed) return;
    showClosed(false);

    const canWebRtc = "RTCPeerConnection" in window;

    if (canWebRtc && !preferHls) {
      try {
        await connectWebRTC();
        return;
      } catch (err) {
        // Hard failure during setup (e.g. WHEP POST not 201, or no WebRTC).
        webrtcFails++;
        if (webrtcFails >= CONFIG.webrtcFailLimit || (err && err.message === "no-webrtc")) {
          preferHls = true;
        }
        teardown();
        // Immediately try HLS rather than waiting out the backoff.
      }
    }

    // HLS path (fallback, or preferred after repeated WebRTC failures).
    // Give the deferred hls.js script a moment to finish loading first.
    try {
      await whenHlsReady(5000);
      connectHls();
    } catch (_) {
      scheduleReconnect("connect failed");
    }
  }

  /* ============================ Snapshot =========================== */
  function capture() {
    const w = video.videoWidth;
    const h = video.videoHeight;
    if (!w || !h) return;

    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(video, 0, 0, w, h);

    // Neon watermark, because the Bing has standards.
    ctx.font = `bold ${Math.max(16, Math.round(w / 28))}px "Trebuchet MS", sans-serif`;
    ctx.textBaseline = "bottom";
    const label = "The Bada Bing";
    const pad = Math.round(w / 50);
    ctx.shadowColor = "#ff2d95";
    ctx.shadowBlur = Math.max(6, w / 80);
    ctx.fillStyle = "#ffffff";
    ctx.fillText(label, pad, h - pad);

    const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);

    try {
      canvas.toBlob((blob) => {
        if (!blob) return downloadDataUrl(canvas.toDataURL("image/png"), stamp);
        const objUrl = URL.createObjectURL(blob);
        triggerDownload(objUrl, `bada-bing_${stamp}.png`);
        setTimeout(() => URL.revokeObjectURL(objUrl), 4000);
      }, "image/png");
    } catch (_) {
      // CORS-tainted canvas (cross-origin stream without proper headers) or
      // older browser — fall back to data URL, which may also be blocked but
      // is worth a shot.
      downloadDataUrl(canvas.toDataURL("image/png"), stamp);
    }

    // Camera-flash effect.
    frame.classList.add("is-flashing");
    setTimeout(() => frame.classList.remove("is-flashing"), 360);
  }

  function downloadDataUrl(dataUrl, stamp) {
    triggerDownload(dataUrl, `bada-bing_${stamp}.png`);
  }

  function triggerDownload(href, filename) {
    downloadLink.href = href;
    downloadLink.download = filename;
    downloadLink.hidden = false;
    downloadLink.click();
  }

  /* =========================== Event wiring ======================== */
  captureBtn.addEventListener("click", capture);
  reconnectBtn.addEventListener("click", () => { preferHls = false; reconnectNow(); });
  retryNowBtn.addEventListener("click", () => { preferHls = false; reconnectNow(); });

  unmuteBtn.addEventListener("click", () => {
    video.muted = false;
    video.volume = 1;
    video.play().catch(() => {});
    unmuteBtn.hidden = true;
  });

  video.addEventListener("playing", maybeShowUnmute);

  // Pause/resume reconnect attempts based on tab visibility to save battery
  // and avoid hammering the server while hidden.
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    // When the tab comes back and we're not live, try again promptly.
    if (statusEl.dataset.state !== State.LIVE && !retryTimer) {
      reconnectNow();
    }
  });

  window.addEventListener("online", () => {
    if (statusEl.dataset.state !== State.LIVE) reconnectNow();
  });
  window.addEventListener("offline", () => {
    setStatus(State.OFFLINE, "No internet", "");
    showClosed(true, "You’re offline. We’ll reconnect when you’re back.");
  });

  window.addEventListener("pagehide", () => { destroyed = true; teardown(); });
  window.addEventListener("beforeunload", () => { destroyed = true; teardown(); });

  // hls.js may still be loading (deferred). If WebRTC is unavailable and we
  // need HLS but the lib isn't ready, the connect() flow handles it; we also
  // surface a small note about transport in the footer.
  if (!("RTCPeerConnection" in window)) {
    techLine.textContent = "WebRTC unavailable — using HLS.";
    preferHls = true;
  }

  /* ================== Coop status / now-playing poller ============== */
  /* Self-contained: fetches the public, same-origin /api/status.json the Pi
     rsyncs in over WireGuard, and drives the "Now Spinning" ticker + the
     health panel + a telemetry freshness indicator. This is INTENTIONALLY
     independent of the video player above — the coop can be healthy while the
     stream is down, or the stream can be up while telemetry has gone stale.
     It never throws: every fetch is wrapped in try/catch with an
     AbortController timeout, and missing/null JSON keys degrade to em-dashes.

     status.json shape (from pi/badabing-status.sh), all fields nullable:
       { schema, host, ts, ts_epoch, uptime_s,
         load:{one,five,fifteen}, cpu_temp_c, wifi_rssi_dbm,
         stream:{up,unit_active,last_frame_age_s},
         music:{playing,artist,title},
         battery: null | {voltage,current_ma,percent} }
     The droplet seed file uses a smaller shape
       {status,stream:{up},music:{playing},updated}
     so we also accept `updated` as a fallback timestamp. */
  const STATUS = Object.freeze({
    url: "/api/status.json",
    // Base poll interval (ms). A small random jitter is added each tick so a
    // wall of reconnecting clients doesn't sync up into a thundering herd.
    intervalMs: 12000,
    jitterMs: 2500,
    // Per-request timeout.
    fetchTimeoutMs: 8000,
    // If the report's timestamp is older than this, telemetry is "stale".
    staleAfterMs: 60000,
  });

  const np = {
    box: document.getElementById("nowSpinning"),
    track: document.getElementById("nowSpinningTrack"),
  };
  const tele = {
    box: document.getElementById("tele"),
    label: document.getElementById("teleLabel"),
  };
  const health = {
    stream: document.getElementById("valStream"),
    seen: document.getElementById("valSeen"),
    temp: document.getElementById("valTemp"),
    uptime: document.getElementById("valUptime"),
    wifi: document.getElementById("valWifi"),
    batteryRow: document.getElementById("rowBattery"),
    battery: document.getElementById("valBattery"),
  };
  // If the markup isn't present (e.g. trimmed-down page) just skip the module.
  const statusUiPresent = !!(np.box && tele.box && health.stream);

  let statusTimer = null;
  let statusAbort = null;
  const EMDASH = "—";

  // Coerce a value to a finite number, or null. Accepts numeric strings too.
  function num(v) {
    if (v === null || v === undefined || v === "") return null;
    const n = typeof v === "number" ? v : Number(v);
    return Number.isFinite(n) ? n : null;
  }

  // Resolve the report's epoch-millis timestamp from whichever field exists.
  function reportEpochMs(data) {
    const epoch = num(data && data.ts_epoch);
    if (epoch !== null) return epoch * 1000;
    const iso = (data && (data.ts || data.updated)) || null;
    if (iso) {
      const t = Date.parse(iso);
      if (Number.isFinite(t)) return t;
    }
    return null;
  }

  // Humanize a duration in seconds -> "3d 4h", "5h 12m", "8m", "42s".
  function fmtDuration(totalSec) {
    let s = Math.max(0, Math.floor(totalSec));
    const d = Math.floor(s / 86400); s -= d * 86400;
    const h = Math.floor(s / 3600);  s -= h * 3600;
    const m = Math.floor(s / 60);    s -= m * 60;
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    if (m) return `${m}m`;
    return `${s}s`;
  }

  // Humanize "time since" for the last-seen row.
  function fmtAgo(ms) {
    const sec = Math.round(ms / 1000);
    if (sec < 5) return "just now";
    if (sec < 60) return `${sec}s ago`;
    return `${fmtDuration(sec)} ago`;
  }

  // Map Wi-Fi RSSI (dBm) to a friendly bars/label. Typical range -30 (great)
  // .. -90 (unusable).
  function fmtWifi(dbm) {
    if (dbm === null) return EMDASH;
    let strength;
    if (dbm >= -55) strength = "excellent";
    else if (dbm >= -67) strength = "good";
    else if (dbm >= -75) strength = "fair";
    else strength = "weak";
    return `${dbm} dBm · ${strength}`;
  }

  function setTele(state, label) {
    if (!tele.box) return;
    tele.box.dataset.tele = state;       // live | stale | offline | unknown
    if (tele.label) tele.label.textContent = label;
  }

  function setNowSpinning(music) {
    if (!np.box) return;
    const playing = !!(music && music.playing);
    const artist = music && typeof music.artist === "string" ? music.artist.trim() : "";
    const title = music && typeof music.title === "string" ? music.title.trim() : "";

    if (playing && (artist || title)) {
      let text;
      if (artist && title) text = `${artist} — ${title}`;
      else text = artist || title;
      np.track.textContent = text;
      np.box.dataset.playing = "true";
      np.box.removeAttribute("title");
      np.box.title = text;
    } else {
      np.track.textContent = "The jukebox is quiet…";
      np.box.dataset.playing = "false";
      np.box.removeAttribute("title");
    }
  }

  // Render the health rows from a (possibly partial) report.
  function renderHealth(data, ageMs) {
    const stream = (data && data.stream) || null;
    const up = !!(stream && stream.up);
    health.stream.textContent = stream ? (up ? "On stage" : "Dark") : EMDASH;
    health.stream.dataset.up = stream ? String(up) : "";

    // Last seen.
    if (ageMs === null) {
      health.seen.textContent = EMDASH;
    } else {
      health.seen.textContent = fmtAgo(ageMs);
    }

    // CPU temperature.
    const temp = num(data && data.cpu_temp_c);
    health.temp.textContent = temp === null ? EMDASH : `${temp.toFixed(1)} °C`;

    // Uptime.
    const up_s = num(data && data.uptime_s);
    health.uptime.textContent = up_s === null ? EMDASH : fmtDuration(up_s);

    // Wi-Fi signal.
    health.wifi.textContent = fmtWifi(num(data && data.wifi_rssi_dbm));

    // Battery — hidden entirely unless the Pi reports it.
    const batt = data && data.battery;
    if (batt && typeof batt === "object") {
      const pct = num(batt.percent);
      const volts = num(batt.voltage);
      const parts = [];
      if (pct !== null) parts.push(`${Math.round(pct)}%`);
      if (volts !== null) parts.push(`${volts.toFixed(2)} V`);
      if (parts.length) {
        health.battery.textContent = parts.join(" · ");
        health.batteryRow.hidden = false;
      } else {
        health.batteryRow.hidden = true;
      }
    } else {
      health.batteryRow.hidden = true;
    }
  }

  // Apply a successful report.
  function applyStatus(data) {
    setNowSpinning(data && data.music);

    const epochMs = reportEpochMs(data);
    const ageMs = epochMs === null ? null : Date.now() - epochMs;

    renderHealth(data, ageMs);

    if (ageMs === null) {
      // We got JSON but no usable timestamp (e.g. the seed file with
      // updated:null). Treat as live-but-unknown so the panel still shows.
      setTele("live", "Coop telemetry live");
    } else if (ageMs > STATUS.staleAfterMs) {
      setTele("stale", `Coop telemetry stale · ${fmtAgo(ageMs)}`);
    } else {
      setTele("live", "Coop telemetry live");
    }
  }

  async function pollStatus() {
    if (!statusUiPresent || destroyed) return;
    // Don't poll a hidden tab; visibilitychange resumes us.
    if (document.hidden) return;

    if (statusAbort) {
      try { statusAbort.abort(); } catch (_) {}
    }
    statusAbort = new AbortController();
    const signal = statusAbort.signal;
    const killer = setTimeout(() => {
      try { statusAbort.abort(); } catch (_) {}
    }, STATUS.fetchTimeoutMs);

    try {
      const res = await fetch(STATUS.url, {
        method: "GET",
        cache: "no-store",
        headers: { "Accept": "application/json" },
        signal,
      });
      if (!res.ok) throw new Error("status-" + res.status);
      const data = await res.json();
      applyStatus(data);
    } catch (_) {
      // Network error, abort/timeout, or bad JSON — telemetry is offline.
      // We leave the last-known health values in place but flag them stale.
      setTele("offline", "Coop telemetry offline");
    } finally {
      clearTimeout(killer);
    }
  }

  function scheduleStatus() {
    if (!statusUiPresent) return;
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    if (destroyed || document.hidden) return;
    const wait = STATUS.intervalMs + Math.floor(Math.random() * STATUS.jitterMs);
    statusTimer = setTimeout(async () => {
      statusTimer = null;
      await pollStatus();
      scheduleStatus();
    }, wait);
  }

  function startStatus() {
    if (!statusUiPresent || destroyed || document.hidden) return;
    // Kick an immediate poll, then settle into the jittered cadence.
    pollStatus().finally(scheduleStatus);
  }

  function stopStatus() {
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    if (statusAbort) {
      try { statusAbort.abort(); } catch (_) {}
      statusAbort = null;
    }
  }

  if (statusUiPresent) {
    // Pause polling when the tab is hidden; resume (with a fresh poll) when it
    // returns. This is separate from the player's own visibility handling.
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        stopStatus();
      } else if (!destroyed) {
        startStatus();
      }
    });
    window.addEventListener("pagehide", stopStatus);
    window.addEventListener("beforeunload", stopStatus);
  }

  /* ------------------------------ Go! ------------------------------ */
  connect();
  startStatus();
})();
