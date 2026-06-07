# Hammertunes.spoon

<p align="center">
  <img src="https://images1.memedroid.com/images/UPLOADED5/5034ea1a8efe9.jpeg" alt="MC Hammer — Stop! Hammer Time!" width="400"><br>
  <em>Stop! Hammertunes.</em>
</p>

A menubar **pill** for [Hammerspoon](https://www.hammerspoon.org/) that shows
what's playing and lets you control it - artwork, a live progress bar,
press-and-hold scrubbing, click-zone transport, and a rich right-click menu.

Works with **Spotify** (AppleScript + Web API) or **Apple Music** (AppleScript +
the private MediaRemote framework), selectable at runtime - both sit behind a
small shared backend interface, and you can flip between them from the menu.

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

## Choosing a backend

Spotify is the default. To use Apple Music (no setup or auth needed):

```lua
spoon.Hammertunes:start({ backend = "applemusic" })
-- or
spoon.Hammertunes:setBackend("applemusic"):start()
```

Or just flip between them from the pill's **right-click menu → "Switch to …"**.
That choice is saved and **takes precedence** over `:setBackend()` / `opts.backend`
on later launches, so you can leave your `init.lua` as-is and toggle from the menu.

## Requirements

- macOS + Hammerspoon
- The Spotify or Apple Music (**Music**) desktop app - transport and state go
  through it via AppleScript.
- For Spotify's Web API extras (playlists, like, context name): a Spotify account
  and a free Spotify developer app. Apple Music needs none of this.

## Status

- ✅ **Spotify** - transport, state, playlists, like, recently-played, shuffle.
- ✅ **Apple Music** - transport, now-playing, artwork and favorite for library
  tracks, and library playlists. Streaming catalog tracks (which the Music
  AppleScript dictionary can't read on macOS Tahoe) fall back to the private
  MediaRemote framework for title/artist/progress.

## License

MIT - see [LICENSE](LICENSE).
