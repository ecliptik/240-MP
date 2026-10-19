import QtQuick

// Live TV player. A slimmed sibling of Player.qml — live channels have no
// resume/duration/seek/autoplay-next semantics, so this drops all of that. It
// tunes the selected channel, hands the HLS stream to mpv, and keeps the tuner
// alive with a timeline ping. Channel up/down (Page Up/Down, or a remote's
// Channel keys) steps through the lineup in place: the Qt app owns the keyboard
// and relays the rest to mpv, so these two never reach mpv.
FocusScope {
    id: livePlayerRoot

    property var navParams: ({})

    signal navigateTo(string path, var params)
    signal goBack()

    // The channel to watch: { channelId, number, title }.
    property var    channel:   navParams.channel || ({})
    // The lineup and this channel's place in it, for channel up/down.
    property var    channels:  navParams.channels || []
    property int    chIndex:   navParams.index !== undefined ? navParams.index : -1
    property bool   switching: false
    // Plex module setting live_stream_url, e.g. "http://tuner:8409/iptv/channel/{number}.ts": play the channel
    // straight from the tuner that feeds Plex's DVR (an HDHomeRun-style source such as ErsatzTV) instead of
    // having Plex tune it and transcode/remux it into HLS. Plex still supplies the channel list. Unset = via Plex.
    property string directTemplate: (appCore.get_setting("com.240mp.plex", "live_stream_url") || "").toString()
    readonly property bool direct: directTemplate !== "" && channel.number !== undefined && channel.number !== ""

    property string sessionId:     ""
    property string streamUrl:     ""
    property string plexToken:     ""
    property bool   playbackStarted: false
    property bool   exiting:        false

    focus: true

    function newSessionId() {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var id = ""
        for (var i = 0; i < 12; i++) id += chars[Math.floor(Math.random() * chars.length)]
        return id
    }

    // Tune the channel. tune_channel resolves asynchronously through
    // onStreamUrlReady, which loads the resulting HLS stream into mpv.
    function tune() {
        if (!channel.channelId) { goBack(); return }
        playbackStarted = false
        sessionId = newSessionId()
        console.log("[LivePlayer] tune " + (channel.number || "?") + (direct ? " (direct)" : " (via Plex)"))
        if (direct) {
            streamUrl = directTemplate.replace("{number}", String(channel.number))
            mpvController.loadAndPlay(streamUrl, 0, 0, -1, [], [], false, -1, 0.0, "")
            return
        }
        plexBackend.tune_channel(channel.channelId, sessionId)
    }

    // Step to the next/previous channel in place: stop this one and tune the new one once mpv reports it has
    // ended. Direct streams take every press, even mid-tune: presses add up, the TUNING screen shows the target,
    // and only the last channel is tuned. Through Plex one tune runs at a time (a Plex tune in flight can't be
    // cancelled), so presses before the picture are ignored there. A remote's repeated code (a second press
    // within 300 ms) counts once.
    property double lastChannelKey: 0
    function switchChannel(step) {
        if (exiting || channels.length < 2 || chIndex < 0) return
        var now = Date.now()
        if (now - lastChannelKey < 300) return
        lastChannelKey = now
        if (!direct && (switching || !playbackStarted)) return
        chIndex = (chIndex + step + channels.length) % channels.length
        channel = channels[chIndex]
        if (switching) return              // already stopping; the retune uses the latest channel
        switching = true
        if (!direct) plexBackend.stop_live_session(sessionId)
        mpvController.stop()
        if (direct) switchFallback.restart()
    }

    // If mpv wasn't running (still starting, or failed), no playbackEnded arrives: tune anyway.
    Timer {
        id: switchFallback
        interval: 2500
        onTriggered: if (livePlayerRoot.switching) {
            livePlayerRoot.switching = false
            livePlayerRoot.tune()
        }
    }

    function teardown() {
        if (exiting) return
        exiting = true
        if (!direct) plexBackend.stop_live_session(sessionId)
        mpvController.stop()
    }

    // Forward keys to mpv (the same set Player.qml forwards) so its OSC works on
    // the Pi, where the Qt app owns the keyboard and relays via sendKey. On desktop
    // mpv has focus and handles these directly. Up/Down drive the OSC here, not
    // channel changes — to switch channels the user exits back to the channel list.
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            // Quit mpv; onPlaybackEnded drives the teardown + goBack.
            mpvController.sendKey("ESC")
            event.accepted = true
        } else if (event.key === Qt.Key_PageUp || event.key === Qt.Key_ChannelUp) {
            if (!event.isAutoRepeat) switchChannel(1)
            event.accepted = true
        } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_ChannelDown) {
            if (!event.isAutoRepeat) switchChannel(-1)
            event.accepted = true
        } else if (event.key === Qt.Key_Backspace) {
            mpvController.sendKey("BS")
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            mpvController.sendKey("UP")
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            mpvController.sendKey("DOWN")
            event.accepted = true
        } else if (event.key === Qt.Key_Left) {
            mpvController.sendKey("LEFT")
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            mpvController.sendKey("RIGHT")
            event.accepted = true
        } else if (event.key === Qt.Key_Space) {
            mpvController.sendKey("SPACE")
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            mpvController.sendKey("ENTER")
            event.accepted = true
        }
    }

    Connections {
        target: plexBackend

        function onStreamUrlReady(url, plexToken) {
            livePlayerRoot.streamUrl = url
            livePlayerRoot.plexToken = plexToken
            // Live always transcodes (HLS): no separate audio/sub tracks to pick.
            mpvController.loadAndPlay(url, 0, 0, -1, [], [], false, -1, 0.0, plexToken)
        }

        function onErrorOccurred(msg) {
            console.log("[LivePlayer] Backend error: " + msg)
            // A tune/stream failure leaves nothing playing — bail back to the list.
            if (!playbackStarted) { teardown(); goBack() }
        }
    }

    Connections {
        target: mpvController

        function onPositionChanged(ms) {
            if (ms > 0) livePlayerRoot.playbackStarted = true
        }

        function onPlaybackEnded(finalPositionMs, finalDurationMs, reason) {
            // A channel switch: tune the new channel instead of leaving.
            if (livePlayerRoot.switching) {
                livePlayerRoot.switching = false
                switchFallback.stop()
                livePlayerRoot.tune()
                return
            }
            // Any other end (user quit, stream failure, or rare eof) tears down the
            // tuner and returns to the channel list.
            teardown()
            goBack()
        }
    }

    // Keep-alive: Plex reaps the DVR grab (and then 404s the stream) if the client
    // stops reporting the timeline. Ping from the moment we're tuned — not gated on
    // playbackStarted — since the grab is rolling before mpv reports its first frame.
    // update_live_timeline no-ops until a channel is tuned.
    Timer {
        interval: 8000
        repeat:   true
        running:  !livePlayerRoot.direct   // a direct stream has no Plex grab to keep alive
        onTriggered: plexBackend.update_live_timeline("playing")
    }

    Component.onCompleted: tune()

    // Black backdrop + loading text, shown until mpv's window takes over (mirrors
    // Player.qml).
    Rectangle {
        anchors.fill: parent
        color: "black"

        Text {
            text: "TUNING " + ((livePlayerRoot.channel.number
                                 ? livePlayerRoot.channel.number + "  " : "")
                               + (livePlayerRoot.channel.title || "")) + "..."
            color: "white"
            font.family: root.globalFont
            font.capitalization: Font.AllUppercase
            anchors.centerIn: parent
            font.pixelSize: root.sh * 0.05 //24
            visible: !livePlayerRoot.playbackStarted
        }
    }
}
