# Spin

A record player room that plays along with Spotify. Your most-played albums cover the back wall, the song that's playing spins on the turntable (its album leans on a stand at the left), and every song that finishes or gets skipped lands on the pile at the right.

![The Spin room](previews/room.png)

There are two versions:

- **Mac app** (`Spin/`): sits on your desktop behind your icons, on every display, and syncs with the Spotify app instantly.
- **Web version** (`docs/`): the same room in a browser, published at **https://michaelm89.github.io/Spin/**.

## Mac app

Needs macOS 14 or later and the Spotify app. Xcode isn't required, only the Command Line Tools.

```bash
./build.sh install
```

This builds `Spin.app`, copies it to Applications and starts it. Spin lives in the menu bar (the record icon), where you can switch between the room and a floating record, turn the tonearm on or off, connect your Spotify account and set it to launch at login. The first time, macOS asks whether Spin may control Spotify; click **Allow**.

`Spin.xcodeproj` is there too, if you ever want to open the project in Xcode.

## Web version

A static page (Three.js, no build step) that talks to the Spotify Web API from your browser:

- The wall shows your top tracks' albums.
- The turntable shows what's playing on any of your devices (checked every few seconds).
- The pile combines songs this browser saw finish or get skipped with Spotify's recently played list.
- The buttons on the turntable control playback (needs Spotify Premium).

To run it locally: `python3 -m http.server 8000 --bind 127.0.0.1 --directory docs`, then open http://127.0.0.1:8000/.

## Connecting Spotify

Both versions use a free Spotify developer app for the album wall (and, on the web, for everything):

1. Open the [Spotify developer dashboard](https://developer.spotify.com/dashboard) and create an app (any name, e.g. "Spin"), with **Web API** ticked.
2. Add these **Redirect URIs**:
   - `http://127.0.0.1:8765/callback` (Mac app)
   - `https://michaelm89.github.io/Spin/` (web version)
   - `http://127.0.0.1:8000/` (web version, running locally)
3. Copy the app's **Client ID** and paste it into Spin: from the menu bar on the Mac, or the ⚙︎ button on the web page.

Sign-in uses PKCE, so there's no client secret anywhere in this project. Tokens stay on your Mac (Keychain) or in your browser.

While the Spotify app is in development mode, only accounts you add under **User Management** in the dashboard can sign in. That's fine for personal use.
