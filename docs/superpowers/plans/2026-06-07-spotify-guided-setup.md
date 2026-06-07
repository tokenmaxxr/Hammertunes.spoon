# Guided Spotify Web API Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users enable Spotify's optional Web API features through a guided dialog flow from the pill's right-click menu (plus a one-time offer), with no `init.lua` editing or hand-copied IDs.

**Architecture:** The wizard is a Spotify concern living in `backends/spotify.lua` as a thin `setup()` wrapper over the existing `authenticate()`, plus `needsSetup()`. `pill.lua` surfaces an "Enable Spotify extras…" menu item via capability checks (so Apple Music shows nothing). `init.lua` is unchanged. The one-time offer fires from the backend's `start()` when unauthenticated, tracked by an `hs.settings` flag.

**Tech Stack:** Lua, Hammerspoon (`hs.dialog`, `hs.pasteboard`, `hs.urlevent`, `hs.settings`, `hs.timer`).

**Testing note:** This feature is dialog/browser/Keychain-coupled, so there is no meaningful pure logic to unit-test (TDD does not apply here). Each task verifies with `luac -p` (syntax) and `make test` (the existing 27-test suite must stay green — regression guard), and the final task is a manual Hammerspoon walkthrough. Reference: `docs/superpowers/specs/2026-06-06-spotify-guided-setup-design.md`.

---

## File Structure

- `backends/spotify.lua` — **modify.** Add `needsSetup()`, the `setup()` wizard, the `module.needsSetup`/`module.setup` exports, and a one-time-offer hook inside `module.start`'s unauthenticated branch.
- `pill.lua` — **modify.** Swap the single "Re-authenticate" block in `showRightClickMenu` for a branch that shows "Enable Spotify extras…" when `api.needsSetup()` is true, else the existing "Re-authenticate".
- `README.md` — **modify.** Rewrite the Spotify section's "### 3. (Optional) Enable the Web API extras" to point at the menu item, keeping the manual steps as a collapsible fallback.
- `init.lua` — **no change.**

---

## Task 1: Backend wizard, `needsSetup`/`setup`, and one-time offer

**Files:**
- Modify: `backends/spotify.lua` (insert before `module.start` at line 852; edit `module.start` body at lines 856–859)

Verified API facts used below: `hs.dialog.blockAlert(message, informativeText, buttonOne, buttonTwo)` returns the pressed button's label (modal/blocking). `hs.dialog.textPrompt(message, informativeText, defaultText, buttonOne, buttonTwo)` returns **two** values, `(buttonLabel, enteredText)`, in that order. `hs.settings.get(key)` returns `nil` for an unset key and round-trips booleans. `REDIRECT_URI` is the module-level constant `"http://127.0.0.1:53127/callback"`.

- [ ] **Step 1: Insert the wizard block immediately before `module.start`**

Insert the following just before the line `module.start = function(changeCallback)` (currently line 852). It defines a module-level local for the settings key, `needsSetup`, the wizard, and the two new exports. `needsSetup` reuses the existing `loadCreds` / `cachedClientId` / `cachedRefreshToken`. The wizard calls the existing `module.authenticate`.

```lua
-- ---------------------------------------------------------------------------
-- Guided Web API setup (optional)
-- ---------------------------------------------------------------------------
-- Wraps authenticate() so the user never edits init.lua or hand-copies IDs.
-- Reached from the right-click menu ("Enable Spotify extras…") and offered once
-- on the first unauthenticated run. A per-user Spotify app is unavoidable
-- (free dev-mode apps are capped at 25 manually-added users), so the wizard
-- guides app creation rather than shipping a shared key.

local OFFER_SETTING_KEY = "Hammertunes.spotifyExtrasOfferShown"

-- True when the Web API has no usable credentials yet.
local function needsSetup()
  loadCreds()
  return not (cachedClientId and cachedRefreshToken)
end

-- Consent -> Client ID -> approval. Each dialog is modal; cancelling any step
-- (or an empty Client ID) aborts with no state change.
local function setupWizard()
  local choice = hs.dialog.blockAlert(
    "Enable Spotify extras?",
    "Adds playlists, like/unlike, Play Liked Songs, and the playing-from name " ..
    "to the menu.\n\n" ..
    "It's free. You create a Spotify API key with limited permissions (just " ..
    "playback and your playlists/library) and approve it on Spotify's own " ..
    "site, so the spoon never sees your password. Everything it stores - the " ..
    "login and cached playlists - stays on your Mac.",
    "Set it up", "Not now"
  )
  if choice ~= "Set it up" then return end

  -- Pre-stage the redirect URI on the clipboard and open the dashboard so the
  -- user can paste both pieces without leaving the flow.
  hs.pasteboard.setContents(REDIRECT_URI)
  hs.urlevent.openURL("https://developer.spotify.com/dashboard")

  local btn, clientId = hs.dialog.textPrompt(
    "Paste your Spotify Client ID",
    "In the dashboard that just opened:\n" ..
    "  1. Create app\n" ..
    "  2. Set the Redirect URI to (already copied to your clipboard):\n" ..
    "       " .. REDIRECT_URI .. "\n" ..
    "  3. Copy the app's Client ID and paste it below.",
    "", "Continue", "Cancel"
  )
  if btn ~= "Continue" then return end
  clientId = clientId and clientId:gsub("%s+", "") or ""
  if clientId == "" then
    hs.alert.show("Spotify setup cancelled (no Client ID)")
    return
  end
  module.authenticate(clientId)
end

module.needsSetup = needsSetup
module.setup = setupWizard

```

- [ ] **Step 2: Add the one-time offer inside `module.start`'s unauthenticated branch**

Replace the current unauthenticated branch (lines 856–859):

```lua
  if not (cachedClientId and cachedRefreshToken) then
    log.i("not authenticated; skipping context fetch")
    return
  end
```

with:

```lua
  if not (cachedClientId and cachedRefreshToken) then
    log.i("not authenticated; skipping context fetch")
    -- Offer the guided setup once, ever (deferred so the pill renders first).
    -- The flag is set when shown, not on success, so declining doesn't re-prompt.
    if not hs.settings.get(OFFER_SETTING_KEY) then
      hs.settings.set(OFFER_SETTING_KEY, true)
      hs.timer.doAfter(1.5, setupWizard)
    end
    return
  end
```

- [ ] **Step 3: Syntax-check**

Run: `luac -p backends/spotify.lua`
Expected: no output (exit 0).

- [ ] **Step 4: Regression-check the existing suite**

Run: `make test`
Expected: ends with `27 passed, 0 failed` and `luac OK:` for all five source files.

- [ ] **Step 5: Commit**

```sh
git add backends/spotify.lua
git commit -m "Add guided Spotify Web API setup wizard (needsSetup/setup + one-time offer)"
```

---

## Task 2: Surface "Enable Spotify extras…" in the menu

**Files:**
- Modify: `pill.lua` (the Re-authenticate block in `showRightClickMenu`, lines 479–482)

- [ ] **Step 1: Replace the Re-authenticate block**

Replace lines 479–482:

```lua
  if api and api.supportsReauth then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Re-authenticate", fn = function() api.authenticate() end }
  end
```

with:

```lua
  if api and api.needsSetup and api.needsSetup() then
    -- Spotify, not yet authenticated: offer the guided setup. Deferred via
    -- doAfter(0) because the wizard is modal and popupMenu is still blocking.
    items[#items + 1] = { title = "-" }
    items[#items + 1] = {
      title = "Enable Spotify extras…",
      fn = function() hs.timer.doAfter(0, api.setup) end,
    }
  elseif api and api.supportsReauth then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Re-authenticate", fn = function() api.authenticate() end }
  end
```

Note: Apple Music exposes neither `needsSetup` nor `supportsReauth`, so it shows neither item. After a successful setup, `needsSetup()` returns false and the item flips to "Re-authenticate" on the next menu open.

- [ ] **Step 2: Syntax-check**

Run: `luac -p pill.lua`
Expected: no output (exit 0).

- [ ] **Step 3: Regression-check**

Run: `make test`
Expected: `27 passed, 0 failed`.

- [ ] **Step 4: Commit**

```sh
git add pill.lua
git commit -m "Show 'Enable Spotify extras…' menu item when Spotify is unauthenticated"
```

---

## Task 3: Update the README Spotify setup section

**Files:**
- Modify: `README.md` (the "### 3. (Optional) Enable the Web API extras" subsection, lines 66–84)

- [ ] **Step 1: Replace the step-3 subsection**

Replace lines 66–84 (from `### 3. (Optional) Enable the Web API extras` through the line ending `...back to just \`:start()\`.`) with:

```markdown
### 3. (Optional) Enable the Web API extras

For playlists, like/unlike, Play Liked Songs, the playing-from name, and the
Smart Shuffle indicator, open the pill's **right-click menu** and choose
**"Enable Spotify extras…"**. It walks you through creating a free Spotify API
key and approving access in your browser - no `init.lua` editing. The first time
you run unauthenticated, the pill also offers this once.

<details>
<summary>Prefer to set it up by hand?</summary>

1. Go to <https://developer.spotify.com/dashboard> → **Create app**.
2. Set the **Redirect URI** to exactly `http://127.0.0.1:53127/callback`.
3. Copy the app's **Client ID**, then authenticate once (opens a browser):

```lua
hs.loadSpoon("Hammertunes")
spoon.Hammertunes:authenticate("YOUR_SPOTIFY_CLIENT_ID")  -- one time
spoon.Hammertunes:start()
```

The login is saved to the macOS Keychain, so later launches need only `:start()`.
</details>
```

- [ ] **Step 2: Verify no em dashes and the section still reads top-to-bottom**

Run: `grep -n "—" README.md`
Expected: no output (the repo uses regular dashes).

- [ ] **Step 3: Commit**

```sh
git add README.md
git commit -m "Point Spotify Web API setup at the in-app wizard; keep manual steps as fallback"
```

---

## Task 4: Manual verification checklist

**Files:** none (manual test in Hammerspoon)

This feature's behavior can only be confirmed in a running Hammerspoon with Spotify. Reload the config (`⌃⌥⌘R` or the menu) and verify:

- [ ] **Step 1: First-run offer appears once**

With no Spotify credentials in the Keychain and the `Hammertunes.spotifyExtrasOfferShown` setting unset, start the spoon on the Spotify backend. ~1.5s after load, the "Enable Spotify extras?" dialog appears. Click **Not now**. Reload again: the dialog does **not** reappear.

(To re-test the offer: `hs.settings.clear("Hammertunes.spotifyExtrasOfferShown")` in the Hammerspoon console, then reload.)

- [ ] **Step 2: Menu item runs the wizard**

Right-click the pill. With no credentials, the menu shows **"Enable Spotify extras…"** (not "Re-authenticate"). Click it: the consent dialog opens; choose **Set it up**; confirm the dashboard opens in the browser and the redirect URI is on your clipboard (paste somewhere to check); the Client ID prompt appears.

- [ ] **Step 3: Completing setup authenticates and flips the menu**

Paste a valid Client ID, click **Continue**, approve in the browser. Confirm auth succeeds (Spotify alert), and that right-clicking the pill now shows **"Re-authenticate"** instead of "Enable Spotify extras…", and that playlists/like items now work.

- [ ] **Step 4: Cancel paths abort cleanly**

Re-run the wizard from the menu and click **Not now** (no change); run again, click **Set it up** then **Cancel** at the Client ID prompt (no change); run again and submit an empty Client ID (shows "cancelled" alert, no change).

- [ ] **Step 5: Apple Music shows no setup item**

Switch to Apple Music via the menu. Right-click: neither "Enable Spotify extras…" nor "Re-authenticate" appears.

---

## Self-review notes

- **Spec coverage:** consent dialog (T1 S1), Client ID capture with clipboard + dashboard (T1 S1), approval via existing `authenticate` (T1 S1), one-time offer with settings flag set-on-show (T1 S2), menu item with capability gating + deferral (T2), `init.lua` unchanged (no task), README rewrite with manual fallback (T3), manual test checklist (T4). All spec sections map to a task.
- **No placeholders:** every code step shows complete literal code; every command has expected output.
- **Naming consistency:** `needsSetup`, `setupWizard` (exported as `module.setup`), `OFFER_SETTING_KEY` = `"Hammertunes.spotifyExtrasOfferShown"`, and `REDIRECT_URI` are used identically across Tasks 1–2 and the manual checklist.
