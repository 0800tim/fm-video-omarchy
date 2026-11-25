.pragma library

// Logic with no QML in it, so it can be tested with plain Node
// (see tests/model.test.mjs).

// The mini player names its window "song · artist · station", or
// "station · FM.video" before the first song.
function parseTitle(title) {
  var clean = stripMarkers(title).replace(/^\[[^\]]*\]\s+/, "")
  var parts = clean.split(" \u00b7 ")
  if (parts.length < 2) return null
  var out
  if (parts.length === 2) {
    if (parts[1] === "FM.video") out = { song: "", artist: "", station: parts[0] }
    else out = { song: parts[0], artist: "", station: parts[1] }
  } else {
    out = {
      song: parts.slice(0, parts.length - 2).join(" \u00b7 "),
      artist: parts[parts.length - 2],
      station: parts[parts.length - 1]
    }
  }
  // "George FM Live" means the window is playing the station's own
  // broadcast and not the music videos.
  out.live = / Live$/.test(out.station)
  if (out.live) out.station = out.station.replace(/ Live$/, "")
  return out
}

// Extras can ride along on the title. At the end, in any order: " [fs:3]"
// counts clicks on the page's full screen button, which is how it asks the
// plugin to make the window fill the screen, and " [lo:+0.4]" is the lyric
// timing in use, in seconds. The page's debug mode puts "[...] " at the
// front. parseTitle drops them all.
function stripMarkers(title) {
  var s = String(title || "")
  var marker = /\s\[(?:fs|lo|nx|pv|app|v|auth):[^\]]*\]\s*$/
  while (marker.test(s)) s = s.replace(marker, "")
  return s
}

function fullscreenCount(title) {
  var m = /\s\[fs:(\d+)\]/.exec(String(title || ""))
  return m ? parseInt(m[1], 10) : 0
}

// Clicks on the page's next ("nx") and previous ("pv") station arrows,
// counted the same way as the full screen button: " [nx:2]".
function markerCount(title, name) {
  var m = new RegExp("\\s\\[" + name + ":(\\d+)\\]").exec(String(title || ""))
  return m ? parseInt(m[1], 10) : 0
}

// The YouTube id of the video on now, from " [v:...]", or "".
function titleVideo(title) {
  var m = /\s\[v:([A-Za-z0-9_-]{6,20})\]/.exec(String(title || ""))
  return m ? m[1] : ""
}

// True while the page is showing its sign in panel: " [auth:1]".
function titleAuth(title) {
  return /\s\[auth:1\]/.test(String(title || ""))
}

// The lyric timing the window is using, or null when it does not say.
function titleLyricOffset(title) {
  var m = /\s\[lo:([+-]?\d+(?:\.\d+)?)\]/.exec(String(title || ""))
  return m ? parseFloat(m[1]) : null
}

function sameText(a, b) {
  return String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase()
}

// The play in a feed that matches what the window says it is showing.
function findPlay(feed, song, artist) {
  if (!feed || !song) return null
  for (var i = 0; i < feed.length; i++)
    if (sameText(feed[i].title, song) && sameText(feed[i].artist, artist)) return feed[i]
  for (var j = 0; j < feed.length; j++)
    if (sameText(feed[j].title, song)) return feed[j]
  return null
}

function findStation(stations, key) {
  if (!stations || !key) return null
  for (var i = 0; i < stations.length; i++) {
    var s = stations[i]
    if (s.id === key || s.slug === key) return s
  }
  for (var j = 0; j < stations.length; j++)
    if (sameText(stations[j].name, key)) return stations[j]
  return null
}

// "all-nz" style country mixes are not in the station list.
function mixCountry(key) {
  var m = /^all-([a-z]{2})$/i.exec(String(key || ""))
  return m ? m[1].toUpperCase() : ""
}

var countryNames = {
  AU: "Australia", CA: "Canada", CL: "Chile", CO: "Colombia", DE: "Germany",
  ES: "Spain", FR: "France", GB: "United Kingdom", HU: "Hungary", IT: "Italy",
  MX: "Mexico", NL: "Netherlands", NZ: "New Zealand", PL: "Poland",
  SE: "Sweden", US: "United States", ZA: "South Africa", IE: "Ireland"
}

function countryName(code) {
  return countryNames[code] || code || "Other"
}

function stationLabel(stations, key) {
  var s = findStation(stations, key)
  if (s) return s.name
  var c = mixCountry(key)
  return c ? countryName(c) + " mix" : String(key || "")
}

// Parse LRC text ("[mm:ss.xx] line") into [{ t: seconds, text }], in order.
function parseLrc(text) {
  var out = []
  var rows = String(text || "").split(/\r?\n/)
  var stamp = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/g
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var times = []
    var m
    stamp.lastIndex = 0
    var end = 0
    while ((m = stamp.exec(row)) !== null) {
      times.push(parseInt(m[1], 10) * 60 + parseFloat(m[2].replace(":", ".")))
      end = stamp.lastIndex
    }
    if (times.length === 0) continue
    var line = row.slice(end).trim()
    for (var k = 0; k < times.length; k++) out.push({ t: times[k], text: line })
  }
  out.sort(function(a, b) { return a.t - b.t })
  return out
}

// The index of the last line that has started `t` seconds in, or -1.
function activeLine(lines, t) {
  var lo = 0, hi = lines.length - 1, at = -1
  while (lo <= hi) {
    var mid = (lo + hi) >> 1
    if (lines[mid].t <= t) { at = mid; lo = mid + 1 } else hi = mid - 1
  }
  return at
}

// How much of the line being sung to light up, from 0 to 1. Nothing times
// single words, so this is an estimate, and the same one the FM.video page
// makes so the bar and the video agree: a line is sung at the pace of most
// pop (0.42 seconds a word, plus a breath), or faster if the next line
// comes sooner. A line before a long gap is sung at that pace and then
// stays lit.
function lineProgress(lines, at, t) {
  if (at < 0 || at >= lines.length) return 0
  var start = lines[at].t
  var words = String(lines[at].text || "").split(/\s+/).filter(function(w) { return w !== "" }).length
  var natural = words * 0.42 + 0.8
  var gap = at + 1 < lines.length ? (lines[at + 1].t - start) * 0.92 : natural
  var span = Math.max(0.5, Math.min(gap, natural))
  return Math.max(0, Math.min(1, (t - start) / span))
}

// The countries listed first after your own: the ones next door, or the ones
// whose radio you are most likely to know.
var neighbours = {
  NZ: ["AU"], AU: ["NZ"], US: ["CA", "MX"], CA: ["US"], MX: ["US", "CO"],
  GB: ["IE", "FR", "NL"], IE: ["GB"], FR: ["ES", "IT", "DE", "GB"], DE: ["NL", "FR", "PL"],
  NL: ["DE", "GB"], ES: ["FR", "IT"], IT: ["FR", "ES"], PL: ["DE", "HU"], HU: ["PL", "DE"],
  SE: ["DE", "NL"], CO: ["CL", "MX"], CL: ["CO"], ZA: []
}

// Country codes in the order to show them: yours, your neighbours, then
// the rest with the most stations first.
function countryOrder(counts, userCountry) {
  var near = neighbours[userCountry] || []
  var rank = function(code) {
    if (code === userCountry) return 0
    var at = near.indexOf(code)
    return at >= 0 ? 1 + at : 100
  }
  return Object.keys(counts).sort(function(a, b) {
    var ra = rank(a), rb = rank(b)
    if (ra !== rb) return ra - rb
    if (counts[a] !== counts[b]) return counts[b] - counts[a]
    return countryName(a).localeCompare(countryName(b))
  })
}

// Rows for the station picker: favourites, then a heading for each country
// (see countryOrder) with its stations. With a search, only the matches.
function stationRows(stations, userCountry, query, favourites) {
  var favs = favourites || []
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
  var groups = {}
  var list = stations || []
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    if (s.isActive === false) continue
    var c = s.country || "??"
    if (words.length) {
      var hay = (s.name + " " + (s.city || "") + " " + (s.genre || "") + " " + countryName(c)).toLowerCase()
      var hit = true
      for (var w = 0; w < words.length; w++) if (hay.indexOf(words[w]) === -1) { hit = false; break }
      if (!hit) continue
    }
    if (!groups[c]) groups[c] = []
    groups[c].push(s)
  }
  var counts = {}
  for (var code0 in groups) counts[code0] = groups[code0].length
  var codes = countryOrder(counts, userCountry)
  var rows = []
  var isFav = function(key) { return favs.indexOf(key) !== -1 }

  if (!words.length && favs.length) {
    var mine = []
    for (var f = 0; f < favs.length; f++) {
      var station = findStation(list, favs[f])
      if (station && station.isActive !== false)
        mine.push({ kind: "station", label: station.name, detail: station.genre || "", key: favs[f], favourite: true })
      else if (mixCountry(favs[f]) !== "")
        mine.push({ kind: "station", label: "All " + countryName(mixCountry(favs[f])) + " stations", detail: "mix", key: favs[f], favourite: true })
    }
    if (mine.length) rows.push({ kind: "heading", label: "Favourites", key: "" })
    rows = rows.concat(mine)
  }

  for (var g = 0; g < codes.length; g++) {
    var code = codes[g]
    var mix = "all-" + code.toLowerCase()
    rows.push({ kind: "heading", label: countryName(code), key: "" })
    if (!words.length)
      rows.push({ kind: "station", label: "All " + countryName(code) + " stations", detail: "mix", key: mix, favourite: isFav(mix) })
    var members = groups[code].slice().sort(function(a, b) { return (a.sortOrder || 0) - (b.sortOrder || 0) })
    for (var k = 0; k < members.length; k++) {
      var key = members[k].slug || members[k].id
      rows.push({ kind: "station", label: members[k].name, detail: members[k].genre || "", key: key, favourite: isFav(key) })
    }
  }
  return rows
}

// Station keys in the order the picker shows them, each once: favourites
// first. With liveOnly, only stations that have a broadcast to listen to.
function stationOrder(stations, userCountry, favourites, liveOnly) {
  var rows = stationRows(stations, userCountry, "", favourites)
  var seen = {}
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var key = rows[i].key
    if (rows[i].kind !== "station" || seen[key]) continue
    seen[key] = true
    if (liveOnly) {
      var s = findStation(stations, key)
      if (!s || !s.streamUrl) continue
    }
    out.push(key)
  }
  return out
}

// The station `step` places on from `current` in `order`, going round at
// the ends. A station that is not in the list starts from the top.
function stepStation(order, current, step) {
  if (!order || order.length === 0) return ""
  var at = order.indexOf(current)
  if (at < 0) return order[0]
  return order[((at + step) % order.length + order.length) % order.length]
}

// The list of favourites with one station added, or taken out if it was in.
function toggleFavourite(favourites, key) {
  var out = (favourites || []).filter(function(k) { return k !== key })
  if (out.length === (favourites || []).length) out.push(key)
  return out
}

function shorten(text, max) {
  var s = String(text || "")
  return s.length > max ? s.slice(0, Math.max(1, max - 1)).replace(/\s+$/, "") + "…" : s
}

function logoUrl(siteBase, station) {
  var u = station ? (station.logoHiUrl || station.logoUrl || "") : ""
  if (!u) return ""
  return u.charAt(0) === "/" ? siteBase + u : u
}

// The address of the mini player. `options` may hold lyrics, live (play
// the station's own broadcast), video (a YouTube id to start with), remote
// (the code commands are sent on) and list ({ kind, value }: a channel, a
// playlist or the listener's favourites, played in place of a station).
function miniHref(base, station, options) {
  var o = options || {}
  var q = []
  var list = o.list && o.list.kind ? o.list : null
  if (list && list.kind === "favourites") q.push("favourites=1")
  else if (list) q.push(list.kind + "=" + encodeURIComponent(list.value))
  else if (station) q.push("station=" + encodeURIComponent(station))
  if (o.lyrics) q.push("lyrics=1")
  if (o.style && o.style !== "plain") q.push("style=" + encodeURIComponent(o.style))
  if (o.live && !list) {
    q.push("live=1")
    if (o.visualiser === false) q.push("viz=0")
  } else if (o.video) {
    q.push("v=" + encodeURIComponent(o.video))
  }
  // The code the plugin sends commands to this window on.
  if (o.remote) q.push("remote=" + encodeURIComponent(o.remote))
  // Tells the page it is inside the plugin's window (see fullscreenCount).
  q.push("shell=omarchy")
  return base + "?" + q.join("&")
}

// The looks the page can give its lyric line, in the order they cycle.
var lyricStyles = ["plain", "dots", "blocks", "sparkle", "explode", "outline", "typewriter", "wave"]

function nextLyricStyle(current, step) {
  var at = lyricStyles.indexOf(current)
  if (at < 0) at = 0
  return lyricStyles[((at + step) % lyricStyles.length + lyricStyles.length) % lyricStyles.length]
}

// The page on the full site for what is playing.
function siteHref(base, station, options) {
  var o = options || {}
  var list = o.list && o.list.kind ? o.list : null
  if (list && list.kind === "favourites") return base + "/favourites"
  if (list && list.kind === "playlist") return base + "/playlist/" + encodeURIComponent(list.value)
  if (list && list.kind === "channel") return base + "/c/" + encodeURIComponent(list.value)
  if (!station) return base
  return base + "/station/" + encodeURIComponent(station) + (o.live ? "?live=1" : "")
}

// A channel's or playlist's songs in the shape of a station's plays.
function listTracks(kind, data) {
  var raw = kind === "playlist" ? (data && data.items) : (data && data.tracks)
  var out = []
  for (var i = 0; raw && i < raw.length; i++) {
    var t = raw[i]
    out.push({
      title: String(t.title || ""), artist: String(t.artist || ""),
      youTubeVideoId: t.youTubeVideoId || t.youtube_video_id || "",
      songId: t.songId || t.song_id || null,
      isExplicit: t.isExplicit === true, playedOn: null
    })
  }
  return out
}

function matchesWords(text, words) {
  var hay = String(text || "").toLowerCase()
  for (var w = 0; w < words.length; w++) if (hay.indexOf(words[w]) === -1) return false
  return true
}

// Rows for the other tabs of the picker. `tab` is "channels" (styles and
// decades), "sets" (festivals, venues and live sessions) or "playlists".
// A row's key is "channel:pop", "playlist:abc" or "favourites:".
function listRows(tab, channels, playlists, query) {
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
  var rows = []
  var group = function(heading, items) {
    if (!items.length) return
    rows.push({ kind: "heading", label: heading, key: "" })
    rows = rows.concat(items)
  }
  var count = function(n) { return n > 0 ? n + (n === 1 ? " song" : " songs") : "" }
  var channelRow = function(c) {
    return { kind: "station", label: c.name, detail: count(c.trackCount || 0), key: "channel:" + c.slug, list: true }
  }
  var list = (channels || []).filter(function(c) {
    return c && c.slug && matchesWords(c.name + " " + (c.description || ""), words)
  })

  if (tab === "channels") {
    group("Styles", list.filter(function(c) { return c.kind === "channel" }).map(channelRow))
    group("Decades", list.filter(function(c) { return c.kind === "era" }).map(channelRow))
  } else if (tab === "sets") {
    var sets = list.filter(function(c) { return c.kind === "list" })
    group("Festivals by style", sets.filter(function(c) { return c.slug.indexOf("festivals") === 0 }).map(channelRow))
    group("Festivals, venues and sessions", sets.filter(function(c) { return c.slug.indexOf("festivals") !== 0 }).map(channelRow))
  } else if (tab === "playlists") {
    if (matchesWords("your favourites", words))
      group("Yours", [{ kind: "station", label: "Your favourites", detail: "sign in on the video", key: "favourites:", list: true }])
    group("Trending playlists", (playlists || []).filter(function(p) {
      return p && p.share_slug && matchesWords(p.name + " " + (p.description || "") + " " + ((p.genres || []).join(" ")), words)
    }).map(function(p) {
      var by = p.curator && p.curator.display_name ? "by " + p.curator.display_name : count(p.track_count || 0)
      return { kind: "station", label: p.name, detail: by, key: "playlist:" + p.share_slug, list: true }
    }))
  }
  return rows
}
