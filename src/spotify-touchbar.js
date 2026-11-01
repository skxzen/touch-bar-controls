// Spotify Touch Bar — local companion, no Spotify credentials required.
(() => {
  "use strict";
  if (globalThis.__spotifyTouchBar) return;
  globalThis.__spotifyTouchBar = true;
  const TOKEN = "__PAIRING_TOKEN__";
  const URL = "http://127.0.0.1:43821/sync";
  let stopped = false, delay = 500, lastError = "";
  const finite = (x, fallback = 0) => Number.isFinite(x) ? x : fallback;
  const clamp = (x, min, max) => Math.min(max, Math.max(min, x));
  const read = (p, name, fallback) => {
    try { return typeof p[name] === "function" ? p[name]() : fallback; }
    catch (_) { return fallback; }
  };
  function timing(p) {
    // Match Spotify's own timeline: its clock stops during buffering and
    // advances by the reported speed, not unconditionally by wall-clock time.
    let state;
    try { state = p.origin?.getState?.() ?? p.origin?._state; } catch (_) {}
    if (state && Number.isFinite(state.positionAsOfTimestamp) && Number.isFinite(state.duration)) {
      const duration = Math.max(0, state.duration);
      let position = state.positionAsOfTimestamp;
      if (state.hasContext && !state.isPaused && !state.isBuffering && Number.isFinite(state.timestamp)) {
        const speed = Math.max(0, finite(state.speed));
        position += Math.max(0, Date.now() - state.timestamp) * speed;
      }
      return {position: clamp(position, 0, duration), duration};
    }
    const duration = Math.max(0, finite(read(p, "getDuration", 0)));
    return {position: clamp(finite(read(p, "getProgress", 0)), 0, duration), duration};
  }
  function snapshot(p) {
    const item = p.data?.item;
    const m = item?.metadata || {};
    return {
      title: m.title || item?.name || "Aucun titre",
      artwork: (() => {
        const raw = m.image_small_url || m.image_url || m.image_large_url || "";
        return raw.startsWith("spotify:image:") ? "https://i.scdn.co/image/" + raw.slice(14) : raw;
      })(),
      artist: m.artist_name || "", uri: item?.uri || "",
      playing: !!read(p, "isPlaying", false),
      ...timing(p),
      volume: clamp(finite(read(p, "getVolume", 0)), 0, 1),
      heart: !!read(p, "getHeart", false),
      shuffle: !!read(p, "getShuffle", false),
      repeat: finite(read(p, "getRepeat", 0)),
      muted: !!read(p, "getMute", false),
      error: lastError
    };
  }
  async function execute(p, c) {
    const simple = {play: "togglePlay", previous: "back", next: "next",
      heart: "toggleHeart", shuffle: "toggleShuffle", repeat: "toggleRepeat", mute: "toggleMute"};
    if (simple[c.action]) {
      if (typeof p[simple[c.action]] !== "function") throw Error("Commande indisponible : " + c.action);
      await p[simple[c.action]]();
    } else if (c.action === "volume" && Number.isFinite(c.value)) {
      await p.setVolume(clamp(c.value, 0, 1));
    } else if (c.action === "seek" && Number.isFinite(c.value)) {
      // A seek for the previous track must never affect a new track.
      if (c.uri !== (p.data?.item?.uri || "")) return;
      const {duration} = timing(p);
      if (duration > 1) await p.seek(Math.max(2, Math.round(clamp(c.value, 0, 1) * duration)));
    } else throw Error("Commande inconnue");
  }
  async function tick() {
    if (stopped) return;
    const p = globalThis.Spicetify?.Player;
    if (!p?.data || typeof p.isPlaying !== "function") {
      setTimeout(tick, 1000); return;
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2500);
    try {
      const response = await fetch(URL, {
        method: "POST", headers: {"Content-Type": "application/json", "X-STB-Token": TOKEN},
        body: JSON.stringify(snapshot(p)), signal: controller.signal, credentials: "omit"
      });
      if (!response.ok) throw Error("Compagnon HTTP " + response.status);
      const result = await response.json();
      clearTimeout(timeout);
      lastError = "";
      for (const command of (result.commands || []).slice(0, 32)) {
        try { await execute(p, command); }
        catch (error) { lastError = String(error.message || error).slice(0, 160); console.warn("[Touch Bar]", error); }
      }
      delay = 500;
    } catch (_) { delay = Math.min(delay * 1.5, 5000); }
    finally { clearTimeout(timeout); if (!stopped) setTimeout(tick, delay); }
  }
  globalThis.addEventListener("beforeunload", () => { stopped = true; }, {once: true});
  tick();
})();
