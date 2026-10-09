# tern-spotify architecture

A Tern plugin that shows and controls Spotify playback in a native pane, in
the status line and through palette commands. It is a **Spotify Connect
remote control** built on the Spotify Web API: audio plays on whatever
Spotify device is active (desktop app, phone, speaker, `spotifyd`, …). The
plugin never plays audio itself.

SDK reference: <https://docs.stencil.so/tern/> (append `.md` to any page
path for the Markdown version). The runtime's declarations are in
`tern.d.luau` (`tern plugin types .`).

## Scope

- Sign-in with Authorization Code + PKCE and the user's own Spotify app.
- A `spotify.player` block: Now playing (art, click-to-seek progress, controls,
  a 5% volume bar, Like, Add to playlist), Queue, Library (Liked Songs,
  playlists), Search, Devices; a compact layout for small or floating panes.
- A window half: palette commands with default keys, a status-line segment,
  sign-out, and automatic capture of the sign-in redirect.

Not included: local audio playback, link routing for `open.spotify.com` /
`spotify:` links, remote session hosts (see [Limits](#limits)).

Playback control endpoints require Spotify Premium; reading playback state,
the library and search work without it.

## Package layout

```text
plugin.toml        manifest: id "spotify", host + window entries, styles, [[blocks]] player
host.luau          host entry: defines the block, starts lib/session, migrates storage
window.luau        window entry: commands, binds, status segment, redirect capture
spotify.css        manifest style sheet, scoped to the block's surface

lib/config.luau    endpoints (overridable by environment), redirect URI, scopes, kv keys
lib/text.luau      trim / is_blank / truncate
lib/proc.luau      short helper processes and the PowerShell path
lib/sha256.luau    pure-Luau SHA-256 for the S256 challenge
lib/url.luau       percent-encoding, forms, query parsing
lib/auth.luau      PKCE sign-in, single-flight refresh, sign-out, storage migration
lib/vault.luau     OS protection for the refresh token (DPAPI / keychain / libsecret)
lib/api.luau       Web API requests: Bearer, refresh-and-retry on 401, error classes
lib/session.luau   the host's coordinator: poller, block registry, art, liked, up-next, `now`
lib/model.luau     Spotify JSON -> plain Lua values (null- and gap-tolerant)

lib/state.luau     the block's per-pane state, plus flash / set_focus
lib/field.luau     one-line text fields (UTF-8 editing, UTF-16 caret for `input` nodes)
lib/signin.luau    the sign-in flow in the block
lib/lists.luau     loading the list tabs, switching tabs, search
lib/controls.luau  playback commands and their outcome in the dock
lib/jump.luau      queue jumps (restart the context, or skip forward)
lib/rows.luau      each list tab's rows and what Enter does; selection
lib/picker.luau    the "Add to playlist" sheet
lib/view.luau      the block's view
lib/player.luau    the block definition: keys, view events, lifecycle

tests/             unit tests, a fake `tern`, the runner, a mock Spotify server
docs/              this file and DEVELOPMENT.md
```

## The two halves

Each half runs in its own Luau VM. They share nothing in memory. The host
writes `tern.kv` (a JSON file in the plugin's data directory on the machine
they run on) and the window only reads it; the window reaches the host by
sending a player block UI actions with `cx.session:event` (the sign-in
redirect and Sign out). Keeping one writer matters: kv rewrites the whole
file, and two VMs writing at once race (the last rename wins).

| Half | Runs in | Budget | Owns |
| --- | --- | --- | --- |
| Host (`host.luau`) | The session daemon, or the window when no daemon runs | 2 s per call | Tokens and refresh, polling, the player blocks, the `now` record |
| Window (`window.luau`) | Every Tern window, on its UI thread | 50 ms per call, 4 ms for the status formatter | Commands, binds, the status segment, redirect capture |

### Host: `lib/session.luau`

One host VM serves every player block on the host, so token and playback
state is module-level, not per block.

- **Single-flight refresh** (`lib/auth.luau`). At most one refresh request
  is in flight; callers that need a token meanwhile wait for its answer.
  Spotify may rotate the refresh token on any refresh, so two concurrent
  refreshes could invalidate each other. A refresh whose answer arrives
  after a sign-out, or after the stored refresh token changed, writes
  nothing. `invalid_grant` / `invalid_client` sign the user out. Changing
  the Client ID drops tokens issued for the old app.
- **Early refresh.** A token is refreshed once it has under 5 minutes left.
  The poller makes a request at least every 30 s while signed in, so the
  token in kv always has minutes left for the window half, which never
  refreshes.
- **One poller** of `GET /me/player`:

  | Situation | Next poll |
  | --- | --- |
  | Playing, a block open | 5 s |
  | Playing, no block open | 15 s |
  | Paused or idle, a block open | 8 s |
  | Paused or idle, no block open | 30 s |
  | Network error | 15 s |
  | Near a track's end | when it ends (+0.8 s) |
  | After any command | 0.4 s |
  | After a 429 | not before `Retry-After` |

  While playing with a block open, a 1 s tick re-renders blocks showing Now
  playing; progress between polls is extrapolated locally. Sign-out bumps a
  session epoch: a poll already in flight is dropped when it answers, and a
  poll answer that finds the tokens gone resets the blocks instead of
  republishing playback.
- **Block registry.** Blocks `attach` from `init` (re-attaching replaces the
  pane's entry). Blocks have no close callback, so entries are pruned when
  their pane disappears from `tern.pane.list()`.
- **Album art.** Fetched once per URL (no token sent), cached (12 entries,
  least recently used evicted) and sent to each pane with `cx:blob` before
  the view that uses it.
- **Publishing.** After each poll the `now` record is written to kv when it
  changed, and at least every 60 s while something plays (`seen`), so the
  window half can tell a live record from one a stopped host left behind.
- **Optimistic updates.** Play/pause, seek, volume, shuffle and repeat patch
  the playback immediately; the poll that follows every command corrects a
  failed one.

### Host: the `spotify.player` block (`lib/player.luau` and the block modules under it, `lib/view.luau`)

- `main`: a `tabs` strip (Now, Queue, Library, Search, Devices) over the
  tab. Lists are `list`/`item` nodes keyed per row and capped in height to
  the pane, so the tab strip stays put.
- `dock`: device, volume, the latest message (command errors, rate limits),
  Sign out, and the keys of the current tab.
- Signed out, `main` is the sign-in flow instead.
- Keys: `space` play/pause, `n`/`p` next/previous, `←`/`→` seek 10 s (Now
  tab; `shift` skips), `+`/`-` volume, `s` shuffle, `r` repeat, `1`–`5` and
  `tab` switch tabs, `/` search, `↑`/`↓`/`j`/`k`/`PageUp`/`PageDown`/`Home`/
  `End` select, `enter` play/open, `a` add to queue, `esc`/`backspace` back
  out of a playlist, `f5` reload. Keys the block ignores return `false`.
- Clickable bars. Tern has no slider node and `progress`/`meter` report no
  click position, so the progress bar (50 segments, seek to the segment's
  middle, sent in ‰) and the volume bar (20 segments of 5%) are rows of `el`
  buttons styled as one thin track (`.sp-bar`, `.sp-seg`, `.sp-fill` in
  `spotify.css`). The volume label mutes: the Web API has no mute, so mute
  is volume 0 and unmute restores the remembered level.
- Chips are `el` buttons styled like Tern's badge (`.sp-chip`: 18 px, `0 7px`,
  500 11px sans, tone color with a 10% fill and 22% ring) because a badge can't
  hold an icon or a tooltip; each has an icon and a tooltip naming its key.
- "Next: …" under the track comes from the first `GET /me/player/queue` entry,
  read by the session when the track, shuffle or repeat changes (and after
  Add to queue), only while a block is open.
- Queue tab: Enter or double-click on an upcoming song plays it. The Web API
  has no "skip N" and no queue-position jump (`POST /me/player/next` takes only
  `device_id`; `GET /me/player/queue` doesn't mark which entries the user
  queued). So:
  - When the song belongs to the album or playlist playing, the block
    restarts that context at it (`PUT /me/player/play` with `offset.uri`,
    through the same shuffle off/on step as Library plays). One request,
    nothing marked skipped, and songs the user queued stay queued (checked
    live, October 2026).
  - Membership must be known first: Spotify accepts an `offset.uri` outside
    the context with a 204 and leaves the player with no track (checked
    live). Albums are checked against the track's album; playlists are
    listed once (`/playlists/{id}/items`, cached 5 minutes, up to 2000
    tracks).
  - Otherwise (a song the user queued, a followed playlist Spotify won't
    list, an artist or no context) it sends `POST /me/player/next` that many
    times (at most 30, 250 ms apart); those songs count as skipped.
  Either way it then checks the track that plays and warns when Spotify
  landed elsewhere.
- `o` and the "Open Spotify app" button open the `spotify:` link through the
  window, which hands it to the OS (the desktop app's protocol handler).
- Compact layout when the pane is under 60 columns or 20 rows (a floating
  player): small art, title/artist, progress, Prev/Play/Next/Like, volume;
  no tab strip or key hints.
- Like / unlike (`h`, chip) uses `PUT`/`DELETE /me/library?uris=…`; whether
  the current track is liked comes from `GET /me/library/contains`, asked
  once per track by the session. Add to playlist (`A`, chip) shows a sheet
  of playlists the user owns or collaborates on (owner id from `GET /me`)
  in place of the tab's content, and posts to `POST /playlists/{id}/items`.
  Both need permissions added after the first release; a sign-in without
  them gets a "Sign in again" row.
- Text fields (Client ID, redirect address, search) are `input` nodes the
  block owns: `lib/field.luau` edits the text; Tern draws it. Search runs
  450 ms after typing stops.
- Playlists: tracks come from `GET /playlists/{id}/items` (50 per page; the
  `/tracks` form is deprecated). Since February 2026 Spotify returns items
  only for playlists the user owns or collaborates on; others answer 403,
  which the block explains, and every opened playlist has a "Play playlist"
  row that plays it as a context regardless.
- Playing: a search track plays in its album (`offset.uri`), a playlist
  track in its playlist (`offset.uri`: positions can drift from the list,
  which skips local and unavailable entries), a Liked Songs track as a list of
  up to 100 loaded tracks from it (Liked Songs has no context URI the API
  accepts), albums, artists and playlists as contexts. While shuffle is on,
  Spotify ignores `offset` and reshuffles `uris`, so a picked track would not
  be the one that starts: the block turns shuffle off, starts playback,
  and turns shuffle back on after 0.6 s (the chosen track keeps playing).
- `save` keeps the tab and the search query. Tokens never go into block
  state.

### Window: `window.luau`

- **Commands** (`tern.command`):

  | Command | Default keys |
  | --- | --- |
  | Open Spotify (focus the open player, else open one beside) | `ctrl+alt+shift+m` |
  | Spotify: Play/Pause | `ctrl+alt+shift+space` |
  | Spotify: Next track | `ctrl+alt+shift+f9` |
  | Spotify: Previous track | `ctrl+alt+shift+f7` |
  | Spotify: Open floating player / dock it (`layout:float(pane, nil, "br")` / `layout:dock`) | none |
  | Spotify: Sign out | none |

  The chords were chosen because Tern's Windows preset leaves them free
  (`ctrl+alt+shift+s/p/n/b` are taken and were left out). A user's
  `keybinds` in `settings.json` override them.
- **Controls** send one request with the access token from kv. With no
  token, or one about to expire, or on a 401, they toast "Open the Spotify
  player to reconnect" and never refresh. Toasts after the request use the
  fresh `cx` the fetch callback receives (`api.send` passes it on).
- **Status segment.** A 1 s window timer reads `now` and calls
  `tern.chrome.refresh()` only when the segment changes; the formatter
  returns the cached segment (4 ms budget). Play or pause icon, muted while
  paused, click runs Open Spotify. Hidden when nothing plays or the record
  is older than 3 minutes. The status line shows only while the status bar
  is on (`status_bar` command).
- **Sign-out** sends the player block the dock's `signout` action (opening a
  player first when none is open); the host signs out at once and every
  block shows the sign-in flow. The window half writes nothing to kv.

## Sign-in

Authorization Code with PKCE; no client secret. Tern's API can't listen for
the redirect, so the redirect address is captured or pasted:

1. The user creates an app in the Spotify Developer Dashboard with redirect
   URI `http://127.0.0.1:8888/callback` and the Web API, and enters its
   Client ID (paste or type; a pasted ID submits itself).
2. The host gets 64 random bytes from the OS CSPRNG through a short process
   (PowerShell's `RandomNumberGenerator` on Windows, `/dev/urandom`
   elsewhere), makes a 64-character verifier and a state, stores them as
   `pending`, and opens the authorize URL with `cx:open`.
3. Spotify redirects to `http://127.0.0.1:8888/callback?code=…&state=…`,
   which doesn't load.
   - **Opened in a Tern browser block** (Tern's default for web links): the
     window half sees that pane's address, sends it to the player block as
     an action (`cx.session:event`), and closes the browser pane. Nothing to
     paste.
   - **Opened in another browser:** the user pastes the address into the
     block; a pasted address with `code=` submits itself.
4. The host checks `state` (a bare code is refused), refuses a sign-in
   older than 15 minutes, exchanges the code, requires a refresh token in
   the answer, stores `auth`, clears `pending`, and every block switches to
   the player.

"Start over", "Open link again", "Copy link" and "Change Client ID" cover
the other cases. Sign-out keeps the Client ID.

Scopes: `user-read-playback-state`, `user-modify-playback-state`,
`user-read-currently-playing`, `playlist-read-private`,
`playlist-read-collaborative`, `user-library-read`, `user-library-modify`,
`playlist-modify-public`, `playlist-modify-private`.

## Data in `tern.kv`

Times are Unix seconds (`os.time()`), comparable across VMs.

| Key | Written by | Value |
| --- | --- | --- |
| `client_id` | host | The Spotify app's Client ID |
| `pending` | host | `{ verifier, state, client_id, created }` during sign-in |
| `auth` | host | `{ access_token, refresh_sealed = { scheme, data }, expires_at, scope }`, or `refresh_token` (plain) instead of `refresh_sealed` where sealing failed |
| `now` | host | `{ uri, title, artist, playing, device, seen }`; absent when nothing plays |

## Errors

| Response | Handling |
| --- | --- |
| 204 on `/me/player` | "Nothing playing" card with Devices / Search / Library; `now` removed |
| 401 | One refresh through the single-flight refresher, then one retry |
| 403 `PREMIUM_REQUIRED` | "Controlling playback needs Spotify Premium." in the dock |
| 404 `NO_ACTIVE_DEVICE` | Message, and the block switches to Devices |
| 403 other | Spotify's message (restriction, e.g. skipping an ad) |
| 429 | Message with the wait; polling resumes after `Retry-After` |
| Network failure | Last state stays; message in the dock; polls every 15 s |

## Limits

- **Remote session hosts are unsupported.** `tern.kv` lives on the machine
  each half runs on. With a window attached to a daemon on another machine,
  the host half (tokens, poller, `now`) runs there: the player block works,
  but this window's status segment stays empty and its commands report
  "not signed in".
- **Token storage.** The refresh token (the long-lived credential) is sealed
  by the OS through a short process (`lib/vault.luau`), because the host half
  can't use `tern.secrets` (window-only):
  - Windows: DPAPI, CurrentUser scope with plugin-specific entropy, through
    PowerShell; the secret goes over stdin and the ciphertext lives in kv.
    Checked live.
  - macOS: the login keychain through `/usr/bin/security` (the secret is an
    argument for the moment that process runs; `security` has no stdin form).
    Linux: libsecret through `secret-tool` (stdin). Both untested; kv keeps
    only a version tag.
  - A seal counts only once the secret reads back unchanged. Anything else
    (no tool, an error, iOS) stores the refresh token plain in kv as before
    and logs a warning once. The host keeps the unsealed token in memory, so
    a process runs at sign-in, on rotation, at startup migration, and on the
    first refresh after a restart.
  - Plain tokens from older versions are sealed at startup (`auth.migrate`),
    verified before the plain copy is replaced. "Same sign-in" checks compare
    the token itself, so a migration can't discard a refresh in flight.
  - The access token stays plain in kv: it expires within the hour and the
    window half reads it for its controls.
  - Protects the file at rest (other accounts, backups, synced folders); not
    against programs running as the same user. Sign out (and changing the
    Client ID) deletes the keychain/libsecret entry too. For comparison,
    NaC-L's plugin keeps its tokens in a plain `token.json`; rico-vz's keeps
    none (it drives the desktop app).
- **Spotify app limits** (February 2026 development-mode rules): the app's
  owner needs Spotify Premium, and an app allows 5 users, added in the
  dashboard. The redirect URI must be the loopback IP literal; `localhost`
  is rejected. Playlist contents are listed only for playlists the user owns
  or collaborates on.
- **Physical key binds are untested by automation:** the harness's synthetic
  chords don't reach the window keymap. The palette shows the binds.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for the workflow, checks and the mock server.
