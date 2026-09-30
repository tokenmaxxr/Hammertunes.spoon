# Ideas

Exploratory notes and "wouldn't it be nice" entries that aren't committed plans.
Things land here before they earn a place on a roadmap.

## Cross-platform like / add-to-playlist via AppleScript

**Question:** Could we drive like and add-to-playlist through `tell application ...`
for both backends, the way the Apple Music backend already does, and drop
Spotify's Web API + OAuth dependency?

**Answer: no, not for Spotify.** The asymmetry in the codebase (AppleScript for
Music, Web API for Spotify) isn't a style choice - it's the maximum each app's
scripting dictionary permits.

Spotify's dictionary (`sdef /Applications/Spotify.app`) is transport-only:

- Commands: `play`, `pause`, `playpause`, `next track`, `previous track`,
  `play track`. Nothing else.
- Track properties are all reads. The one tease, `starred`, is `access="r"`
  (read-only) and is a relic of the long-dead starring feature anyway.
- There is no playlist class at all - you can't even enumerate playlists, let
  alone add to one.

So there's no `set starred to true` or `add current track to playlist`
equivalent. That's why `backends/spotify.lua` only uses AppleScript for the
now-playing query and shuffle toggle, and goes through the Web API + OAuth for
like / playlists / recently-played.

Apple Music, by contrast, ships a real scripting dictionary with library
mutation - `set favorited of current track` and `duplicate current track to
user playlist ...` - which is exactly what the Apple Music backend uses.

**Known gap on the Apple Music side:** streaming catalog tracks on macOS Tahoe
throw error -1728 on `current track`, so like / add-to-playlist fail closed on
the MediaRemote fallback path (library tracks still work).
