// Tests for Model.js, the logic with no QML in it. Run with: node tests/model.test.mjs

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const names = [...source.matchAll(/^function (\w+)\(/gm)].map((m) => m[1])
const Model = new Function(`${source}\nreturn { ${names.join(", ")} }`)()

let passed = 0
function test(name, fn) {
  fn()
  passed += 1
  console.log("ok   " + name)
}

test("window title: song, artist, station", () => {
  assert.deepEqual(Model.parseTitle("Firefly · Drax Project · ZM"),
    { song: "Firefly", artist: "Drax Project", station: "ZM", live: false })
})

test("window title: before the first song", () => {
  assert.deepEqual(Model.parseTitle("George FM · FM.video"), { song: "", artist: "", station: "George FM", live: false })
})

test("window title: a dot inside the song name stays with the song", () => {
  const t = Model.parseTitle("A · B · Artist · ZM")
  assert.equal(t.song, "A · B")
  assert.equal(t.artist, "Artist")
  assert.equal(t.station, "ZM")
})

test("window title: not ours", () => {
  assert.equal(Model.parseTitle("fm.video_/mini"), null)
  assert.equal(Model.parseTitle(""), null)
})

test("findPlay matches title and artist, ignoring case", () => {
  const feed = [
    { title: "Girls", artist: "Someone Else", songId: 1 },
    { title: "Girls", artist: "The Kid Laroi", songId: 2 },
  ]
  assert.equal(Model.findPlay(feed, "girls", "the kid laroi").songId, 2)
  assert.equal(Model.findPlay(feed, "Girls", "Nobody").songId, 1)
  assert.equal(Model.findPlay(feed, "Missing", "x"), null)
  assert.equal(Model.findPlay([], "Girls", "x"), null)
})

const stations = [
  { id: "ZM-6190", slug: "zm", name: "ZM", country: "NZ", genre: "CHR/pop", sortOrder: 0 },
  { id: "GeorgeFM", slug: "george", name: "George FM", country: "NZ", genre: "dance/electronic", sortOrder: 6 },
  { id: "KEXP", slug: "kexp", name: "KEXP", country: "US", genre: "indie", city: "Seattle", sortOrder: 1 },
  { id: "Off", slug: "off", name: "Off Air", country: "US", isActive: false },
]

test("findStation by id, slug and name", () => {
  assert.equal(Model.findStation(stations, "GeorgeFM").slug, "george")
  assert.equal(Model.findStation(stations, "george").id, "GeorgeFM")
  assert.equal(Model.findStation(stations, "george fm").id, "GeorgeFM")
  assert.equal(Model.findStation(stations, "nope"), null)
})

test("station labels, including country mixes", () => {
  assert.equal(Model.stationLabel(stations, "zm"), "ZM")
  assert.equal(Model.stationLabel(stations, "all-nz"), "New Zealand mix")
  assert.equal(Model.mixCountry("all-gb"), "GB")
  assert.equal(Model.mixCountry("george"), "")
})

test("parseLrc reads times, keeps order and handles two stamps on a line", () => {
  const lines = Model.parseLrc("[00:12.50] first\n[01:02.00][00:30.00] again\nno stamp\n[00:20] plain seconds\n")
  assert.deepEqual(lines.map((l) => l.t), [12.5, 20, 30, 62])
  assert.equal(lines[0].text, "first")
  assert.equal(lines[2].text, "again")
  assert.deepEqual(Model.parseLrc(""), [])
  assert.deepEqual(Model.parseLrc(null), [])
})

test("activeLine is the last line that has started", () => {
  const lines = [{ t: 5 }, { t: 10 }, { t: 20 }]
  assert.equal(Model.activeLine(lines, 0), -1)
  assert.equal(Model.activeLine(lines, 5), 0)
  assert.equal(Model.activeLine(lines, 19.9), 1)
  assert.equal(Model.activeLine(lines, 500), 2)
  assert.equal(Model.activeLine([], 3), -1)
})

test("station rows: own country first, a mix row, inactive stations left out", () => {
  const rows = Model.stationRows(stations, "US", "")
  assert.equal(rows[0].kind, "heading")
  assert.equal(rows[0].label, "United States")
  assert.equal(rows[1].key, "all-us")
  assert.equal(rows[2].key, "kexp")
  assert.ok(!rows.some((r) => r.key === "off"))
  assert.equal(rows.filter((r) => r.kind === "heading").length, 2)
})

test("station rows: search by name, genre, city or country, with no mix rows", () => {
  assert.deepEqual(Model.stationRows(stations, "NZ", "dance").filter((r) => r.kind === "station").map((r) => r.key), ["george"])
  assert.deepEqual(Model.stationRows(stations, "NZ", "seattle").filter((r) => r.kind === "station").map((r) => r.key), ["kexp"])
  assert.equal(Model.stationRows(stations, "NZ", "new zealand").filter((r) => r.kind === "station").length, 2)
  assert.deepEqual(Model.stationRows(stations, "NZ", "zzz"), [])
})

test("shorten adds one ellipsis and never grows the text", () => {
  assert.equal(Model.shorten("short", 10), "short")
  const cut = Model.shorten("a very long line of lyrics indeed", 12)
  assert.ok(cut.length <= 12)
  assert.ok(cut.endsWith("…"))
})

test("logo addresses: site relative ones get the site in front", () => {
  assert.equal(Model.logoUrl("https://fm.video", { logoUrl: "/station-logos/x.png" }), "https://fm.video/station-logos/x.png")
  assert.equal(Model.logoUrl("https://fm.video", { logoHiUrl: "https://cdn.example/x.png" }), "https://cdn.example/x.png")
  assert.equal(Model.logoUrl("https://fm.video", null), "")
})

test("mini player address", () => {
  const base = "https://fm.video/mini"
  assert.equal(Model.miniHref(base, "george"), base + "?station=george&shell=omarchy")
  assert.equal(Model.miniHref(base, "all-nz", { lyrics: true }), base + "?station=all-nz&lyrics=1&shell=omarchy")
  assert.equal(Model.miniHref(base, ""), base + "?shell=omarchy")
  assert.equal(Model.miniHref(base, "george", { live: true }), base + "?station=george&live=1&shell=omarchy")
  assert.equal(Model.miniHref(base, "george", { live: true, visualiser: false }), base + "?station=george&live=1&viz=0&shell=omarchy")
  assert.equal(Model.miniHref(base, "zm", { video: "ZsudGQCy_fM" }), base + "?station=zm&v=ZsudGQCy_fM&shell=omarchy")
  assert.equal(Model.miniHref(base, "zm", { remote: "abc123" }), base + "?station=zm&remote=abc123&shell=omarchy")
})

test("window title: markers at the end in either order", () => {
  for (const tail of [" [lo:+0.4]", " [fs:2] [lo:-1.2]", " [lo:+0.0] [fs:7]"]) {
    const t = Model.parseTitle("Luka \u00b7 Suzanne Vega \u00b7 The Breeze" + tail)
    assert.equal(t.station, "The Breeze")
    assert.equal(t.song, "Luka")
  }
  assert.equal(Model.parseTitle("Luka \u00b7 Suzanne Vega \u00b7 The Breeze Live [fs:2]").live, true)
  assert.equal(Model.fullscreenCount("a \u00b7 b \u00b7 c [fs:7] [lo:+0.2]"), 7)
  assert.equal(Model.titleLyricOffset("a \u00b7 b \u00b7 c [fs:7] [lo:+0.2]"), 0.2)
  assert.equal(Model.titleLyricOffset("a \u00b7 b \u00b7 c [lo:-1.2] [fs:1]"), -1.2)
  assert.equal(Model.titleLyricOffset("a \u00b7 b \u00b7 c"), null)
})

test("window title: live radio", () => {
  const t = Model.parseTitle("Diggy \u00b7 Sammy Virji \u00b7 George FM Live")
  assert.equal(t.station, "George FM")
  assert.equal(t.live, true)
})

test("window title: full screen counter and debug trail are stripped", () => {
  assert.deepEqual(Model.parseTitle("Firefly \u00b7 Drax Project \u00b7 ZM [fs:2]"),
    { song: "Firefly", artist: "Drax Project", station: "ZM", live: false })
  assert.equal(Model.fullscreenCount("Firefly \u00b7 Drax Project \u00b7 ZM [fs:2]"), 2)
  assert.equal(Model.fullscreenCount("Firefly \u00b7 Drax Project \u00b7 ZM"), 0)
  assert.equal(Model.parseTitle("[yt1 yt2] In The Air \u00b7 L.A.B \u00b7 George FM").song, "In The Air")
})

test("country order: yours, neighbours, then most stations first", () => {
  const counts = { NZ: 19, AU: 23, GB: 39, US: 40, ZA: 5, HU: 11 }
  assert.deepEqual(Model.countryOrder(counts, "NZ"), ["NZ", "AU", "US", "GB", "HU", "ZA"])
  assert.deepEqual(Model.countryOrder(counts, "GB").slice(0, 2), ["GB", "US"])
  assert.deepEqual(Model.countryOrder({ CA: 23, MX: 10, US: 40, GB: 39 }, "US"), ["US", "CA", "MX", "GB"])
  assert.equal(Model.countryOrder(counts, "")[0], "US")
})

test("favourites: listed first, marked in place, hidden while searching", () => {
  const rows = Model.stationRows(stations, "NZ", "", ["george", "all-us", "gone"])
  assert.equal(rows[0].label, "Favourites")
  assert.deepEqual([rows[1].key, rows[2].key], ["george", "all-us"])
  assert.equal(rows[3].label, "New Zealand")
  assert.equal(rows.filter((r) => r.key === "george").length, 2)
  assert.ok(rows.filter((r) => r.key === "george").every((r) => r.favourite))
  assert.equal(rows.find((r) => r.key === "zm").favourite, false)
  assert.equal(Model.stationRows(stations, "NZ", "zm", ["george"])[0].label, "New Zealand")
})

test("lineProgress: sung at a natural pace, sooner if the next line is close", () => {
  const lines = [
    { t: 10, text: "one two three four five" },   // natural pace is 2.9 s
    { t: 60, text: "a b" },                       // next line 1 s later
    { t: 61, text: "last line here" },
  ]
  assert.equal(Model.lineProgress(lines, 0, 10), 0)
  assert.ok(Math.abs(Model.lineProgress(lines, 0, 11.45) - 0.5) < 0.001)
  // A long gap after the line: it is sung, then stays lit.
  assert.equal(Model.lineProgress(lines, 0, 13), 1)
  assert.equal(Model.lineProgress(lines, 0, 40), 1)
  // The next line is close: finish just before it.
  assert.ok(Math.abs(Model.lineProgress(lines, 1, 60.46) - 0.5) < 0.001)
  // The last line uses the natural pace (3 words: 2.06 s).
  assert.ok(Math.abs(Model.lineProgress(lines, 2, 62.03) - 0.5) < 0.001)
  assert.equal(Model.lineProgress(lines, -1, 5), 0)
})

test("next and previous station follow the picker's order", () => {
  const list = stations.map((s) => (s.slug === "kexp" ? { ...s, streamUrl: "https://x/stream" } : s))
    .map((s) => (s.slug === "zm" ? { ...s, streamUrl: "https://y/stream" } : s))
  const all = Model.stationOrder(list, "NZ", ["kexp"], false)
  assert.deepEqual(all, ["kexp", "all-nz", "zm", "george", "all-us"])
  const live = Model.stationOrder(list, "NZ", ["kexp"], true)
  assert.deepEqual(live, ["kexp", "zm"])
  assert.equal(Model.stepStation(live, "kexp", 1), "zm")
  assert.equal(Model.stepStation(live, "zm", 1), "kexp")
  assert.equal(Model.stepStation(live, "kexp", -1), "zm")
  assert.equal(Model.stepStation(live, "george", 1), "kexp")
  assert.equal(Model.stepStation([], "zm", 1), "")
})

test("window title: next and previous station counters", () => {
  const title = "Diggy \u00b7 Sammy Virji \u00b7 George FM Live [nx:3] [app:1] [pv:1] [fs:2]"
  assert.equal(Model.markerCount(title, "nx"), 3)
  assert.equal(Model.markerCount(title, "pv"), 1)
  assert.equal(Model.markerCount(title, "app"), 1)
  assert.equal(Model.markerCount("a \u00b7 b \u00b7 c", "nx"), 0)
  const t = Model.parseTitle(title)
  assert.equal(t.station, "George FM")
  assert.equal(t.live, true)
})

test("toggleFavourite adds and removes", () => {
  assert.deepEqual(Model.toggleFavourite([], "zm"), ["zm"])
  assert.deepEqual(Model.toggleFavourite(["zm", "george"], "zm"), ["george"])
})

console.log(`\n${passed} tests passed`)
