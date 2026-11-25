.pragma library

// Logic with no QML in it, so it can be tested with plain Node
// (see tests/model.test.mjs).

// The mini player names its window "song · artist · station", or
// "station · FM.video" before the first song.
function parseTitle(title) {
  var parts = String(title || "").split(" · ")
  if (parts.length < 2) return null
  if (parts.length === 2) {
    if (parts[1] === "FM.video") return { song: "", artist: "", station: parts[0] }
    return { song: parts[0], artist: "", station: parts[1] }
  }
  return {
    song: parts.slice(0, parts.length - 2).join(" · "),
    artist: parts[parts.length - 2],
    station: parts[parts.length - 1]
  }
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

// Rows for the station picker: a heading for each country, the user's own
// country first, then each station. With a search, only the matches.
function stationRows(stations, userCountry, query) {
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
  var codes = Object.keys(groups).sort(function(a, b) {
    if (a === userCountry) return -1
    if (b === userCountry) return 1
    return countryName(a).localeCompare(countryName(b))
  })
  var rows = []
  for (var g = 0; g < codes.length; g++) {
    var code = codes[g]
    rows.push({ kind: "heading", label: countryName(code), key: "" })
    if (!words.length)
      rows.push({ kind: "station", label: "All " + countryName(code) + " stations", detail: "mix", key: "all-" + code.toLowerCase() })
    var members = groups[code].slice().sort(function(a, b) { return (a.sortOrder || 0) - (b.sortOrder || 0) })
    for (var k = 0; k < members.length; k++)
      rows.push({ kind: "station", label: members[k].name, detail: members[k].genre || "", key: members[k].slug || members[k].id })
  }
  return rows
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

function miniHref(base, station, lyrics) {
  var q = []
  if (station) q.push("station=" + encodeURIComponent(station))
  if (lyrics) q.push("lyrics=1")
  return q.length ? base + "?" + q.join("&") : base
}
