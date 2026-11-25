# FM.video for Omarchy

Radio with music videos, on your desktop. This plugin puts [FM.video](https://fm.video) in the Omarchy bar.

![The FM.video panel open under the bar, with the video window beside it](preview.png)

## What it does

- **The song in your bar.** The song a station is playing now, with play, pause and next.
- **A panel of stations.** Click the song for over 200 stations, grouped by country: yours first, then your neighbours, then the countries with the most stations. Type to search by name, style, city or country. Click the heart on a station to keep it at the top.
- **A small video window.** The station's music videos play in a little window that floats on top of your other windows and follows you to every workspace.
- **Karaoke in the bar.** When a song has timed lyrics, the bar shows the line being sung, in time with the video, and the words light up as they are sung.

## What you need

- Omarchy 4.5 or later (the Quattro shell, with Hyprland's Lua config).
- A Chromium kind of browser. Omarchy ships Chromium. Chrome, Brave, Edge, Vivaldi and Helium work too if one of them is your default browser.
- `curl` and `jq`. Omarchy ships both.

## Install

```bash
omarchy plugin add https://github.com/0800tim/omarchy-fmvideo.git --enable
```

The widget goes in the right hand end of the bar. To move it:

```bash
omarchy bar move video.fm.radio --section left
```

## Remove

```bash
omarchy plugin remove video.fm.radio
```

That removes the plugin. It leaves one folder behind, `~/.local/state/fmvideo-omarchy`, which holds your last station, where you put the video window, and the browser profile the window uses. Delete it if you want nothing left:

```bash
rm -rf ~/.local/state/fmvideo-omarchy
```

The plugin never edits your Hyprland config or any other file of yours.

## Using it

| Where | Click | What happens |
|---|---|---|
| The icon | Left | Starts the video. Once it is open, plays and pauses. |
| The song | Left | Opens the panel. |
| The arrow | Left | Next song. |
| Anywhere | Right | Opens the panel. |
| Anywhere | Middle | Shows or hides the video window. The music carries on. |

In the panel:

- **Show video** shows or hides the video window. Hidden, it keeps playing, so you can have the music without the picture. While you listen live it reads **Show visualiser**.
- **Stop**, the square button, closes the window and stops the music.
- **Listen live** plays the station's own broadcast in place of its music videos, for stations that have one.
- Click a song under **Just played** to watch its video.
- **Install the FM.video app**, at the bottom, adds the full FM.video site to your app launcher as an app of its own and opens it on the station you are on. The mini player stops, so the two do not play at once. After that the button reads **Open the FM.video app**. It uses Omarchy's own web app installer. To take it out again: `omarchy-webapp-remove FM.video`.
- **Lyrics in the bar** shows the line being sung in place of the song name.
- **Lyrics on the video** shows the line over the video as well.
- **Small, Medium, Large, Full screen** set the size of the video window.
- Pick a station to switch to it. Type to search, use the up and down arrows, and press Enter.
- Point at a station and click its heart to make it a favourite. Favourites are listed first. Click the heart again to take it off.

To move the video window, drag it. To resize it, hold Super and drag with the right button. It opens in the same place next time.

With the video window in front, its own keys work too: Space plays and pauses, N is next, P is previous, S picks a station, L turns lyrics on the video on and off, and M mutes.

## Settings

Add these to the plugin's entry in `~/.config/omarchy/shell.json`, or use `omarchy bar set`:

| Setting | Default | What it does |
|---|---|---|
| `maxLength` | `56` | The longest text the bar will show, in letters. |
| `showSongWhenClosed` | `true` | Show what the station is playing while the video window is closed. Set to `false` for just the icon. |
| `hideExplicitLyrics` | `false` | Keep the lyrics of songs marked explicit out of the bar. |

```bash
omarchy bar set video.fm.radio maxLength 40
```

## Keyboard shortcuts

The plugin answers these commands, so you can bind keys to them in your Hyprland config:

```bash
omarchy-shell video.fm.radio toggleWindow     # show or hide
omarchy-shell video.fm.radio stop
omarchy-shell video.fm.radio live true
omarchy-shell video.fm.radio playPause
omarchy-shell video.fm.radio next
omarchy-shell video.fm.radio previous
omarchy-shell video.fm.radio station george
omarchy-shell video.fm.radio size medium     # small, medium, large or full
omarchy-shell video.fm.radio barLyrics true
omarchy-shell video.fm.radio videoLyrics false
omarchy-shell video.fm.radio status
```

## How it works

There are three pieces.

1. **The video player** is a web page, [fm.video/mini](https://fm.video/mini). The plugin opens it in a browser window with no tabs or address bar, and asks Hyprland to float it and pin it. It is a web page on purpose: YouTube only allows its videos to play in its own embedded player, which needs a browser. The plugin never downloads or extracts video or audio.
2. **The data** comes from the FM.video API: the list of stations, what each one has played, and lyrics.
3. **The plugin** is the part in this repository. `Service.qml` runs once in the background and holds everything the bar needs. `BarWidget.qml` is what you see in the bar, with its panel. `scripts/fmv-window` opens, sizes and closes the video window. `Model.js` is the logic that needs no desktop, and `tests/model.test.mjs` tests it.

The plugin learns what the window is playing from the window's title, and reads the position in the song from the desktop's media controls (MPRIS) to keep the lyric line in time. Commands such as next go to the page as key presses. A change of station or song goes through the FM.video server, to a code made up on your machine that only your window listens on.

Hiding the window moves it to a Hyprland workspace that is never shown (`special:fmvideo`). It is still open there, which is why it keeps playing.

The video window has a browser profile of its own, kept apart from your normal browsing.

Dragging works through a small Lua script, `scripts/fmv-drag.lua`, that the plugin loads into Hyprland while the video window is open. It watches the left mouse button and moves the window only when the press lands on the FM.video window. Clicks still go through to whatever is under the pointer, and no other window is affected. It stays loaded until the next Hyprland reload, and does nothing while no FM.video window is open. To switch it off by hand: `hyprctl eval 'fmvideo_drag.unload()'`.

Nothing times single words, so the lit part of a lyric line is worked out from how far the song is between this line and the next.

### What it sends over the network

- Requests to `api.fm.video` for stations, plays and lyrics, and one request to learn your country so your stations come first. The bar asks every 40 seconds while the video or the panel is open, and every two minutes otherwise. When the plugin is turned off it asks for nothing.
- Station logos from `fm.video`.
- Everything the video window loads, which is the FM.video page and YouTube's player.

The API key in `Constants.js` is public on purpose. It can only read what the website already shows, and the server limits how often anyone can use it. It is for this plugin only, so please do not use it for anything else.

No code is ever loaded from the network. Only data.

## What is still rough

- **Changing station happens inside the window**, by a command sent through the FM.video server. If that fails, the plugin reopens the window in the same place, which takes about a second.
- **The lyric line can run ahead or behind** on some songs, when the video is a different cut from the one the lyrics were timed to. Many songs have no timed lyrics at all, and then the bar shows the song name.
- **Captions.** YouTube's own captions sometimes show over the video.
- **An upright bar** (on the left or right edge) shows only the icon. Click it for the panel.
- **Only tested on Hyprland 0.56 with Omarchy's Lua config.** Older Hyprland configs will not float or pin the window.
- **The video window's browser profile takes disk space**, a few hundred megabytes after some use, in `~/.local/state/fmvideo-omarchy/browser`.
- **Firefox is not supported** for the video window. If your default browser is not a Chromium kind, the plugin uses Chromium.

## Working on it

```bash
node tests/model.test.mjs       # test the logic
omarchy plugin validate .       # check the manifest
tools/dev-sync                  # copy this checkout into ~/.config/omarchy/plugins
omarchy restart shell           # load the new code
```

The shell notices changed files by itself, but it does not always let go of the old code, so restart it to be sure.

## Licence

MIT. See [LICENSE](LICENSE).

FM.video is not connected with YouTube or with any of the radio stations. Videos play through YouTube's own player.
