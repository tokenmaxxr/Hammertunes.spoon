# Repository guidance

Hammertunes is a Hammerspoon Spoon written in Lua. Keep changes compatible
with the Lua version shipped by Hammerspoon and avoid adding dependencies that
require a separate runtime.

## Structure

- `init.lua` is the Spoon entry point and owns lifecycle, backend selection,
  persisted settings, and wiring between the pill and backend.
- `backends/interface.lua` defines and verifies the shared backend contract.
- `backends/spotify.lua` and `backends/applemusic.lua` implement that contract.
- `pill.lua`, `menubar.lua`, and `rightclick.lua` own the menubar UI, click
  gestures, and menu actions.
- `backends/progress.lua` and `backends/pollinterval.lua` hold shared logic.
- `tests/` contains the Lua test suite and Hammerspoon stubs.

## Development

- Run `make test` to syntax-check the Lua sources and run the unit suite. It
  requires `lua` and `luac` on `PATH`.
- Keep backend behavior aligned with `backends/interface.lua`; update both
  backend implementations when changing required shared behavior.
- Keep user-facing setup and controls documented in `README.md`.
- Treat specs and plans in `docs/superpowers/` as project documentation. Their
  implementation notes do not require a particular assistant, plugin, or
  workflow; use the repository guidance and the task's requirements.
