# Spotify for Tern

Play and control Spotify without leaving Tern. A player pane shows the current track with its
album art, and lets you browse your queue, library and search results and pick a device.
The current track can also sit in Tern's status line, and palette commands control playback
from anywhere.

Music plays on your own Spotify device (the desktop app, your phone, a speaker): this plugin
is a remote control for it.

## What you need

- **Spotify Premium.** Spotify only lets Premium accounts control playback.
- **A Spotify device** with Spotify open: the desktop app, phone app, or a speaker.
- **A free Spotify developer app**, made once in two minutes (below). Spotify asks every
  third-party player for one.

## Install

```sh
tern plugin install github.com/kyle-elliott/tern-spotify
```

`tern plugin list` should show **spotify** as ready.

## Sign in

1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and choose
   **Create app**. Any name and description will do.
2. Under **Redirect URIs** add exactly `http://127.0.0.1:8888/callback`, tick **Web API**,
   and save.
3. Copy the app's **Client ID** (in its Settings).
4. In Tern, open the palette and run **Open Spotify**. Paste the Client ID into the pane.
5. Approve in the Spotify page that opens.

If the page opened in a Tern browser pane, you're done: the pane closes and the player
appears. If it opened in your regular browser, you'll end up on a page that doesn't load.
That's expected: copy its address from the address bar and paste it into the Spotify pane.

## Using the player

The player has five tabs: **Now**, **Queue**, **Library**, **Search** and **Devices**.
Everything works with the mouse; hover a button to see its key.

### On the Now tab

| Key | Does |
| --- | --- |
| `space` | Play / pause |
| `n` / `p` | Next / previous track |
| `←` / `→` | Back / forward 10 seconds |
| `+` / `-` | Volume up / down by 5% |
| `m` | Mute / unmute |
| `s` | Shuffle on / off |
| `r` | Repeat: off, all, one |
| `h` | Save to / remove from Liked Songs |
| `A` | Add the song to one of your playlists |
| `o` | Open the Spotify app |

Click anywhere on the progress bar to jump there, and on the volume bar to set the volume.

### In the lists

| Key | Does |
| --- | --- |
| `1` – `5` | Switch tab |
| `↑` / `↓` | Move the selection |
| `enter` (or double-click) | Play it (in **Queue**: jump ahead to it; in **Devices**: play there) |
| `a` | Add the song to the queue |
| `A` | Add the song to one of your playlists |
| `/` | Search |
| `esc` | Back out of a playlist, or leave the search field |
| `f5` | Reload the tab |

### From anywhere in Tern

Open the palette and type **Spotify**:

| Command | Default keys |
| --- | --- |
| Open Spotify | `ctrl+alt+shift+m` |
| Spotify: Open floating player / dock it | |
| Spotify: Play/Pause | `ctrl+alt+shift+space` |
| Spotify: Next track | `ctrl+alt+shift+f9` |
| Spotify: Previous track | `ctrl+alt+shift+f7` |
| Spotify: Sign out | |

To change a key, add it to `keybinds` in Tern's `settings.json` with the action
`plugin.spotify.open`, `plugin.spotify.play_pause`, `plugin.spotify.next` or
`plugin.spotify.previous`.

### Floating player

**Spotify: Open floating player / dock it** puts the player in a small window in the
bottom-right corner, over your work. Run it again to put it back into a pane. A small player
shows a compact view: the song, the progress bar, the main buttons and the volume.

### Status line

Turn on Tern's status bar (the `status_bar` command) to see the current song at the bottom of
the window. Click it to open the player.

## Good to know

- **Jumping ahead in the queue.** If the song is part of the album or playlist that's
  playing, the player starts it right there: nothing counts as skipped, and songs you added
  to the queue stay. Otherwise (a song you queued yourself, or a playlist you follow but
  don't own) it skips ahead one song at a time, so those songs count as skipped.
- **Playlists you follow.** Spotify only shows the songs of playlists you own or collaborate
  on. You can still play the others with **Play playlist**.
- **"Sign in again".** If you signed in with an older version, Like and Add to playlist need
  one more permission. The player shows a **Sign in again** button for it.
- **Who can use your developer app.** Spotify allows the app's owner and up to 5 people you
  add in the dashboard.
- **Remote Tern sessions.** If your Tern sessions run on another machine, use the player
  pane. The status line and the palette commands only work for sessions on this machine.

## Troubleshooting

| You see | Try |
| --- | --- |
| "No active Spotify device" | Open Spotify on a device, or pick one in **Devices** (press `o` to open the app) |
| "Controlling playback needs Spotify Premium" | The account you signed in with isn't Premium |
| The sign-in page says the redirect URI is invalid | The Redirect URI in your developer app must be exactly `http://127.0.0.1:8888/callback` |
| "Spotify is rate limiting requests" | Wait a few seconds; the player retries by itself |
| A default key does nothing | Another key binding uses it; set your own in `settings.json` |

## Privacy

Your Spotify sign-in is stored encrypted with your computer account's key store: Windows' data
protection, the macOS keychain, or the Linux secret service. Where none is available it's kept
in Tern's plugin data folder without encryption. The plugin only talks to Spotify.
**Spotify: Sign out** (or the **Sign out** button) removes the sign-in from your computer.
To revoke the plugin's access entirely, remove your developer app's access in your Spotify
account settings.

## License

[MIT](LICENSE) © Kyle Elliott. Not affiliated with or endorsed by Spotify.

---

Working on the plugin itself? See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
