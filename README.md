# Hammertunes.spoon

A menubar **pill** for [Hammerspoon](https://www.hammerspoon.org/) that shows
what's playing and lets you control it - artwork, a live progress bar,
press-and-hold scrubbing, click-zone transport, and a rich right-click menu.

Currently backed by **Spotify** (AppleScript + Web API). The backend sits behind
a small interface so **Apple Music** can be added later.

## Features

- **Now-playing pill** with album (or playlist) cover art, song/artist, and a
  progress bar that doubles as the menubar item.
- **Click zones:** left = previous/restart, middle = play/pause, right = next.
- **Press-and-hold to scrub** to a position; drag to seek.
- **Double-click** the middle to copy "Song by Artist".
- **Right-click menu:** shuffle (incl. read-only Smart Shuffle state),
  like/unlike, **Add to Playlist** and **Play Playlist** with cover thumbnails,
  Play Liked Songs. Play Playlist pins recently-played playlists (the only way
  Discover Weekly / Release Radar show up without following them) on top.

## Install

It's a plain Spoon directory - no zip needed.

```sh
git clone https://github.com/tokenmaxxr/Hammertunes.spoon \
  ~/.hammerspoon/Spoons/Hammertunes.spoon
```

Update later with `git -C ~/.hammerspoon/Spoons/Hammertunes.spoon pull`.

## Spotify setup (one time)

The Web API features (playlists, like, context name) need a Spotify app:

1. Go to <https://developer.spotify.com/dashboard> → **Create app**.
2. Set the **Redirect URI** to exactly `http://127.0.0.1:53127/callback`.
3. Copy the app's **Client ID**.

Then in your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("Hammertunes")
spoon.Hammertunes:authenticate("YOUR_SPOTIFY_CLIENT_ID")  -- one time; opens a browser
spoon.Hammertunes:start()
```

After the first auth, the refresh token (and Client ID) live in the macOS
Keychain, so on later launches you only need:

```lua
hs.loadSpoon("Hammertunes")
spoon.Hammertunes:start()
```

### Optional: hide some contexts

```lua
spoon.Hammertunes.hiddenContexts = { "spotify:playlist:XXXX" }  -- pill shows ♪
spoon.Hammertunes:start()
```

## Requirements

- macOS + Hammerspoon
- The Spotify desktop app (transport/state go through it via AppleScript)
- A Spotify account; a free Spotify developer app for the Web API features

## Status / roadmap

- ✅ Spotify backend (transport, state, playlists, like, recently-played).
- ⏳ Apple Music backend - reserved in `backends/applemusic.lua`. Needs the
  state-fetch (`SPOTIFY_QUERY` AppleScript) and transport (`hs.spotify.*`) in
  `pill.lua` lifted behind the backend interface so `hs.itunes` / the Music app
  can slot in. See the notes in that file.

## License

MIT - see [LICENSE](LICENSE).
