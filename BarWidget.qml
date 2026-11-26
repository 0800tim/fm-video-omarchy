import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Constants.js" as C
import "Model.js" as Model

// FM.video in the bar: the song on now, with play, pause and next.
//
// The icon plays and pauses (or starts the video when it is closed). The
// song opens the panel: stations, what was just played, the video window
// and lyrics. Right click anywhere opens the panel too, and middle click
// opens or closes the video window.
Panel {
  id: root
  moduleName: C.pluginId
  // The service answers on the plugin's name, so the panel base does not.
  ipcTarget: ""

  // The service arrives a moment after the first widget, so keep asking.
  property var svc: null
  function findService() {
    if (svc) return
    var found = bar && bar.shell && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor(C.pluginId) : null
    if (found) svc = found
  }
  onBarChanged: findService()
  Timer {
    interval: 500
    repeat: true
    running: root.svc === null
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  property var counted: null
  onSvcChanged: {
    if (svc && counted !== svc) { svc.widgets += 1; counted = svc }
  }
  Component.onDestruction: {
    if (counted) counted.widgets -= 1
    if (counted && opened) counted.panels -= 1
  }
  onOpenedChanged: {
    if (svc) svc.panels += opened ? 1 : -1
    if (opened) { search.text = ""; root.cursor = -1 }
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // A light theme gets the logo drawn for light backgrounds.
  readonly property bool lightPanel: {
    var c = Commons.Color.popups.background
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.6
  }

  readonly property string glyphRadio: "\u{F0439}"
  readonly property string glyphPlay: "\u{F040A}"
  readonly property string glyphPause: "\u{F03E4}"
  readonly property string glyphNext: "\u{F04AD}"
  readonly property string glyphPrevious: "\u{F04AE}"
  readonly property string glyphStop: "\u{F04DB}"
  readonly property string glyphHeart: "\u{F02D1}"
  readonly property string glyphHeartOutline: "\u{F02D5}"

  readonly property bool windowOpen: svc ? svc.windowOpen : false
  readonly property bool playing: svc ? svc.playing : false
  readonly property bool windowLive: svc ? svc.windowLive : false
  readonly property bool windowShown: svc ? svc.windowShown : false
  readonly property bool showSongWhenClosed: setting("showSongWhenClosed", true) === true
  readonly property int maxLength: Math.max(12, Number(setting("maxLength", 56)) || 56)

  readonly property string songText: {
    if (!svc || svc.song === "") return ""
    return svc.song + (svc.artist !== "" ? " · " + svc.artist : "")
  }
  // Set "hideExplicitLyrics": true in shell.json to keep the words of songs
  // marked explicit out of the bar.
  readonly property bool hideExplicit: setting("hideExplicitLyrics", false) === true
  readonly property bool showingLyric: svc !== null && svc.barLyrics && svc.lyricLine !== ""
    && !(hideExplicit && svc.currentPlay && svc.currentPlay.isExplicit === true)
  readonly property string labelText: {
    if (!svc || vertical) return ""
    if (!windowOpen && !showSongWhenClosed) return ""
    if (showingLyric) return Model.shorten(svc.lyricLine, maxLength)
    return Model.shorten(songText, maxLength)
  }
  readonly property string tip: {
    if (!svc) return "FM.video"
    var where = svc.stationName !== "" ? svc.stationName : "FM.video"
    var what = songText !== "" ? "\n" + songText : ""
    return where + what
  }

  implicitWidth: vertical ? barSize : row.implicitWidth
  implicitHeight: vertical ? column.implicitHeight : barSize
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  function press(button, primary) {
    if (!svc) return
    if (button === Qt.MiddleButton) svc.toggleWindow()
    else if (button === Qt.RightButton) root.toggle()
    else primary()
  }

  // The panel hangs from this, not from the song label. The label changes
  // width with every lyric line, and the panel would slide about with it.
  // In the right hand end of the bar the widget's right edge stays put as
  // it grows, and in the left hand end its left edge does.
  readonly property bool growsRight: {
    var left = bar && bar.layoutConfig ? bar.layoutConfig.left : null
    if (!Array.isArray(left)) return false
    for (var i = 0; i < left.length; i++) if (left[i] && left[i].id === C.pluginId) return true
    return false
  }
  Item {
    id: panelAnchor
    width: Math.min(parent.width, root.barSize)
    height: parent.height
    x: root.growsRight ? 0 : parent.width - width
  }

  Row {
    id: row
    visible: !root.vertical
    height: parent.height

    BarIconButton {
      id: playButton
      height: parent.height
      bar: root.bar
      text: !root.windowOpen ? root.glyphRadio : root.playing ? root.glyphPause : root.glyphPlay
      dimmed: !root.windowOpen
      tooltipText: root.opened ? "" : !root.windowOpen
        ? root.tip + "\nClick to watch"
        : root.tip + (root.playing ? "\nClick to pause" : "\nClick to play")
      onPressed: function(b) { root.press(b, function() { root.svc.playPause() }) }
    }

    WidgetButton {
      id: label
      height: parent.height
      bar: root.bar
      text: root.labelText
      horizontalMargin: 4
      dimmed: !root.windowOpen
      // For a lyric line the button's own label only holds the space. The
      // two copies below draw it: a dim one, and a bright one that is
      // uncovered from the left as the line is sung.
      labelVisible: !root.showingLyric
      tooltipText: root.opened ? "" : root.tip + "\nClick for stations"
      onPressed: function(b) { root.press(b, function() { root.toggle() }) }

      Item {
        id: karaoke
        visible: root.showingLyric
        anchors.centerIn: parent
        width: unsung.implicitWidth
        height: unsung.implicitHeight

        Text {
          id: unsung
          textFormat: Text.PlainText
          text: root.labelText
          color: label.foreground
          opacity: 0.5
          font.family: label.fontFamily
          font.pixelSize: label.fontSize
          renderType: Text.NativeRendering
        }

        Item {
          clip: true
          height: parent.height
          width: Math.round(parent.width * (root.svc ? root.svc.lyricProgress : 0))
          // Glide between readings, but snap back for a new line.
          Behavior on width {
            enabled: root.svc !== null && root.svc.lyricProgress > 0.02
            NumberAnimation { duration: 200; easing.type: Easing.Linear }
          }

          Text {
            textFormat: Text.PlainText
            text: root.labelText
            color: label.foreground
            font.family: label.fontFamily
            font.pixelSize: label.fontSize
            renderType: Text.NativeRendering
          }
        }
      }
    }

    BarIconButton {
      id: nextButton
      height: parent.height
      bar: root.bar
      text: root.glyphNext
      hasVisualContent: root.windowOpen
      tooltipText: root.opened ? "" : root.windowLive ? "Next station" : "Next song"
      onPressed: function(b) { root.press(b, function() { root.svc.next() }) }
    }
  }

  // An upright bar only has room for the icon.
  Column {
    id: column
    visible: root.vertical
    width: parent.width

    BarIconButton {
      id: uprightButton
      width: parent.width
      bar: root.bar
      text: playButton.text
      dimmed: !root.windowOpen
      tooltipText: root.opened ? "" : root.tip + "\nClick for stations"
      onPressed: function(b) { root.press(b, function() { root.toggle() }) }
    }
  }

  // ------------------------------------------------------------ the panel

  property string query: ""
  property int cursor: -1
  // "stations", "channels", "sets" or "playlists".
  property string tab: "stations"
  readonly property int tabAskedSerial: svc ? svc.tabAskedSerial : 0
  onTabAskedSerialChanged: {
    if (svc && ["stations", "channels", "sets", "playlists"].indexOf(svc.tabAsked) !== -1) tab = svc.tabAsked
  }
  readonly property var rows: !svc ? []
    : tab === "stations" ? Model.stationRows(svc.stations, svc.country, query, svc.favourites)
    : Model.listRows(tab, svc.channels, svc.playlists, query)

  function moveCursor(step) {
    var at = cursor
    for (var i = 0; i < rows.length; i++) {
      at += step
      if (at < 0 || at >= rows.length) return
      if (rows[at].kind === "station") { cursor = at; stationList.positionViewAtIndex(at, ListView.Contain); return }
    }
  }

  function pickCursor() {
    var at = cursor
    if (at < 0) for (var i = 0; i < rows.length; i++) if (rows[i].kind === "station") { at = i; break }
    if (at >= 0 && rows[at]) pick(rows[at].key)
  }

  function pick(key) {
    if (!svc || !key) return
    // The panel stays open, so you can click through stations and see what
    // each is playing. Click outside it, or press Escape, to close it.
    var at = key.indexOf(":")
    if (tab === "stations" || at < 0) { svc.setStation(key); return }
    var name = ""
    for (var i = 0; i < rows.length; i++) if (rows[i].key === key) { name = rows[i].label; break }
    svc.setList(key.slice(0, at), key.slice(at + 1), name)
  }

  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property bool checked: false
    signal toggled()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowLabel.implicitHeight, rowSwitch.implicitHeight)

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.right: rowSwitch.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: switchRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      foreground: root.foreground
      onToggled: switchRow.toggled()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.vertical ? uprightButton : panelAnchor
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: search
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.fill: parent
      spacing: Style.space(12)

      PanelHero {
        id: hero
        width: parent.width
        title: root.svc ? root.svc.stationName : "FM.video"
        meta: !root.svc ? "" : root.svc.lastError !== "" ? root.svc.lastError.toUpperCase()
          : !root.windowOpen ? "ON AIR NOW" : root.svc.windowStall >= 3 ? "YOUTUBE IS NOT ANSWERING" : root.svc.windowStall > 0 ? "TRYING THE VIDEO AGAIN" : !root.playing ? "PAUSED" : root.windowLive ? "LIVE" : "PLAYING"
        foreground: root.foreground
        fontFamily: root.fontFamily
        // The FM.video mark, top right. Click it for the full app.
        trailingControl: Component {
          Item {
            implicitHeight: Style.space(28)
            implicitWidth: implicitHeight

            Image {
              anchors.fill: parent
              fillMode: Image.PreserveAspectFit
              sourceSize.width: parent.implicitWidth * 3
              sourceSize.height: parent.implicitHeight * 3
              smooth: true
              source: Qt.resolvedUrl(root.lightPanel ? "assets/fmvideo-mark-onlight.svg" : "assets/fmvideo-mark.svg")
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.svc) { root.svc.openApp(); root.close() }
            }
          }
        }
        iconComponent: Component {
          Item {
            implicitWidth: Style.space(40)
            implicitHeight: Style.space(40)

            Image {
              id: logo
              anchors.fill: parent
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              sourceSize.width: 96
              sourceSize.height: 96
              source: root.svc ? Model.logoUrl(C.siteBase, root.svc.stationObject) : ""
            }

            Text {
              anchors.centerIn: parent
              visible: logo.status !== Image.Ready
              textFormat: Text.PlainText
              text: root.glyphRadio
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }
      }

      // Every part of the panel keeps its place and its height whatever it
      // has to show, so nothing jumps as you click through stations or as
      // the lyric line changes. An empty line is a blank line, not a gap
      // that closes up.
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.songText !== "" ? root.songText : " "
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        maximumLineCount: 1
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.svc !== null && root.svc.barLyrics && root.windowOpen && !root.windowLive
        textFormat: Text.PlainText
        text: root.showingLyric ? root.svc.lyricLine : " "
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.italic: true
        maximumLineCount: 1
        elide: Text.ElideRight
      }

      Row {
        spacing: Style.space(8)
        visible: root.windowOpen

        PanelActionButton {
          iconText: root.glyphPrevious
          tooltipText: root.windowLive ? "Previous station" : "Previous song"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.svc.previous()
        }
        PanelActionButton {
          iconText: root.playing ? root.glyphPause : root.glyphPlay
          tooltipText: root.playing ? "Pause" : "Play"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.svc.playPause()
        }
        PanelActionButton {
          iconText: root.glyphNext
          tooltipText: root.windowLive ? "Next station" : "Next song"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.svc.next()
        }
        PanelActionButton {
          visible: !root.windowLive
          iconText: root.glyphHeartOutline
          tooltipText: "Add this song to your FM.video favourites"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.svc.favouriteSong()
        }
        PanelActionButton {
          iconText: root.glyphStop
          tooltipText: "Stop and close"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.svc.closeWindow()
        }
      }

      PanelSeparator { foreground: root.foreground }

      // Off hides the window and the music carries on. Stop, above, is
      // what turns it off.
      SwitchRow {
        label: root.windowLive ? "Show visualiser" : "Show video"
        checked: root.windowShown
        onToggled: if (root.svc) root.svc.toggleWindow()
      }
      SwitchRow {
        // Always there, so the rows below do not shift between stations.
        // Faded for a station with no broadcast to listen to.
        label: "Listen live"
        opacity: root.svc !== null && root.svc.canLive ? 1 : 0.4
        checked: root.svc ? (root.windowOpen ? root.windowLive : root.svc.live) : false
        onToggled: if (root.svc) root.svc.setLive(!checked)
      }
      SwitchRow {
        visible: !root.windowLive
        label: "Lyrics in the bar"
        checked: root.svc ? root.svc.barLyrics : false
        onToggled: if (root.svc) root.svc.setBarLyrics(!root.svc.barLyrics)
      }
      SwitchRow {
        visible: !root.windowLive
        label: "Lyrics on the video"
        checked: root.svc ? root.svc.videoLyrics : false
        onToggled: if (root.svc) root.svc.setVideoLyrics(!root.svc.videoLyrics)
      }

      // The look of the lyric line on the video. Click for the next one,
      // right click for the one before.
      Item {
        visible: !root.windowLive
        width: parent.width
        implicitHeight: styleButton.implicitHeight

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Lyric style"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Button {
          id: styleButton
          anchors.right: parent.right
          width: Style.space(130)
          readonly property string style: root.svc ? root.svc.lyricStyle : "plain"
          text: style.charAt(0).toUpperCase() + style.slice(1)
          tooltipText: "Click for the next style"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: if (root.svc) root.svc.setLyricStyle(Model.nextLyricStyle(style, 1))
          onRightClicked: if (root.svc) root.svc.setLyricStyle(Model.nextLyricStyle(style, -1))
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.windowShown

        ButtonGroup {
          options: [
            { value: "small", label: "Small" },
            { value: "medium", label: "Medium" },
            { value: "large", label: "Large" },
            { value: "full", label: "Full screen" }
          ]
          value: root.svc ? root.svc.windowSize : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: false
          onChanged: function(v) { if (root.svc) root.svc.setWindowSize(v) }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Drag the video to move it. Drag a corner to make it any size."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      PanelSeparator {
        foreground: root.foreground
      }

      PanelSectionHeader {
        text: root.svc && root.svc.inList ? "IN THIS LIST" : "JUST PLAYED"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Column {
        width: parent.width
        spacing: 0

        Repeater {
          id: played
          // Always five rows, filled or not.
          model: 5

          Item {
            id: playedRow
            required property int index
            readonly property var modelData: root.svc && root.svc.recent[index] ? root.svc.recent[index] : null
            readonly property string video: modelData && root.svc && !root.svc.inList ? String(modelData.youTubeVideoId || "") : ""
            width: parent.width
            implicitHeight: playedTime.implicitHeight + Style.space(4)

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: -Style.space(4)
              anchors.rightMargin: -Style.space(4)
              visible: playedMouse.containsMouse && playedRow.video !== ""
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, Commons.Color.accent, Commons.Color.urgent)
            }

            Text {
              id: playedTime
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(64)
              textFormat: Text.PlainText
              text: !playedRow.modelData ? " " : playedRow.modelData.playedOn
                ? Qt.formatTime(new Date(playedRow.modelData.playedOn), "h:mm ap") : String(playedRow.index + 1)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              id: playedText
              anchors.left: playedTime.right
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: playedRow.modelData ? playedRow.modelData.title + " \u00b7 " + playedRow.modelData.artist : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            // Click a song to watch its video now.
            MouseArea {
              id: playedMouse
              anchors.fill: parent
              enabled: playedRow.video !== ""
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.svc) root.svc.playVideo(playedRow.video)
            }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      ButtonGroup {
        options: [
          { value: "stations", label: "Stations" },
          { value: "channels", label: "Channels" },
          { value: "sets", label: "Live sets" },
          { value: "playlists", label: "Playlists" }
        ]
        value: root.tab
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: false
        onChanged: function(v) { root.tab = v; root.cursor = -1; stationList.positionViewAtBeginning() }
      }

      TextField {
        id: search
        width: parent.width
        placeholderText: root.tab === "stations" ? "Search stations" : root.tab === "channels" ? "Search channels"
          : root.tab === "sets" ? "Search festivals and live sets" : "Search playlists"
        foreground: root.foreground
        font.family: root.fontFamily
        onTextChanged: { root.query = text; root.cursor = -1 }
        Keys.onEscapePressed: root.close()
        Keys.onDownPressed: root.moveCursor(1)
        Keys.onUpPressed: root.moveCursor(-1)
        onAccepted: root.pickCursor()
      }

      ListView {
        id: stationList
        width: parent.width
        height: Style.space(240)
        clip: true
        model: root.rows
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
          id: stationRow
          required property var modelData
          required property int index
          readonly property bool heading: modelData.kind === "heading"
          readonly property bool current: !heading && root.svc !== null
            && (modelData.list === true ? root.svc.feedOwner === modelData.key : !root.svc.inList && root.svc.station === modelData.key)
          readonly property bool hot: !heading && (rowMouse.containsMouse || heartMouse.containsMouse || root.cursor === index)

          width: ListView.view.width
          height: heading ? Style.space(26) : Style.spacing.popupRowHeight

          Rectangle {
            anchors.fill: parent
            visible: stationRow.hot || stationRow.current
            radius: Style.cornerRadius
            color: stationRow.hot ? Style.hoverFillFor(root.foreground, Commons.Color.accent, Commons.Color.urgent)
              : Style.selectedFillFor(root.foreground, Commons.Color.accent, Commons.Color.urgent)
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: stationRow.heading ? 0 : Style.space(8)
            anchors.right: detail.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: stationRow.heading ? Style.space(3) : 0
            textFormat: Text.PlainText
            text: stationRow.heading ? stationRow.modelData.label.toUpperCase() : stationRow.modelData.label
            color: stationRow.heading ? root.dim : root.foreground
            font.family: root.fontFamily
            font.pixelSize: stationRow.heading ? Style.font.caption : Style.font.body
            font.bold: stationRow.current
            elide: Text.ElideRight
          }

          Text {
            id: detail
            anchors.right: heart.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width * 0.4)
            visible: !stationRow.heading
            textFormat: Text.PlainText
            text: stationRow.heading ? "" : String(stationRow.modelData.detail || "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: !stationRow.heading
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pick(stationRow.modelData.key)
          }

          // A heart to keep the station at the top of the list. Always
          // shown on favourites, and on the row under the pointer.
          Text {
            id: heart
            readonly property bool on: !stationRow.heading && stationRow.modelData.favourite === true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: stationRow.heading || stationRow.modelData.list === true ? 0 : Style.space(18)
            horizontalAlignment: Text.AlignHCenter
            visible: !stationRow.heading && stationRow.modelData.list !== true
            opacity: on || heartMouse.containsMouse ? 1 : stationRow.hot ? 0.45 : 0
            textFormat: Text.PlainText
            text: on ? root.glyphHeart : root.glyphHeartOutline
            color: on ? Commons.Color.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon

            MouseArea {
              id: heartMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.svc) root.svc.toggleFavourite(stationRow.modelData.key)
            }
          }
        }
      }

      Button {
        width: parent.width
        text: root.svc && root.svc.appInstalled ? "Open the FM.video app" : "Install the FM.video app"
        tooltipText: root.svc && root.svc.appInstalled
          ? "The full site in a window of its own"
          : "Adds FM.video to your app launcher and opens it"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: if (root.svc) { root.svc.openApp(); root.close() }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Use the full app for many more features, including charts, dynamic playlists, channels, thousands of hours of full live sets, plus much, much more."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      // The full logo in one colour, as a quiet sign off.
      Image {
        anchors.horizontalCenter: parent.horizontalCenter
        height: Style.space(22)
        width: Math.round(height * 436 / 96)
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * 3
        sourceSize.height: height * 3
        smooth: true
        opacity: footerMouse.containsMouse ? 1 : 0.6
        source: Qt.resolvedUrl(root.lightPanel ? "assets/fmvideo-lockup-black.svg" : "assets/fmvideo-lockup-white.svg")

        // Click it for the full app, like the button and the mark.
        MouseArea {
          id: footerMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.svc) { root.svc.openApp(); root.close() }
        }
      }

      Text {
        width: parent.width
        visible: root.rows.length === 0
        textFormat: Text.PlainText
        text: root.query !== "" ? "Nothing matches" : "Loading"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
