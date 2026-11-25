import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import "Constants.js" as C
import "Model.js" as Model

// The one background part of the plugin. It knows the stations, what is
// playing, whether the video window is open and which lyric line is due.
// Every bar widget (one for each screen) reads from here, so there is only
// ever one set of requests to the FM.video API.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ---- Remembered between sessions (state.json).
  property string station: C.defaultStation   // a slug, an id or a mix such as "all-nz"
  property bool barLyrics: true               // show the lyric line in the bar
  property bool videoLyrics: false            // show the lyric line over the video
  property string lyricStyle: "plain"         // the look of the lyric line on the video
  property var geometry: null                 // { x, y, w, h } of the video window
  property var favourites: []                 // station keys, in the order they were added
  // A channel, a playlist or the listener's favourites, played in place of
  // a station. listKind is "" for radio.
  property string listKind: ""
  property string listValue: ""
  property string listName: ""
  readonly property bool inList: listKind !== ""
  readonly property string feedOwner: inList ? listKind + ":" + listValue : station
  property var channels: []
  property var playlists: []
  property bool listsLoaded: false
  property bool live: false                   // play the station's own broadcast, not the videos
  property bool visualiser: false             // draw the visualiser while live (heavy on the processor)
  // Commands reach an open window through the FM.video server, on a code
  // only this install knows. remoteWindow is the window that was opened
  // with the code in its address, and so is listening on it.
  property string remoteCode: ""
  property string remoteWindow: ""
  property string windowAddress: ""
  property double remoteReadyAt: 0
  readonly property bool remoteUsable: remoteCode !== "" && windowAddress !== "" && windowAddress === remoteWindow
  property string tabAsked: ""
  property int tabAskedSerial: 0
  property bool stateLoaded: false

  // ---- From the API.
  property var stations: []
  property string country: ""
  property var feed: []          // the station's plays, newest first
  property string feedStation: ""
  property string lastError: ""
  property double pausedUntil: 0 // set when the API says we are asking too often
  property double lastFeedAt: 0

  // ---- Who is looking. Polling slows or stops when nobody is.
  property int widgets: 0
  property int panels: 0

  // ---- The video window.
  readonly property var toplevel: {
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var id = String(list[i].appId || "")
      if (/^[A-Za-z-]+-fm\.video__mini-/.test(id)) return list[i]
    }
    return null
  }
  readonly property bool windowOpen: toplevel !== null
  readonly property string windowTitle: toplevel ? String(toplevel.title || "") : ""
  readonly property var titleInfo: windowOpen ? Model.parseTitle(windowTitle) : null
  // What the window is doing now, which wins over what was asked for.
  // While a window is still loading its title says nothing yet, so go by
  // what was asked for. Otherwise the panel would flip to its video
  // layout and back on every station change while listening live.
  readonly property bool windowLive: titleInfo && titleInfo.song !== ""
    ? titleInfo.live === true : (windowOpen && live && canLive)
  readonly property bool canLive: !inList && stationObject !== null && String(stationObject.streamUrl || "") !== ""
  property int windowPid: 0
  property bool opening: false
  property bool windowFullscreen: false
  // Out of sight on a workspace that is never shown, and still playing.
  property bool windowHidden: false
  readonly property bool windowShown: windowOpen && !windowHidden
  readonly property string windowSize: {
    if (!windowOpen) return ""
    if (windowFullscreen) return "full"
    var w = geometry ? geometry.w : 0
    return w === 480 ? "small" : w === 720 ? "medium" : w === 1280 ? "large" : ""
  }

  // The browser publishes one media player for each browser process, named
  // after its process id. The window has a browser profile of its own, so
  // its process id picks out our player among any others.
  readonly property var player: {
    if (!windowOpen || windowPid <= 0) return null
    var list = Mpris.players ? Mpris.players.values : []
    var suffix = ".instance" + windowPid
    for (var i = 0; i < list.length; i++) {
      var name = String(list[i].dbusName || "")
      if (name.length >= suffix.length && name.slice(-suffix.length) === suffix) return list[i]
    }
    return null
  }
  readonly property bool playing: player ? player.isPlaying : false

  // ---- What to show.
  readonly property string stationName: {
    if (titleInfo && titleInfo.station) return titleInfo.station
    if (inList) return listName
    return Model.stationLabel(stations, station)
  }
  readonly property var stationObject: inList ? null : Model.findStation(stations, station)
  readonly property var livePlay: !inList && feed.length > 0 && feedStation === station ? feed[0] : null
  readonly property string song: windowOpen
    ? (titleInfo ? titleInfo.song : "")
    : (livePlay ? String(livePlay.title || "") : "")
  readonly property string artist: windowOpen
    ? (titleInfo ? titleInfo.artist : "")
    : (livePlay ? String(livePlay.artist || "") : "")
  readonly property var currentPlay: windowOpen ? (feedStation === feedOwner ? Model.findPlay(feed, song, artist) : null) : livePlay
  readonly property var recent: feed.slice(0, 5)

  // ---- Lyrics.
  property var lyricLines: []
  property real lyricOffset: 0
  property string lyricsFor: ""    // the video the lines belong to
  property string lyricLine: ""
  property real lyricProgress: 0   // how much of the line has been sung, 0 to 1
  // Lyrics are timed to the video, so there are none for live radio.
  readonly property bool wantLyrics: barLyrics && windowOpen && widgets > 0 && !windowLive

  // ------------------------------------------------------------ requests

  Component {
    id: requestComponent

    Process {
      id: request
      property var done: null

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          // curl adds the status code on a last line of its own.
          var cut = text.lastIndexOf("\n")
          var status = parseInt(cut >= 0 ? text.slice(cut + 1) : "0", 10) || 0
          var data = null
          var body = cut >= 0 ? text.slice(0, cut) : ""
          if (status >= 200 && status < 300) {
            try { data = JSON.parse(body) } catch (e) { status = 0 }
          }
          if (request.done) request.done(status, data, body.slice(0, 500))
          request.destroy(500)
        }
      }
    }
  }

  // ---- This install's own token. The key in Constants.js says "this is
  // the plugin"; the token says which copy, so FM.video can count installs
  // and stop one that misbehaves without touching the rest. It is asked for
  // once and kept in a file only this user can read.
  property string installToken: ""
  property bool tokenLoaded: false
  property bool installRefused: false
  property bool registering: false
  property double lastRegisterAt: 0
  readonly property string tokenPath: stateDir + "/install-token"

  function headers() {
    var list = ["-H", "X-FMV-Key: " + C.apiKey]
    if (installToken !== "") list = list.concat(["-H", "X-FMV-Install: " + installToken])
    return list
  }

  // A 403 that talks about the install means this copy's token is unknown
  // or has been turned off. Stop asking for an hour and register again, at
  // most once a day. The old token is kept until a new one arrives. Any
  // other 403 (a server being restarted, a firewall having a moment) is
  // only a reason to wait a minute: it says nothing about this install.
  function refused(body) {
    if (!/install/i.test(String(body || ""))) {
      pausedUntil = Math.max(pausedUntil, Date.now() + 60000)
      return
    }
    pausedUntil = Date.now() + 3600000
    installRefused = true
    lastError = "FM.video is not available on this install"
    registerInstall()
  }

  function registerInstall() {
    if (!stateLoaded || !tokenLoaded || (installToken !== "" && !installRefused)) return
    if (Date.now() - lastRegisterAt < 86400000) return
    lastRegisterAt = Date.now()
    saveState()
    registering = true
    var request = requestComponent.createObject(root, {
      done: function(status, data) {
        root.registering = false
        if (status === 200 && data && /^fmi_[A-Za-z0-9_-]{8,200}$/.test(String(data.token || ""))) {
          root.installToken = String(data.token)
          root.installRefused = false
          root.pausedUntil = 0
          if (root.lastError === "FM.video is not available on this install") root.lastError = ""
          saveToken.command = ["sh", "-c", "umask 077; printf %s \"$1\" > \"$2\"", "sh", root.installToken, root.tokenPath]
          saveToken.running = true
        } else if (status === 429) {
          // Too many registrations from this address today: try in an hour.
          root.lastRegisterAt = Date.now() - 86400000 + 3600000
          root.saveState()
        }
      }
    })
    var version = manifest && manifest.version ? String(manifest.version) : "0"
    request.command = ["curl", "-sS", "--max-time", "10", "-A", C.userAgent,
      "-H", "X-FMV-Key: " + C.apiKey, "-H", "Content-Type: application/json", "-X", "POST",
      "--data-raw", JSON.stringify({ app: "omarchy", version: version }), "-w", "\n%{http_code}",
      C.apiBase + "/api/plugin/register"]
    request.running = true
  }

  Process { id: saveToken }

  Timer {
    interval: 3600000
    repeat: true
    running: root.stateLoaded && root.tokenLoaded && (root.installToken === "" || root.installRefused)
    triggeredOnStart: true
    onTriggered: root.registerInstall()
  }

  // On a first run the token is still on its way. Requests wait for it,
  // for a few seconds at most, so they are not refused for lacking one.
  function waitingForToken(tries) {
    return (installToken === "" || installRefused) && (!tokenLoaded || registering) && (tries || 0) < 8
  }

  function api(path, done, tries) {
    if (waitingForToken(tries)) { delay(1500, function() { root.api(path, done, (tries || 0) + 1) }); return }
    if (Date.now() < pausedUntil) { done(429, null); return }
    var request = requestComponent.createObject(root, {
      done: function(status, data, body) {
        if (status === 429) root.pausedUntil = Date.now() + 60000
        if (status === 403) root.refused(body)
        done(status, data)
      }
    })
    request.command = ["curl", "-sS", "--max-time", "10", "-A", C.userAgent].concat(headers(),
      ["-w", "\n%{http_code}", C.apiBase + path])
    request.running = true
  }

  function apiPost(path, body, done, tries) {
    if (waitingForToken(tries)) { delay(1500, function() { root.apiPost(path, body, done, (tries || 0) + 1) }); return }
    if (Date.now() < pausedUntil) { done(429, null); return }
    var request = requestComponent.createObject(root, {
      done: function(status, data, body) {
        if (status === 429) root.pausedUntil = Date.now() + 30000
        if (status === 403) root.refused(body)
        done(status, data)
      }
    })
    request.command = ["curl", "-sS", "--max-time", "10", "-A", C.userAgent].concat(headers(),
      ["-H", "Content-Type: application/json", "-X", "POST", "--data-raw", JSON.stringify(body), "-w", "\n%{http_code}", C.apiBase + path])
    request.running = true
  }

  function loadStations() {
    api("/api/stations", function(status, data) {
      if (status === 200 && data && data.length) { root.stations = data; root.lastError = "" }
      else { root.lastError = "Could not reach FM.video"; stationsRetry.restart() }
    })
    if (country === "") api("/api/geo", function(status, data) {
      if (status === 200 && data && data.country) root.country = String(data.country)
    })
  }

  function feedKey() {
    var s = stationObject
    return s ? s.id : station
  }

  function loadFeed() {
    if (!stateLoaded) return
    if (inList) { loadListTracks(); return }
    var wanted = station
    lastFeedAt = Date.now()
    api("/api/feed/" + encodeURIComponent(feedKey()) + "/20", function(status, data) {
      if (wanted !== root.station || root.inList) return
      if (status === 200 && data) { root.feed = data; root.feedStation = wanted; root.lastError = "" }
      else if (status !== 429) root.lastError = "Could not reach FM.video"
    })
  }

  // The songs in the channel or playlist being played, so the song on now
  // can be found in it for its lyrics. Asked for once, not on a timer.
  function loadListTracks() {
    var owner = feedOwner
    if (feedStation === owner) return
    lastFeedAt = Date.now()
    var path = listKind === "channel" ? "/api/channels/" + encodeURIComponent(listValue) + "/feed?count=50"
      : listKind === "playlist" ? "/api/playlists/pub/" + encodeURIComponent(listValue) : ""
    if (path === "") { feed = []; feedStation = owner; return }
    var kind = listKind
    api(path, function(status, data) {
      if (owner !== root.feedOwner) return
      if (status === 200 && data) { root.feed = Model.listTracks(kind, data); root.feedStation = owner }
    })
  }

  // What the other tabs of the picker list. Asked for the first time a
  // panel opens.
  function loadLists() {
    if (listsLoaded) return
    listsLoaded = true
    api("/api/channels", function(status, data) {
      if (status === 200 && data && data.channels) root.channels = data.channels
      else root.listsLoaded = false
    })
    api("/api/playlists/discover?sort=trending&limit=40", function(status, data) {
      if (status === 200 && data && data.items) root.playlists = data.items
    })
  }

  // ------------------------------------------------------------ lyrics

  function clearLyrics() {
    lyricLines = []
    lyricOffset = 0
    lyricKey = ""
    lyricLine = ""
    lyricProgress = 0
  }

  property string lyricKey: ""

  // People can nudge a song's timing on the site, and the fix is shared,
  // so look again now and then while the song plays.
  function loadLyricOffset() {
    var video = lyricsFor
    if (video === "" || lyricKey === "") return
    api("/api/lyrics/video/" + encodeURIComponent(video) + "/offset?k=" + encodeURIComponent(lyricKey),
      function(status, data) {
        if (root.lyricsFor !== video) return
        if (status === 200 && data) root.lyricOffset = typeof data.offset === "number" ? data.offset : 0
      })
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.lyricLines.length > 0 && root.lyricKey !== "" && root.playing
    onTriggered: root.loadLyricOffset()
  }

  // The window says which video is on, in its title. That works for every
  // source. Matching the song against the list of plays is the fallback.
  readonly property string windowVideo: windowOpen ? Model.titleVideo(windowTitle) : ""
  onWindowVideoChanged: {
    // Give the desktop a moment to report the new video's length.
    var video = windowVideo
    delay(1500, function() { if (root.windowVideo === video) root.loadLyrics() })
  }

  function loadLyrics() {
    var play = currentPlay
    var video = windowVideo !== "" ? windowVideo : play && play.youTubeVideoId ? String(play.youTubeVideoId) : ""
    if (!wantLyrics || video === "") { lyricsFor = ""; clearLyrics(); return }
    if (video === lyricsFor) return
    lyricsFor = video
    clearLyrics()

    // One song has several recordings, each timed apart. Asking by video,
    // with the video's real length, gets the lines timed for this cut.
    var seconds = player && player.length > 0 ? Math.round(player.length) : 0
    var path = "/api/lyrics/video/" + encodeURIComponent(video) + "?"
    if (play && play.songId) path += "song=" + encodeURIComponent(play.songId) + "&"
    if (seconds >= 20) path += "d=" + seconds

    api(path, function(status, data) {
      if (root.lyricsFor !== video) return
      if (status === 404 && play && play.songId) {
        root.api("/api/lyrics/" + encodeURIComponent(play.songId), function(status2, data2) {
          if (root.lyricsFor !== video) return
          if (status2 === 200 && data2 && data2.synced) root.lyricLines = Model.parseLrc(data2.synced)
        })
        return
      }
      if (status !== 200 || !data || !data.synced) return
      root.lyricLines = Model.parseLrc(data.synced)
      root.lyricKey = data.lrcKey ? String(data.lrcKey) : ""
      root.loadLyricOffset()
    })
  }

  onCurrentPlayChanged: {
    if (windowVideo === "") loadLyrics()
    // The window has moved on to a song the list does not have yet.
    if (windowOpen && song !== "" && !currentPlay && Date.now() - lastFeedAt > 8000) loadFeed()
  }
  onWantLyricsChanged: loadLyrics()

  Timer {
    interval: 200
    repeat: true
    running: root.lyricLines.length > 0 && root.player !== null && root.wantLyrics
    onTriggered: {
      // The player only reports a new position when asked to.
      root.player.positionChanged()
      // The window's own figure wins: it includes this person's nudge.
      var shown = Model.titleLyricOffset(root.windowTitle)
      var now = root.player.position + (shown !== null ? shown : root.lyricOffset)
      var at = Model.activeLine(root.lyricLines, now)
      var line = at >= 0 ? root.lyricLines[at].text : ""
      if (line !== root.lyricLine) { root.lyricProgress = 0; root.lyricLine = line }
      root.lyricProgress = Model.lineProgress(root.lyricLines, at, now)
    }
    onRunningChanged: if (!running) root.lyricLine = ""
  }

  // ------------------------------------------------------------ the window

  readonly property string helper: Qt.resolvedUrl("scripts/fmv-window").toString().replace("file://", "")

  Component {
    id: helperComponent

    Process {
      id: run
      property var done: null

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var data = null
          try { data = JSON.parse(text) } catch (e) {}
          if (run.done) run.done(data)
          run.destroy(500)
        }
      }
    }
  }

  function windowCommand(args, done) {
    var run = helperComponent.createObject(root, { done: done || null })
    run.command = [helper].concat(args)
    run.running = true
  }

  function takeState(data) {
    if (!data) return
    if (data.open && data.pid) windowPid = data.pid
    windowAddress = data.open && data.address ? String(data.address) : ""
    windowFullscreen = data.open === true && data.fullscreen === true
    windowHidden = data.open === true && data.hidden === true
    // A full screen window is not a place to come back to.
    if (data.w > 0 && data.h > 0 && data.fullscreen !== true && data.hidden !== true) {
      var g = { x: data.x, y: data.y, w: data.w, h: data.h }
      if (!geometry || geometry.x !== g.x || geometry.y !== g.y || geometry.w !== g.w || geometry.h !== g.h) {
        geometry = g
        saveState()
      }
    }
  }

  function address(video) {
    return Model.miniHref(C.miniUrl, station, {
      lyrics: videoLyrics, style: lyricStyle, live: live && canLive, video: video || "", remote: remoteCode,
      list: inList ? { kind: listKind, value: listValue } : null
    })
  }

  // Play one video now, from the Just played list.
  function playVideo(video) {
    video = String(video || "")
    if (!/^[A-Za-z0-9_-]{6,20}$/.test(video)) return
    if (live) { live = false; saveState() }
    var url = Model.miniHref(C.miniUrl, station, {
      lyrics: videoLyrics, style: lyricStyle, video: video, remote: remoteCode,
      list: inList ? { kind: listKind, value: listValue } : null
    })
    var done = function(data) { root.opening = false; root.takeState(data); root.noteRemote(data) }
    if (windowOpen) {
      remote({ cmd: "video", value: video }, function(ok) {
        if (!ok) root.windowCommand(["switch", url], done)
      })
    } else {
      opening = true
      var g = geometry
      var args = ["open", url]
      if (g) args = args.concat([String(g.x), String(g.y), String(g.w), String(g.h)])
      windowCommand(args, done)
    }
  }

  // Listen to the station's own broadcast, or go back to the videos. The
  // page switches on its V key, and its title says which it is doing.
  function setLive(on) {
    on = on === true && canLive
    if (live !== on) { live = on; saveState() }
    if (windowOpen && windowLive !== on) pressKey("V")
    else if (!windowOpen && on) openWindow()
  }

  function setVisualiser(on) {
    if (visualiser === on) return
    visualiser = on
    saveState()
    if (windowOpen && windowLive) pressKey("Z")
  }

  // Someone switched inside the window: remember it for next time.
  onWindowLiveChanged: {
    if (windowOpen && titleInfo && titleInfo.song !== "" && live !== windowLive) { live = windowLive; saveState() }
  }

  function openWindow() {
    if (windowOpen || opening) return
    opening = true
    var g = geometry
    var args = ["open", address()]
    if (g) args = args.concat([String(g.x), String(g.y), String(g.w), String(g.h)])
    windowCommand(args, function(data) { root.opening = false; root.takeState(data); root.noteRemote(data) })
  }

  // The window just opened carries the code in its address. The page joins
  // its channel a moment after it loads, so hold commands back until then.
  function noteRemote(data) {
    if (!data || !data.open || !data.address || remoteCode === "") return
    remoteWindow = String(data.address)
    remoteReadyAt = Date.now() + 3000
    saveState()
  }

  // Send a command to the open window. done(true) means the server passed
  // it on, which is not proof the page acted, so callers check the title.
  function remote(command, done) {
    if (!remoteUsable) { done(false); return }
    var wait = Math.max(0, remoteReadyAt - Date.now())
    var send = function() {
      root.apiPost("/api/mini/remote/" + encodeURIComponent(root.remoteCode), command, function(status) {
        done(status === 200)
      })
    }
    if (wait > 0) delay(wait, send)
    else send()
  }

  Component {
    id: delayComponent
    Timer {
      property var then: null
      running: true
      onTriggered: { if (then) then(); destroy() }
    }
  }
  function delay(ms, then) {
    delayComponent.createObject(root, { interval: ms, then: then })
  }

  function closeWindow() {
    if (!windowOpen) return
    windowCommand(["close"], function(data) { root.takeState(data) })
  }

  // "small", "medium", "large" or "full".
  function setWindowSize(name) {
    if (!windowShown) return
    var sizes = { small: [480, 270], medium: [720, 405], large: [1280, 720] }
    var done = function(data) { root.takeState(data) }
    if (name === "full") { if (!windowFullscreen) windowCommand(["fullscreen"], done) }
    else if (sizes[name]) windowCommand(["size", String(sizes[name][0]), String(sizes[name][1])], done)
  }

  // Hiding keeps the music going. closeWindow() is what stops it.
  function hideWindow() {
    if (windowShown) windowCommand(["hide"], function(data) { root.takeState(data) })
  }

  function showWindow() {
    if (!windowOpen) { openWindow(); return }
    if (!windowHidden) return
    var g = geometry
    var args = ["show"]
    if (g) args = args.concat([String(g.x), String(g.y), String(g.w), String(g.h)])
    windowCommand(args, function(data) { root.takeState(data) })
  }

  function toggleWindow() {
    windowShown ? hideWindow() : showWindow()
  }

  function pressKey(key) {
    if (windowOpen) windowCommand(["key", key], null)
  }

  // Commands go to the page as its own keys. The desktop's media commands
  // only reach the embedded YouTube frame, which ignores next and previous.
  function playPause() { windowOpen ? pressKey("space") : openWindow() }
  // Live radio has no next song, so next and previous go to the next and
  // previous station in the picker's order, among those with a broadcast.
  function stepStation(step) {
    var order = Model.stationOrder(stations, country, favourites, windowLive)
    var key = Model.stepStation(order, station, step)
    if (key !== "" && key !== station) setStation(key)
  }
  function next() { windowLive ? stepStation(1) : pressKey("N") }
  function previous() { windowLive ? stepStation(-1) : pressKey("P") }

  function setVideoLyrics(on) {
    if (videoLyrics === on) return
    videoLyrics = on
    saveState()
    pressKey("L")
  }

  // The look of the lyric line on the video. Choosing one turns the
  // lyrics on, as it does on the page.
  function setLyricStyle(style) {
    if (Model.lyricStyles.indexOf(style) === -1) return
    lyricStyle = style
    videoLyrics = true
    saveState()
    if (windowOpen) remote({ cmd: "style", value: style }, function(ok) {})
  }

  function setBarLyrics(on) {
    if (barLyrics === on) return
    barLyrics = on
    saveState()
  }

  function toggleFavourite(key) {
    key = String(key || "")
    if (key === "") return
    favourites = Model.toggleFavourite(favourites, key)
    saveState()
  }

  // The full FM.video site as an app of its own. The first use installs a
  // launcher for it with Omarchy's web app installer.
  property bool appInstalled: false
  function openApp() {
    // The site plays by itself when it opens, so say which it should play,
    // and stop the mini player so the two do not play over each other.
    var s = stationObject
    var key = inList ? "" : s ? (s.slug || s.id) : Model.mixCountry(station) !== "" ? station : ""
    var url = Model.siteHref(C.siteBase, key, {
      live: windowLive, list: inList ? { kind: listKind, value: listValue } : null
    })
    appRun.command = [helper, "app", url]
    appRun.running = true
    closeWindow()
  }

  Process {
    id: appRun
    command: [root.helper, "app-installed"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.appInstalled = text.trim() === "true"
    }
  }

  // Pick a station. Opens the video window if it is closed.
  function setStation(key) {
    key = String(key || "")
    if (key === "") return
    var changed = key !== station || inList
    if (changed) {
      stationSetAt = Date.now()
      listKind = ""
      listValue = ""
      listName = ""
      station = key
      saveState()
      loadFeed()
    }
    if (!windowOpen) openWindow()
    else if (changed) changeInPlace({ cmd: "station", value: key })
  }

  // Play a channel, a playlist or the listener's favourites.
  function setList(kind, value, name) {
    kind = String(kind || "")
    value = String(value || "")
    if (["channel", "playlist", "favourites"].indexOf(kind) === -1) return
    if (kind !== "favourites" && !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value)) return
    var changed = kind !== listKind || value !== listValue
    if (changed) {
      stationSetAt = Date.now()
      listKind = kind
      listValue = kind === "favourites" ? "" : value
      listName = String(name || (kind === "favourites" ? "Your favourites" : value))
      if (live) live = false
      saveState()
      loadFeed()
    }
    if (!windowOpen) openWindow()
    else if (changed) changeInPlace(kind === "favourites" ? { cmd: "favourites" } : { cmd: kind, value: value })
  }

  // Add the song on now to the listener's favourites on FM.video, or take
  // it out. Signing in, if needed, happens in the video window.
  function favouriteSong() {
    if (!windowOpen) return
    remote({ cmd: "favourite" }, function(ok) { if (!ok) root.pressKey("H") })
  }

  // Change what the open window plays without reopening it. If the
  // command cannot be sent, or the window has not moved to the station
  // asked for a few seconds later, fall back to reopening it.
  property int changeSerial: 0
  function changeInPlace(command) {
    changeSerial += 1
    var serial = changeSerial
    remote(command, function(ok) {
      if (serial !== root.changeSerial) return
      if (!ok) { root.switchWindow(); return }
      root.delay(9000, function() {
        if (serial !== root.changeSerial || !root.windowOpen) return
        if (root.inList) return
        var want = root.stationObject
        var shown = root.titleInfo ? root.titleInfo.station : ""
        // Country mixes have names the station list does not know, so
        // only single stations can be checked.
        if (want && shown !== "" && !Model.sameText(shown, want.name)) root.switchWindow()
      })
    })
  }

  // Reopen the window on the current station. Clicking through stations
  // quickly would start several of these at once, so only one runs at a
  // time, and the last station asked for wins.
  property double stationSetAt: 0
  property bool switching: false
  property bool switchAgain: false
  function switchWindow() {
    if (switching) { switchAgain = true; return }
    switching = true
    windowCommand(["switch", address()], function(data) {
      root.takeState(data)
      root.noteRemote(data)
      root.switching = false
      if (root.switchAgain) { root.switchAgain = false; root.switchWindow() }
    })
  }

  onWindowOpenChanged: {
    if (windowOpen) {
      windowCommand(["state"], function(data) { root.takeState(data) })
      loadFeed()
    } else {
      windowPid = 0
      windowFullscreen = false
      windowHidden = false
      lyricsFor = ""
      clearLyrics()
    }
  }

  // The page's own full screen button. A pinned window cannot go full
  // screen by itself, so the page counts clicks in its title and the plugin
  // does the work (see Model.fullscreenCount).
  //
  // The page's next and previous station arrows, shown while live, ask the
  // same way with " [nx:N]" and " [pv:N]": the page does not know the
  // order of the plugin's list, favourites first, so the plugin picks.
  property var fullscreenWindow: null
  property int fullscreenSeen: 0
  property int nextSeen: 0
  property int previousSeen: 0
  property int appSeen: 0
  onWindowTitleChanged: {
    var count = Model.fullscreenCount(windowTitle)
    var nx = Model.markerCount(windowTitle, "nx")
    var pv = Model.markerCount(windowTitle, "pv")
    var app = Model.markerCount(windowTitle, "app")
    if (toplevel !== fullscreenWindow) {
      appSeen = app
      fullscreenWindow = toplevel
      fullscreenSeen = count
      nextSeen = nx
      previousSeen = pv
      return
    }
    // The FM.video logo on the page: open the full app.
    if (app !== appSeen) { appSeen = app; openApp(); return }
    if (nx !== nextSeen) { nextSeen = nx; stepStation(1) }
    if (pv !== previousSeen) { previousSeen = pv; stepStation(-1) }
    if (count === fullscreenSeen) return
    fullscreenSeen = count
    windowCommand(["fullscreen"], function(data) { root.takeState(data) })
  }

  // The page is asking the listener to sign in. Its panel is cramped in a
  // small window, so bring the window out and make it bigger for as long
  // as the panel is up, then put it back.
  readonly property bool windowAuth: windowOpen && Model.titleAuth(windowTitle)
  property var authRestore: null
  onWindowAuthChanged: {
    if (windowAuth) {
      if (windowHidden) showWindow()
      var g = geometry
      if (g && g.w < 720 && !windowFullscreen) {
        authRestore = { w: g.w, h: g.h }
        windowCommand(["size", "720", "405"], function(data) { root.takeState(data) })
      }
    } else if (authRestore) {
      var back = authRestore
      authRestore = null
      if (windowOpen) windowCommand(["size", String(back.w), String(back.h)], function(data) { root.takeState(data) })
    }
  }

  // Someone picked another station inside the window: follow it.
  onTitleInfoChanged: {
    if (!titleInfo || !titleInfo.station) return
    // Not while the plugin itself is changing station: the old window is
    // still about for a moment and would pull the choice back.
    if (switching || Date.now() - stationSetAt < 10000) return
    var shown = Model.findStation(stations, titleInfo.station)
    var key = shown ? (shown.slug || shown.id) : ""
    if (key !== "" && (inList || (key !== station && shown !== stationObject))) {
      listKind = ""
      listValue = ""
      listName = ""
      station = key
      saveState()
      loadFeed()
    }
  }

  // Where the window sits, so it can go back there next time.
  Timer {
    interval: 20000
    repeat: true
    running: root.windowOpen
    onTriggered: root.windowCommand(["state"], function(data) { root.takeState(data) })
  }

  // ------------------------------------------------------------ polling

  Timer {
    id: feedTimer
    interval: root.windowOpen || root.panels > 0 ? C.feedIntervalActive : C.feedIntervalIdle
    repeat: true
    running: root.stateLoaded && (root.windowOpen || root.widgets > 0) && !root.inList
    triggeredOnStart: true
    onTriggered: root.loadFeed()
  }

  onPanelsChanged: {
    if (panels > 0) loadLists()
    if (panels > 0 && Date.now() - lastFeedAt > 15000) loadFeed()
  }
  onStateLoadedChanged: if (stateLoaded && inList) loadFeed()

  Timer {
    id: stationsRetry
    interval: 60000
    onTriggered: root.loadStations()
  }

  // ------------------------------------------------------------ saved state

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/fmvideo-omarchy"

  function saveState() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({
      station: station, barLyrics: barLyrics, videoLyrics: videoLyrics, geometry: geometry,
      favourites: favourites, live: live, visualiser: visualiser,
      remoteCode: remoteCode, remoteWindow: remoteWindow,
      listKind: listKind, listValue: listValue, listName: listName, lyricStyle: lyricStyle,
      lastRegisterAt: lastRegisterAt
    }, null, 2) + "\n")
  }

  function applyState(text) {
    try {
      var data = JSON.parse(text)
      if (typeof data.station === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$/.test(data.station)) station = data.station
      if (typeof data.barLyrics === "boolean") barLyrics = data.barLyrics
      if (typeof data.videoLyrics === "boolean") videoLyrics = data.videoLyrics
      if (data.geometry && data.geometry.w > 0 && data.geometry.h > 0) geometry = data.geometry
      if (typeof data.remoteCode === "string" && /^[A-Za-z0-9_-]{24,64}$/.test(data.remoteCode)) remoteCode = data.remoteCode
      if (typeof data.remoteWindow === "string") remoteWindow = data.remoteWindow
      if (["channel", "playlist", "favourites"].indexOf(data.listKind) !== -1 && typeof data.listValue === "string"
          && (data.listKind === "favourites" || /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(data.listValue))) {
        listKind = data.listKind
        listValue = data.listValue
        listName = typeof data.listName === "string" ? data.listName.slice(0, 80) : data.listValue
      }
      if (typeof data.lastRegisterAt === "number") lastRegisterAt = data.lastRegisterAt
      if (Model.lyricStyles.indexOf(data.lyricStyle) !== -1) lyricStyle = data.lyricStyle
      if (typeof data.live === "boolean") live = data.live
      if (typeof data.visualiser === "boolean") visualiser = data.visualiser
      if (Array.isArray(data.favourites))
        favourites = data.favourites.filter(function(k) { return typeof k === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$/.test(k) })
    } catch (e) {}
    stateLoaded = true
  }

  Process {
    id: makeStateDir
    command: ["mkdir", "-p", root.stateDir]
    running: true
    onExited: {
      stateFile.path = root.stateDir + "/state.json"
      tokenFile.path = root.tokenPath
    }
  }

  FileView {
    id: tokenFile
    printErrors: false
    onLoaded: {
      var token = text().trim()
      if (/^fmi_[A-Za-z0-9_-]{8,200}$/.test(token)) root.installToken = token
      root.tokenLoaded = true
    }
    onLoadFailed: { root.tokenLoaded = true; root.registerInstall() }
  }

  FileView {
    id: stateFile
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: root.stateLoaded = true
  }

  // Make this install's code once, from the kernel's random numbers.
  Process {
    id: makeCode
    command: ["sh", "-c", "cat /proc/sys/kernel/random/uuid /proc/sys/kernel/random/uuid | tr -d '\\n-'"]
    running: root.stateLoaded && root.remoteCode === ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var code = text.trim().slice(0, 48)
        if (/^[a-f0-9]{48}$/.test(code)) { root.remoteCode = code; root.saveState() }
      }
    }
  }

  Component.onCompleted: loadStations()

  // ------------------------------------------------------------ commands
  //
  // For keyboard shortcuts and scripts:
  //   omarchy-shell plugin.fm.video toggleWindow

  IpcHandler {
    target: C.pluginId

    function toggleWindow(): void { root.toggleWindow() }
    function openWindow(): void { root.openWindow() }
    function closeWindow(): void { root.closeWindow() }
    function showWindow(): void { root.showWindow() }
    function hideWindow(): void { root.hideWindow() }
    function stop(): void { root.closeWindow() }
    function openApp(): void { root.openApp() }
    // Which tab the panel shows: stations, channels, sets or playlists.
    function tab(name: string): void { root.tabAsked = name; root.tabAskedSerial += 1 }
    function playPause(): void { root.playPause() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function station(key: string): void { root.setStation(key) }
    function channel(slug: string): void { root.setList("channel", slug, "") }
    function playlist(slug: string): void { root.setList("playlist", slug, "") }
    function favourites(): void { root.setList("favourites", "", "") }
    function favouriteSong(): void { root.favouriteSong() }
    function size(name: string): void { root.setWindowSize(name) }
    function live(on: bool): void { root.setLive(on) }
    function visualiser(on: bool): void { root.setVisualiser(on) }
    function lyricStyle(name: string): void { root.setLyricStyle(name) }
    function barLyrics(on: bool): void { root.setBarLyrics(on) }
    function videoLyrics(on: bool): void { root.setVideoLyrics(on) }
    function status(): string {
      return JSON.stringify({
        station: root.station, list: root.feedOwner, stationName: root.stationName, song: root.song, artist: root.artist,
        windowOpen: root.windowOpen, windowShown: root.windowShown, playing: root.playing, live: root.windowLive, lyricLine: root.lyricLine,
        lyricLines: root.lyricLines.length, stations: root.stations.length, error: root.lastError, registered: root.installToken !== ""
      })
    }
  }
}
