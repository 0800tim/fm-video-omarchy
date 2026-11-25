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

  readonly property string glyphRadio: "\u{F0439}"
  readonly property string glyphPlay: "\u{F040A}"
  readonly property string glyphPause: "\u{F03E4}"
  readonly property string glyphNext: "\u{F04AD}"
  readonly property string glyphPrevious: "\u{F04AE}"

  readonly property bool windowOpen: svc ? svc.windowOpen : false
  readonly property bool playing: svc ? svc.playing : false
  readonly property bool showSongWhenClosed: setting("showSongWhenClosed", true) === true
  readonly property int maxLength: Math.max(12, Number(setting("maxLength", 56)) || 56)

  readonly property string songText: {
    if (!svc || svc.song === "") return ""
    return svc.song + (svc.artist !== "" ? " · " + svc.artist : "")
  }
  readonly property bool showingLyric: svc !== null && svc.barLyrics && svc.lyricLine !== ""
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
      tooltipText: root.opened ? "" : root.tip + "\nClick for stations"
      onPressed: function(b) { root.press(b, function() { root.toggle() }) }
    }

    BarIconButton {
      id: nextButton
      height: parent.height
      bar: root.bar
      text: root.glyphNext
      hasVisualContent: root.windowOpen
      tooltipText: root.opened ? "" : "Next song"
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
  readonly property var rows: svc ? Model.stationRows(svc.stations, svc.country, query) : []

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
    svc.setStation(key)
    root.close()
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
    anchorItem: root.vertical ? uprightButton : label.visible ? label : playButton
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
          : !root.windowOpen ? "ON AIR NOW" : root.playing ? "PLAYING" : "PAUSED"
        foreground: root.foreground
        fontFamily: root.fontFamily
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

      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: root.songText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.showingLyric
        textFormat: Text.PlainText
        text: root.svc ? root.svc.lyricLine : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.italic: true
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Row {
        spacing: Style.space(8)
        visible: root.windowOpen

        PanelActionButton {
          iconText: root.glyphPrevious
          tooltipText: "Previous song"
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
          tooltipText: "Next song"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.svc.next()
        }
      }

      PanelSeparator { foreground: root.foreground }

      SwitchRow {
        label: "Video window"
        checked: root.windowOpen
        onToggled: if (root.svc) root.svc.toggleWindow()
      }
      SwitchRow {
        label: "Lyrics in the bar"
        checked: root.svc ? root.svc.barLyrics : false
        onToggled: if (root.svc) root.svc.setBarLyrics(!root.svc.barLyrics)
      }
      SwitchRow {
        label: "Lyrics on the video"
        checked: root.svc ? root.svc.videoLyrics : false
        onToggled: if (root.svc) root.svc.setVideoLyrics(!root.svc.videoLyrics)
      }

      PanelSeparator {
        foreground: root.foreground
        visible: played.count > 0
      }

      PanelSectionHeader {
        text: "JUST PLAYED"
        visible: played.count > 0
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: played.count > 0

        Repeater {
          id: played
          model: root.svc ? root.svc.recent : []

          Item {
            id: playedRow
            required property var modelData
            width: parent.width
            implicitHeight: playedText.implicitHeight

            Text {
              id: playedTime
              anchors.left: parent.left
              width: Style.space(64)
              textFormat: Text.PlainText
              text: Qt.formatTime(new Date(playedRow.modelData.playedOn), "h:mm ap")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              id: playedText
              anchors.left: playedTime.right
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: playedRow.modelData.title + " · " + playedRow.modelData.artist
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      TextField {
        id: search
        width: parent.width
        placeholderText: "Search stations"
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
          readonly property bool current: !heading && root.svc !== null && root.svc.station === modelData.key
          readonly property bool hot: !heading && (rowMouse.containsMouse || root.cursor === index)

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
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
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
        }
      }

      Text {
        width: parent.width
        visible: root.rows.length === 0
        textFormat: Text.PlainText
        text: root.svc && root.svc.stations.length === 0 ? "Loading stations" : "No stations match"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
