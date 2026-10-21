import { Room, STACK_LIMIT } from "./room.js";
import { Spotify, SpotifyError } from "./spotify.js";
import { cleanTitle, artworkID, artworkURL } from "./titles.js";

const POLL_VISIBLE_MS = 4000;
const RECENT_REFRESH_MS = 5 * 60 * 1000;
const TOP_REFRESH_MS = 30 * 60 * 1000;

const $ = (id) => document.getElementById(id);
const room = new Room($("room"));
const spotify = new Spotify();

let current = null;      // { id, art, title, artist, playing, position, duration }
let wallIDs = [];
let recentPlays = [];    // [{ art, at }] from Spotify's recently played
let pollTimer = null;

// --- Local history: every song that finishes or is skipped ------------------

const HISTORY_KEY = "spin.history";
function readHistory() {
  try { return JSON.parse(localStorage.getItem(HISTORY_KEY)) ?? []; } catch { return []; }
}
function recordFinished(track) {
  if (!track?.art) return;
  const history = readHistory();
  history.push({ art: track.art, at: Date.now() });
  try { localStorage.setItem(HISTORY_KEY, JSON.stringify(history.slice(-500))); } catch {}
  updateStack();
}

function updateStack() {
  // Newest first, one sleeve per album; the album that just finished goes on top.
  const merged = [...readHistory(), ...recentPlays].sort((a, b) => b.at - a.at);
  const seen = new Set();
  const stack = [];
  for (const { art } of merged) {
    if (seen.has(art)) continue;
    seen.add(art);
    stack.push(artworkURL(art, 640));
    if (stack.length === STACK_LIMIT) break;
  }
  room.setStack(stack);
}

function updateWall() {
  let ids = wallIDs;
  if (!ids.length) {
    // Not connected yet or no top tracks: fall back to what this browser has seen finish.
    const counts = new Map();
    for (const { art } of readHistory()) counts.set(art, (counts.get(art) ?? 0) + 1);
    ids = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([art]) => art);
  }
  room.setWall(ids.map((id) => artworkURL(id, 300)));
}

// --- Polling Spotify ---------------------------------------------------------

function trackFrom(state) {
  const item = state?.item;
  if (!item || item.type !== "track") return null;
  return {
    id: item.id,
    art: artworkID(item.album?.images?.[0]?.url),
    title: cleanTitle(item.name),
    artist: (item.artists ?? []).map((a) => a.name).join(", "),
    playing: !!state.is_playing,
    position: state.progress_ms ?? 0,
    duration: item.duration_ms ?? 0,
  };
}

async function poll() {
  clearTimeout(pollTimer);
  try {
    const next = trackFrom(await spotify.player());
    if (current && (!next || next.id !== current.id)) recordFinished(current);
    if (!next || next.id !== current?.id || next.art !== current?.art) {
      room.setNowPlaying(next && { art: artworkURL(next.art, 640), title: next.title, artist: next.artist });
    }
    room.setPlayback(next ?? { playing: false, position: 0, duration: 0 });
    current = next;
    setStatus(next ? `${next.playing ? "Playing" : "Paused"}: ${next.title} — ${next.artist}` : "Connected. Nothing is playing on Spotify right now.");
  } catch (error) {
    handleError(error);
  }
  if (!document.hidden) pollTimer = setTimeout(poll, POLL_VISIBLE_MS);
}

async function loadLibrary() {
  try {
    const top = await spotify.topTracks();
    const seen = new Set();
    wallIDs = [];
    for (const track of top) {
      const id = artworkID(track.album?.images?.[0]?.url);
      if (id && !seen.has(id)) { seen.add(id); wallIDs.push(id); }
    }
    updateWall();
  } catch (error) { handleError(error); }
}

async function loadRecent() {
  try {
    const items = await spotify.recentlyPlayed();
    recentPlays = items
      .map((item) => ({ art: artworkID(item.track?.album?.images?.[0]?.url), at: Date.parse(item.played_at) }))
      .filter((p) => p.art && p.at);
    updateStack();
  } catch (error) { handleError(error); }
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && spotify.isConnected) poll();
});

// --- Buttons on the turntable ------------------------------------------------

room.onButton(async (button) => {
  if (!spotify.isConnected) { openSettings(); return; }
  try {
    if (button === "playPause") await (current?.playing ? spotify.pause() : spotify.play());
    if (button === "next") await spotify.next();
    if (button === "previous") await spotify.previous();
  } catch (error) {
    if (error instanceof SpotifyError && (error.status === 404 || error.reason === "NO_ACTIVE_DEVICE")) {
      toast("Start Spotify on one of your devices first, then try again.");
    } else if (error instanceof SpotifyError && error.status === 403) {
      toast("Spotify only allows playback control with Premium.");
    } else {
      handleError(error);
    }
  }
  setTimeout(poll, 350);
});

// --- Settings ----------------------------------------------------------------

function setStatus(text) { $("status").textContent = text; }

let toastTimer;
function toast(text) {
  const el = $("toast");
  el.textContent = text;
  el.classList.add("visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("visible"), 4000);
}

function handleError(error) {
  console.warn(error);
  if (error instanceof SpotifyError && error.status === 401) {
    setStatus("Spotify sign-in expired. Connect again.");
    refreshSettings();
  } else if (error instanceof SpotifyError && error.status === 429) {
    setStatus("Spotify asked Spin to slow down; it will catch up shortly.");
  } else {
    setStatus(error.message ?? String(error));
  }
}

function refreshSettings() {
  $("redirect-uri").textContent = Spotify.redirectURI;
  $("client-id").value = spotify.clientID;
  $("connect-section").hidden = spotify.isConnected;
  $("account-section").hidden = !spotify.isConnected;
  if (!spotify.isConnected) setStatus("Not connected. Showing a sample room.");
}

function openSettings() {
  refreshSettings();
  $("settings").showModal();
}

$("settings-button").addEventListener("click", openSettings);
$("connect").addEventListener("click", () => {
  const id = $("client-id").value.trim();
  if (!/^[0-9a-f]{32}$/i.test(id)) { setStatus("That doesn't look like a Client ID (32 letters and numbers)."); return; }
  spotify.clientID = id;
  spotify.connect();
});
$("disconnect").addEventListener("click", () => {
  spotify.disconnect();
  clearTimeout(pollTimer);
  current = null;
  wallIDs = [];
  showSample();
  refreshSettings();
});
$("refresh").addEventListener("click", () => { loadLibrary(); loadRecent(); });

// --- Sample room before connecting --------------------------------------------

function sampleCover(i) {
  const c = document.createElement("canvas");
  c.width = c.height = 256;
  const ctx = c.getContext("2d");
  const hues = [12, 28, 200, 340, 45, 160, 270, 5, 190, 60];
  ctx.fillStyle = `hsl(${hues[i % hues.length]} 55% ${38 + (i * 7) % 25}%)`;
  ctx.fillRect(0, 0, 256, 256);
  ctx.fillStyle = `hsl(${hues[(i * 3 + 4) % hues.length]} 60% 70% / 0.85)`;
  if (i % 3 === 0) { ctx.beginPath(); ctx.arc(128, 128, 70, 0, Math.PI * 2); ctx.fill(); }
  else if (i % 3 === 1) ctx.fillRect(0, 150, 256, 106);
  else for (let k = 0; k < 5; k++) ctx.fillRect(0, k * 52, 256, 22);
  return c.toDataURL("image/jpeg", 0.8);
}

function showSample() {
  const covers = Array.from({ length: 40 }, (_, i) => sampleCover(i));
  room.setWall(covers);
  room.setStack(covers.slice(5, 9));
  room.setNowPlaying({ art: covers[2], title: "Connect Spotify in Settings", artist: "Spin" });
  room.setPlayback({ playing: true, position: 40000, duration: 200000 });
}

// --- Start ------------------------------------------------------------------

(async () => {
  try {
    const error = await spotify.handleRedirect();
    if (error) toast(error);
  } catch (error) {
    toast(error.message);
  }
  refreshSettings();
  if (!spotify.isConnected) {
    showSample();
    return;
  }
  updateWall();
  updateStack();
  poll();
  loadLibrary();
  loadRecent();
  setInterval(() => { if (!document.hidden) loadRecent(); }, RECENT_REFRESH_MS);
  setInterval(() => { if (!document.hidden) loadLibrary(); }, TOP_REFRESH_MS);
})();
