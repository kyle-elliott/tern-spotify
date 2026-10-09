# Developing the Spotify plugin

How the plugin is built is in [ARCHITECTURE.md](ARCHITECTURE.md). This page is the workflow.

## Setup

- [Tern](https://stencil.so/tern) with its CLI on `PATH` (`tern`).
- The Luau CLI and luau-lsp in `.tools/` (ignored by git): `luau` from
  [luau-lang/luau releases](https://github.com/luau-lang/luau/releases) and `luau-lsp` from
  [JohnnyMorganz/luau-lsp releases](https://github.com/JohnnyMorganz/luau-lsp/releases).
- Python 3 for the test runner and the mock server.

```sh
tern plugin types .     # writes tern.d.luau, the declarations of the Tern version you run
tern plugin link .      # Tern reloads the plugin on every save
tern plugin list        # load status and problems
```

`.vscode/settings.json` points luau-lsp at `tern.d.luau`.

A linked plugin reloads as soon as a file is saved, and a reload that fails to load ends
every open player pane. When changing several files at once, edit a copy, check it, and
copy it back.

## Checks

```sh
python tests/run.py
.tools/luau-lsp analyze --platform standard --definitions=@tern=tern.d.luau host.luau window.luau lib/*.luau
```

- `tests/pure.luau`: modules that don't touch `tern` (SHA-256 and PKCE vectors, URL
  helpers, text fields, Spotify JSON readers). Runs directly with the Luau CLI.
- `tests/with_tern_*.luau`: sign-in, the single-flight refresh, the API wrapper, the
  session's poller and up-next, and the sealed refresh token, against a scripted fake
  `tern` (`tests/fake_tern.luau`). The Luau CLI gives each required module its own
  read-only globals, so `run.py` bundles the modules and the test into one chunk where
  `tern` and `require` are locals.
- `tests/check.luau`: the shared `eq`/`done` assertions.

## Running against a mock Spotify

`tests/mock_spotify.py` stands in for the Web API and the accounts service, so the whole
plugin runs in a real Tern window without a Spotify account:

```sh
python tests/mock_spotify.py 47900
```

Start a separate Tern for it, so the test stays away from your own sessions and sign-in:

```sh
TERN_CONFIG_DIR=/tmp/tern-test/config            # its own plugins and plugin data
TERN_DAEMON_SOCKET=/tmp/tern-test/none.sock      # no daemon: the window runs its panes
TERN_SPOTIFY_API=http://127.0.0.1:47900/v1
TERN_SPOTIFY_ACCOUNTS=http://127.0.0.1:47900
tern plugin link .                               # with TERN_CONFIG_DIR set
tern --control 47812 .                           # a window `tern ctl --control 47812` drives
```

Any 32-hex Client ID signs in. The mock's hooks drive the error paths:

| Request | Effect |
| --- | --- |
| `GET /_log` | Every request so far |
| `POST /_expire` | The current access token answers 401 |
| `POST /_rate?n=1` | The next n API requests answer 429 |
| `POST /_premium?on=0` | Playback commands answer 403 `PREMIUM_REQUIRED` |
| `POST /_nodevice` | Nothing plays and no device is active |

Odd-numbered mock playlists behave like followed playlists (their items answer 403).
