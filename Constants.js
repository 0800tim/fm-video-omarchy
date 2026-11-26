.pragma library

// Every fixed value the plugin needs, in one place.

var pluginId = "plugin.fm.video"

// The public, read only key for the FM.video API. It is meant to be seen:
// it only allows reading what the website already shows, and it is limited
// to 90 requests a minute for each user.
var apiBase = "https://api.fm.video"
var apiKey = "fmv_4b3ce31ca24ef80f1faebdb26ccf1db3508f785a9d9a7921"
var userAgent = "fmvideo-omarchy/0.1"

var siteBase = "https://fm.video"
var miniUrl = siteBase + "/mini"

// How often to ask for a station's plays, in milliseconds.
var feedIntervalActive = 40000   // the video window or the panel is open
var feedIntervalIdle = 120000    // only the bar label is showing

var defaultStation = "all-nz"
var defaultWidth = 480
var defaultHeight = 270
// How often to look for new stations: when the panel opens, and in the background.
var stationsRefreshOpen = 300000
var stationsRefreshIdle = 1800000

// The most that is taken in from FM.video in one answer, in bytes, and the
// most items kept from it. A longer answer is thrown away, so a server
// that has gone wrong cannot fill the shell's memory.
var responseLimit = 524288      // every request but the station list
var stationsLimit = 2097152     // the station list, about 300 KB today
var maxStations = 2000
var maxFeed = 50
var maxTracks = 500
var maxLists = 500
