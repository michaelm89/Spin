// Spotify Web API from the browser: Authorization Code with PKCE (no client secret),
// tokens kept in this browser's localStorage.
const SCOPES = [
  "user-read-playback-state",
  "user-modify-playback-state",
  "user-read-currently-playing",
  "user-top-read",
  "user-read-recently-played",
].join(" ");

const store = {
  get: (key) => { try { return JSON.parse(localStorage.getItem(key)); } catch { return null; } },
  set: (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch {} },
  remove: (key) => { try { localStorage.removeItem(key); } catch {} },
};

export class SpotifyError extends Error {
  constructor(status, message, reason) {
    super(message);
    this.status = status;
    this.reason = reason;
  }
}

export class Spotify {
  /** This page's address, which must be listed as a Redirect URI in the Spotify app. */
  static get redirectURI() {
    return location.origin + location.pathname.replace(/index\.html$/, "");
  }

  get clientID() { return store.get("spin.clientID") ?? ""; }
  set clientID(value) { store.set("spin.clientID", value.trim()); }
  get isConnected() { return !!store.get("spin.tokens")?.refresh && !!this.clientID; }

  async connect() {
    const verifier = randomString(64);
    const state = randomString(16);
    sessionStorage.setItem("spin.verifier", verifier);
    sessionStorage.setItem("spin.state", state);
    const params = new URLSearchParams({
      client_id: this.clientID,
      response_type: "code",
      redirect_uri: Spotify.redirectURI,
      scope: SCOPES,
      state,
      code_challenge_method: "S256",
      code_challenge: await challenge(verifier),
    });
    location.assign(`https://accounts.spotify.com/authorize?${params}`);
  }

  /** Finishes sign-in if Spotify just redirected back here. Returns an error message or null. */
  async handleRedirect() {
    const params = new URLSearchParams(location.search);
    if (!params.has("code") && !params.has("error")) return null;
    history.replaceState(null, "", Spotify.redirectURI);
    if (params.get("error")) return `Spotify said: ${params.get("error")}`;
    if (params.get("state") !== sessionStorage.getItem("spin.state")) return "Sign-in didn't match; try again.";
    await this.requestToken({
      grant_type: "authorization_code",
      code: params.get("code"),
      redirect_uri: Spotify.redirectURI,
      client_id: this.clientID,
      code_verifier: sessionStorage.getItem("spin.verifier") ?? "",
    });
    sessionStorage.removeItem("spin.verifier");
    sessionStorage.removeItem("spin.state");
    return null;
  }

  disconnect() { store.remove("spin.tokens"); }

  async requestToken(form) {
    const response = await fetch("https://accounts.spotify.com/api/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(form),
    });
    const json = await response.json().catch(() => ({}));
    if (!response.ok || !json.access_token) {
      if (json.error === "invalid_grant") this.disconnect();
      throw new SpotifyError(response.status, json.error_description || "Couldn't get a Spotify token.");
    }
    const previous = store.get("spin.tokens") ?? {};
    store.set("spin.tokens", {
      access: json.access_token,
      refresh: json.refresh_token ?? previous.refresh,
      expires: Date.now() + (json.expires_in - 60) * 1000,
    });
  }

  async accessToken() {
    const tokens = store.get("spin.tokens");
    if (!tokens?.refresh) throw new SpotifyError(401, "Not connected to Spotify.");
    if (Date.now() < tokens.expires) return tokens.access;
    await this.requestToken({ grant_type: "refresh_token", refresh_token: tokens.refresh, client_id: this.clientID });
    return store.get("spin.tokens").access;
  }

  async api(path, { method = "GET", body } = {}, retried = false) {
    const response = await fetch(`https://api.spotify.com/v1${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${await this.accessToken()}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (response.status === 401 && !retried) {
      const tokens = store.get("spin.tokens");
      if (tokens) store.set("spin.tokens", { ...tokens, expires: 0 });
      return this.api(path, { method, body }, true);
    }
    if (response.status === 204 || response.status === 202) return null;
    const json = await response.json().catch(() => null);
    if (!response.ok) {
      throw new SpotifyError(response.status, json?.error?.message || `Spotify error ${response.status}`, json?.error?.reason);
    }
    return json;
  }

  // --- Data -----------------------------------------------------------------

  player() { return this.api("/me/player"); }

  async topTracks() {
    const tracks = [];
    for (const range of ["long_term", "medium_term", "short_term"]) {
      const page = await this.api(`/me/top/tracks?limit=50&time_range=${range}`);
      tracks.push(...(page?.items ?? []));
    }
    return tracks;
  }

  async recentlyPlayed() {
    const page = await this.api("/me/player/recently-played?limit=50");
    return page?.items ?? [];
  }

  // --- Controls (need Spotify Premium and an active device) ------------------

  play() { return this.api("/me/player/play", { method: "PUT" }); }
  pause() { return this.api("/me/player/pause", { method: "PUT" }); }
  next() { return this.api("/me/player/next", { method: "POST" }); }
  previous() { return this.api("/me/player/previous", { method: "POST" }); }
}

function randomString(length) {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes, (b) => chars[b % chars.length]).join("");
}

async function challenge(verifier) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
