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
  property var geometry: null                 // { x, y, w, h } of the video window
  property var favourites: []                 // station keys, in the order they were added
  property bool live: false                   // play the station's own broadcast, not the videos
  property bool visualiser: true              // draw the visualiser while live
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
  readonly property bool windowLive: titleInfo ? titleInfo.live === true : false
  readonly property bool canLive: stationObject !== null && String(stationObject.streamUrl || "") !== ""
  property int windowPid: 0
  property bool opening: false
  property bool windowFullscreen: false
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
    return Model.stationLabel(stations, station)
  }
  readonly property var stationObject: Model.findStation(stations, station)
  readonly property var livePlay: feed.length > 0 && feedStation === station ? feed[0] : null
  readonly property string song: windowOpen
    ? (titleInfo ? titleInfo.song : "")
    : (livePlay ? String(livePlay.title || "") : "")
  readonly property string artist: windowOpen
    ? (titleInfo ? titleInfo.artist : "")
    : (livePlay ? String(livePlay.artist || "") : "")
  readonly property var currentPlay: windowOpen ? Model.findPlay(feed, song, artist) : livePlay
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
          if (status >= 200 && status < 300) {
            try { data = JSON.parse(text.slice(0, cut)) } catch (e) { status = 0 }
          }
          if (request.done) request.done(status, data)
          request.destroy(500)
        }
      }
    }
  }

  function api(path, done) {
    if (Date.now() < pausedUntil) { done(429, null); return }
    var request = requestComponent.createObject(root, {
      done: function(status, data) {
        if (status === 429) root.pausedUntil = Date.now() + 60000
        done(status, data)
      }
    })
    request.command = ["curl", "-sS", "--max-time", "10", "-A", C.userAgent,
      "-H", "X-FMV-Key: " + C.apiKey, "-w", "\n%{http_code}", C.apiBase + path]
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
    var wanted = station
    lastFeedAt = Date.now()
    api("/api/feed/" + encodeURIComponent(feedKey()) + "/20", function(status, data) {
      if (wanted !== root.station) return
      if (status === 200 && data) { root.feed = data; root.feedStation = wanted; root.lastError = "" }
      else if (status !== 429) root.lastError = "Could not reach FM.video"
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

  function loadLyrics() {
    var play = currentPlay
    if (!wantLyrics || !play || !play.youTubeVideoId) { lyricsFor = ""; clearLyrics(); return }
    var video = String(play.youTubeVideoId)
    if (video === lyricsFor) return
    lyricsFor = video
    clearLyrics()

    // One song has several recordings, each timed apart. Asking by video,
    // with the video's real length, gets the lines timed for this cut.
    var seconds = player && player.length > 0 ? Math.round(player.length) : 0
    var path = "/api/lyrics/video/" + encodeURIComponent(video) + "?song=" + encodeURIComponent(play.songId)
    if (seconds >= 20) path += "&d=" + seconds

    api(path, function(status, data) {
      if (root.lyricsFor !== video) return
      if (status === 404 && play.songId) {
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
    loadLyrics()
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
      var now = root.player.position + root.lyricOffset
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
    windowFullscreen = data.open === true && data.fullscreen === true
    // A full screen window is not a place to come back to.
    if (data.w > 0 && data.h > 0 && data.fullscreen !== true) {
      var g = { x: data.x, y: data.y, w: data.w, h: data.h }
      if (!geometry || geometry.x !== g.x || geometry.y !== g.y || geometry.w !== g.w || geometry.h !== g.h) {
        geometry = g
        saveState()
      }
    }
  }

  function address(video) {
    return Model.miniHref(C.miniUrl, station, {
      lyrics: videoLyrics, live: live && canLive, visualiser: visualiser, video: video || ""
    })
  }

  // Play one video now, from the Just played list.
  function playVideo(video) {
    video = String(video || "")
    if (!/^[A-Za-z0-9_-]{6,20}$/.test(video)) return
    if (live) { live = false; saveState() }
    var url = Model.miniHref(C.miniUrl, station, { lyrics: videoLyrics, video: video })
    var done = function(data) { root.opening = false; root.takeState(data) }
    if (windowOpen) windowCommand(["switch", url], done)
    else {
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
    if (windowOpen && titleInfo && live !== windowLive) { live = windowLive; saveState() }
  }

  function openWindow() {
    if (windowOpen || opening) return
    opening = true
    var g = geometry
    var args = ["open", address()]
    if (g) args = args.concat([String(g.x), String(g.y), String(g.w), String(g.h)])
    windowCommand(args, function(data) { root.opening = false; root.takeState(data) })
  }

  function closeWindow() {
    if (!windowOpen) return
    windowCommand(["close"], function(data) { root.takeState(data) })
  }

  // "small", "medium", "large" or "full".
  function setWindowSize(name) {
    if (!windowOpen) return
    var sizes = { small: [480, 270], medium: [720, 405], large: [1280, 720] }
    var done = function(data) { root.takeState(data) }
    if (name === "full") { if (!windowFullscreen) windowCommand(["fullscreen"], done) }
    else if (sizes[name]) windowCommand(["size", String(sizes[name][0]), String(sizes[name][1])], done)
  }

  function toggleWindow() {
    windowOpen ? closeWindow() : openWindow()
  }

  function pressKey(key) {
    if (windowOpen) windowCommand(["key", key], null)
  }

  // Commands go to the page as its own keys. The desktop's media commands
  // only reach the embedded YouTube frame, which ignores next and previous.
  function playPause() { windowOpen ? pressKey("space") : openWindow() }
  function next() { pressKey("N") }
  function previous() { pressKey("P") }

  function setVideoLyrics(on) {
    if (videoLyrics === on) return
    videoLyrics = on
    saveState()
    pressKey("L")
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

  // Pick a station. Opens the video window if it is closed.
  function setStation(key) {
    key = String(key || "")
    if (key === "") return
    var changed = key !== station
    if (changed) {
      station = key
      feed = []
      saveState()
      loadFeed()
    }
    if (!windowOpen) openWindow()
    else if (changed) windowCommand(["switch", address()], function(data) { root.takeState(data) })
  }

  onWindowOpenChanged: {
    if (windowOpen) {
      windowCommand(["state"], function(data) { root.takeState(data) })
      loadFeed()
    } else {
      windowPid = 0
      windowFullscreen = false
      lyricsFor = ""
      clearLyrics()
    }
  }

  // The page's own full screen button. A pinned window cannot go full
  // screen by itself, so the page counts clicks in its title and the plugin
  // does the work (see Model.fullscreenCount).
  property var fullscreenWindow: null
  property int fullscreenSeen: 0
  onWindowTitleChanged: {
    var count = Model.fullscreenCount(windowTitle)
    if (toplevel !== fullscreenWindow) {
      fullscreenWindow = toplevel
      fullscreenSeen = count
      return
    }
    if (count === fullscreenSeen) return
    fullscreenSeen = count
    windowCommand(["fullscreen"], function(data) { root.takeState(data) })
  }

  // Someone picked another station inside the window: follow it.
  onTitleInfoChanged: {
    if (!titleInfo || !titleInfo.station) return
    var shown = Model.findStation(stations, titleInfo.station)
    var key = shown ? (shown.slug || shown.id) : ""
    if (key !== "" && key !== station && shown !== stationObject) {
      station = key
      feed = []
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
    running: root.stateLoaded && (root.windowOpen || root.widgets > 0)
    triggeredOnStart: true
    onTriggered: root.loadFeed()
  }

  onPanelsChanged: if (panels > 0 && Date.now() - lastFeedAt > 15000) loadFeed()

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
      favourites: favourites, live: live, visualiser: visualiser
    }, null, 2) + "\n")
  }

  function applyState(text) {
    try {
      var data = JSON.parse(text)
      if (typeof data.station === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$/.test(data.station)) station = data.station
      if (typeof data.barLyrics === "boolean") barLyrics = data.barLyrics
      if (typeof data.videoLyrics === "boolean") videoLyrics = data.videoLyrics
      if (data.geometry && data.geometry.w > 0 && data.geometry.h > 0) geometry = data.geometry
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
    onExited: stateFile.path = root.stateDir + "/state.json"
  }

  FileView {
    id: stateFile
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: root.stateLoaded = true
  }

  Component.onCompleted: loadStations()

  // ------------------------------------------------------------ commands
  //
  // For keyboard shortcuts and scripts:
  //   omarchy-shell video.fm.radio toggleWindow

  IpcHandler {
    target: C.pluginId

    function toggleWindow(): void { root.toggleWindow() }
    function openWindow(): void { root.openWindow() }
    function closeWindow(): void { root.closeWindow() }
    function playPause(): void { root.playPause() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function station(key: string): void { root.setStation(key) }
    function size(name: string): void { root.setWindowSize(name) }
    function live(on: bool): void { root.setLive(on) }
    function visualiser(on: bool): void { root.setVisualiser(on) }
    function barLyrics(on: bool): void { root.setBarLyrics(on) }
    function videoLyrics(on: bool): void { root.setVideoLyrics(on) }
    function status(): string {
      return JSON.stringify({
        station: root.station, stationName: root.stationName, song: root.song, artist: root.artist,
        windowOpen: root.windowOpen, playing: root.playing, live: root.windowLive, lyricLine: root.lyricLine,
        lyricLines: root.lyricLines.length, stations: root.stations.length, error: root.lastError
      })
    }
  }
}
