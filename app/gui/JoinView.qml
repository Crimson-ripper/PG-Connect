// PG Connect: start screen. The player enters a session code (or opens a
// productify://connect?code=... link) and everything else is automatic.
// 0.2.0: a gaming-app shell in Productify's white and lime: a left icon rail (Play, Session,
// Settings, Help), angular tiles, a scrolling launcher row and a player-chosen accent colour.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import QtCore

import ComputerManager 1.0

Item {
    id: joinView
    objectName: ""  // no toolbar title: the page heading says it

    // Productify palette (productify-node v2/app/src/style.css); the accent is the player's choice
    readonly property color ink: "#101112"
    readonly property color paper: "#F5F6F1"
    readonly property color line: "#E3E4DE"
    readonly property color muted: "#62635C"
    readonly property color lime: "#C8F04C"
    readonly property color accent: look.accent
    readonly property string uiFont: "Segoe UI"
    readonly property int motion: look.reduceMotion ? 0 : 1

    // Saved on this PC (GX Control-style customisation)
    Settings {
        id: look
        category: "PGConnectLook"
        property color accent: "#C8F04C"
        property bool pattern: true
        property bool reduceMotion: false
    }
    readonly property var accentPresets: [
        { name: qsTr("Productify lime"), color: "#C8F04C" },
        { name: qsTr("Cyan"), color: "#3FE0E8" },
        { name: qsTr("Magenta"), color: "#FF4FD8" },
        { name: qsTr("Orange"), color: "#FF8A3D" },
        { name: qsTr("Red"), color: "#FF4D5E" },
        { name: qsTr("Violet"), color: "#9B6BFF" }
    ]

    property int page: 0          // 0 Play, 1 Session, 2 Settings, 3 Help
    property var info: ({})       // joinLauncher.sessionInfo()
    property double nowMs: Date.now()

    function startJoin() {
        if (joinLauncher.busy) {
            return
        }
        var code = joinLauncher.normalizeCode(codeField.text)
        if (code === "") {
            errorLabel.text = qsTr("Session codes are 6 to 16 letters and numbers, like R929RSEQ. Copy it from the Gamezone page.")
            return
        }
        errorLabel.text = ""
        stageLabel.text = ""
        joinLauncher.join(code, ComputerManager)
    }

    // 0.1.8: launcher picker (Steam, Epic, ...), shown after pairing and when the player leaves a game
    property bool picking: false
    property var appChoices: []
    property string currentApp: ""

    function onStageChanged(text) {
        stageLabel.text = text
        if (text !== "") {
            picking = false
        }
    }

    // 0.1.9: balance is zero and the machine shuts down soon unless the player tops up
    property string creditWarning: ""
    function onCreditWarning(text) {
        creditWarning = text
    }

    function onAppChoicesReady(choices, current) {
        // last played first, so Enter / A starts it straight away
        var ordered = choices.slice()
        var i = ordered.indexOf(current)
        if (i > 0) {
            ordered.splice(i, 1)
            ordered.unshift(current)
        }
        appChoices = ordered
        currentApp = current
        errorLabel.text = ""
        picking = true
        page = 0
        Qt.callLater(function() { launcherRow.currentIndex = 0; launcherRow.forceActiveFocus() })
    }

    // Logos are the launchers' own (shown as "works with" marks); a launcher without one gets a monogram.
    function launcherMeta(name) {
        var known = {
            "Steam": { logo: "qrc:/res/launcher-steam.svg", tile: "#1B2838",
                       description: qsTr("Your Steam library, cloud saves and friends") },
            "Epic Games": { logo: "qrc:/res/launcher-epic.svg", tile: "#0074E4",
                            description: qsTr("Your Epic Games library, through the Heroic launcher") }
        }
        return known[name] || { logo: "", tile: "#2A2D33", description: qsTr("Open %1").arg(name) }
    }

    function openLauncher(name) {
        picking = false
        joinLauncher.chooseApp(name)
    }

    function clock(ms) {
        var s = Math.max(0, Math.floor(ms / 1000))
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
        return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (sec < 10 ? "0" : "") + sec
    }

    function onFailed(message) {
        stageLabel.text = ""
        errorLabel.text = message
        page = 0
        console.error(message)
    }

    function onSessionCreated(appName, session) {
        var component = Qt.createComponent("StreamSegue.qml")
        var segue = component.createObject(stackView, {
            "appName": appName,
            "session": session,
            // A Gamezone session has exactly one app: close when the stream ends.
            "quitAfter": true,
            // ...unless the network dropped: then reconnect (PG Connect 0.1.6)
            "onDropped": function() { joinLauncher.reconnect() },
            // ...and leaving a game (Ctrl+Alt+Shift+Q) goes back to the launcher picker (0.1.8)
            "onEnded": joinLauncher.canSwitchApps() ? function() { joinLauncher.backToPicker() } : null
        })
        stackView.push(segue)
    }

    function onAppQuitRequired(appName) {
        quitAppDialog.appName = appName
        quitAppDialog.open()
    }

    function newer(a, b) { // "0.1.7" > "0.1.6"
        var x = a.split("."), y = b.split(".")
        for (var i = 0; i < Math.max(x.length, y.length); i++) {
            var d = (parseInt(x[i]) || 0) - (parseInt(y[i]) || 0)
            if (d !== 0) return d > 0
        }
        return false
    }

    function checkForUpdate() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var rel = JSON.parse(xhr.responseText)
                var latest = String(rel.tag_name || "").replace(/^pfy-v/, "")
                if (latest && newer(latest, Qt.application.version)) {
                    updateBanner.url = "https://www.productifynow.com/gamezone"
                    updateBanner.latest = latest
                }
            } catch (e) { /* no banner on any problem */ }
        }
        xhr.open("GET", "https://api.github.com/repos/Crimson-ripper/PG-Connect/releases/latest")
        xhr.send()
    }

    Component.onCompleted: {
        checkForUpdate()
        joinLauncher.stageChanged.connect(onStageChanged)
        joinLauncher.failed.connect(onFailed)
        joinLauncher.sessionCreated.connect(onSessionCreated)
        joinLauncher.appQuitRequired.connect(onAppQuitRequired)
        joinLauncher.appChoicesReady.connect(onAppChoicesReady)
        joinLauncher.creditWarning.connect(onCreditWarning)
        joinLauncher.sessionInfoChanged.connect(function() { info = joinLauncher.sessionInfo() })
        info = joinLauncher.sessionInfo()
    }

    StackView.onActivated: {
        if (!picking) {
            codeField.forceActiveFocus()
        }
        if (joinLauncher.initialCode !== "" && !joinLauncher.busy && codeField.text === "") {
            // Opened from a productify://connect link
            codeField.text = joinLauncher.initialCode
            startJoin()
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: info.connected === true
        onTriggered: nowMs = Date.now()
    }

    // ---------- building blocks ----------

    // Angular panel: square corners with the top-right and bottom-left cut, the shell's signature shape
    component CutRect: Shape {
        id: cut
        property color fill: "#FFFFFF"
        property color stroke: "transparent"
        property real strokeWidth: 0
        property real notch: 14
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: cut.fill
            strokeColor: cut.stroke
            strokeWidth: cut.strokeWidth
            joinStyle: ShapePath.MiterJoin
            startX: 0; startY: 0
            PathLine { x: cut.width - cut.notch; y: 0 }
            PathLine { x: cut.width; y: cut.notch }
            PathLine { x: cut.width; y: cut.height }
            PathLine { x: cut.notch; y: cut.height }
            PathLine { x: 0; y: cut.height - cut.notch }
            PathLine { x: 0; y: 0 }
        }
    }

    // Accent button with the cut shape
    component AccentButton: AbstractButton {
        id: btn
        property color accentColor: "#C8F04C"
        property int motionScale: 1
        property bool primary: true
        implicitHeight: 46
        implicitWidth: btnLabel.implicitWidth + 48
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        opacity: enabled ? 1 : 0.45
        scale: btn.down ? 0.98 : 1
        Behavior on scale { NumberAnimation { duration: 90 * motionScale } }
        background: CutRect {
            notch: 10
            fill: btn.primary ? (btn.hovered ? Qt.darker(accentColor, 1.06) : accentColor)
                              : (btn.hovered ? "#E9EAE3" : "#F5F6F1")
            stroke: btn.visualFocus ? "#101112" : "transparent"
            strokeWidth: btn.visualFocus ? 2 : 0
        }
        contentItem: Label {
            id: btnLabel
            text: btn.text
            font.family: "Segoe UI"
            font.pixelSize: 15
            font.weight: Font.Bold
            color: "#101112"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Left rail item
    component RailButton: AbstractButton {
        id: rb
        property color accentColor: "#C8F04C"
        property int motionScale: 1
        property int currentPage: 0
        signal pick(int target)
        property string glyph: ""
        property int target: 0
        readonly property bool active: currentPage === target
        implicitWidth: 76
        implicitHeight: 70
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        opacity: enabled ? 1 : 0.35
        Accessible.name: text
        onClicked: pick(target)
        property string hint: ""
        ToolTip.visible: hovered && hint !== ""
        ToolTip.text: hint
        ToolTip.delay: 400
        background: Item {
            Rectangle {  // active marker
                width: 4
                height: rb.active ? 36 : 0
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                color: accentColor
                Behavior on height { NumberAnimation { duration: 160 * motionScale; easing.type: Easing.OutCubic } }
            }
            CutRect {
                width: 40
                height: 40
                anchors.horizontalCenter: parent.horizontalCenter
                y: 6
                notch: 8
                fill: rb.active ? accentColor : (rb.hovered ? "#E9EAE3" : "transparent")
                stroke: rb.visualFocus ? "#101112" : "transparent"
                strokeWidth: rb.visualFocus ? 2 : 0
            }
        }
        contentItem: Item {
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 6 + (40 - height) / 2
                text: rb.glyph
                font.family: "Segoe UI Symbol"
                font.pixelSize: 18
                color: "#101112"
            }
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 50
                text: rb.text
                font.family: "Segoe UI"
                font.pixelSize: 11
                font.weight: rb.active ? Font.Bold : Font.Normal
                color: "#101112"
            }
        }
    }

    // Small fact on the Session currentPage
    component Fact: ColumnLayout {
        property string label: ""
        property string value: ""
        spacing: 2
        Label { text: label; font.family: "Segoe UI"; font.pixelSize: 13; color: "#62635C" }
        Label { text: value === "" ? "—" : value; font.family: "Segoe UI"; font.pixelSize: 22; font.weight: Font.DemiBold; color: "#101112" }
    }

    // ---------- background ----------

    Rectangle {
        anchors.fill: parent
        color: "#FFFFFF"
    }

    // Optional pattern: thin diagonal accent strokes in the far corner (Settings > Background)
    Canvas {
        id: pattern
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Math.min(parent.width * 0.55, 620)
        height: Math.min(parent.height * 0.6, 420)
        visible: look.pattern
        opacity: 0.55
        property color c: accent
        onCChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = c
            ctx.lineWidth = 2
            for (var x = 0; x < width + height; x += 26) {
                ctx.globalAlpha = Math.min(1, x / (width + height)) * 0.6
                ctx.beginPath()
                ctx.moveTo(x, height)
                ctx.lineTo(x + height * 0.6, 0)
                ctx.stroke()
            }
        }
    }

    // ---------- shell ----------

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Left rail
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 76
            color: paper

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: 18
                anchors.bottomMargin: 14
                spacing: 6

                CutRect {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.bottomMargin: 14
                    width: 40
                    height: 40
                    notch: 9
                    fill: accent
                    Label {
                        anchors.centerIn: parent
                        text: "P"
                        font.family: uiFont
                        font.pixelSize: 20
                        font.weight: Font.Black
                        color: ink
                    }
                }

                RailButton { text: qsTr("Play"); hint: qsTr("Join a session and choose a launcher"); glyph: "▶"; target: 0; accentColor: accent; motionScale: motion; currentPage: page; onPick: function(t) { page = t } }
                RailButton { text: qsTr("Session"); hint: qsTr("Your machine, time and credit"); glyph: "◷"; target: 1; accentColor: accent; motionScale: motion; currentPage: page; onPick: function(t) { page = t } }
                RailButton { text: qsTr("Customise"); hint: qsTr("Customise colours and motion"); glyph: "⚙"; target: 2; accentColor: accent; motionScale: motion; currentPage: page; onPick: function(t) { page = t } }
                RailButton { text: qsTr("Help"); hint: qsTr("Shortcuts and support"); glyph: "?"; target: 3; accentColor: accent; motionScale: motion; currentPage: page; onPick: function(t) { page = t } }

                Item { Layout.fillHeight: true }

                // connection light
                ColumnLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 4
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        width: 10; height: 10; radius: 5
                        color: info.connected ? "#3BB273" : (joinLauncher.busy ? "#E8B021" : "#B8B9B2")
                        SequentialAnimation on opacity {
                            running: joinLauncher.busy && !info.connected && motion === 1
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 600 }
                            NumberAnimation { to: 1; duration: 600 }
                        }
                    }
                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: info.connected ? qsTr("Online") : (joinLauncher.busy ? qsTr("Joining") : qsTr("Offline"))
                        font.family: uiFont
                        font.pixelSize: 11
                        color: muted
                    }
                }
            }
        }

        // Pages
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: page

            // ===== 0: Play =====
            Item {
                Flickable {
                    id: playFlick
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: playCol.implicitHeight + 64
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: playCol
                        x: 40
                        y: 28
                        width: playFlick.width - 80
                        spacing: 16

                        // 0.1.7: players kept joining with old versions (missing fixes); say when a newer one exists.
                        Rectangle {
                            id: updateBanner
                            property string latest: ""
                            property string url: ""
                            visible: latest !== ""
                            Layout.fillWidth: true
                            implicitHeight: updateText.implicitHeight + 20
                            color: Qt.rgba(accent.r, accent.g, accent.b, 0.25)
                            Label {
                                id: updateText
                                anchors.fill: parent
                                anchors.margins: 10
                                wrapMode: Text.WordWrap
                                textFormat: Text.StyledText
                                color: ink
                                font.family: uiFont
                                font.pixelSize: 14
                                text: qsTr("PG Connect %1 is available, with fixes for Gamezone. <a href=\"%2\">Download it</a>, install it over this version, then join again.").arg(updateBanner.latest).arg(updateBanner.url)
                                onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                            }
                        }

                        Rectangle {
                            visible: creditWarning !== ""
                            Layout.fillWidth: true
                            implicitHeight: creditText.implicitHeight + 20
                            color: "#FDECEA"
                            Label {
                                id: creditText
                                anchors.fill: parent
                                anchors.margins: 10
                                wrapMode: Text.WordWrap
                                textFormat: Text.StyledText
                                color: ink
                                font.family: uiFont
                                font.pixelSize: 14
                                text: creditWarning.replace(/\n/g, " ") + " <a href=\"https://www.productifynow.com/pricing\">Top up</a>"
                                onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                            }
                        }

                        // ----- join (not connected yet) -----
                        ColumnLayout {
                            visible: !picking
                            Layout.fillWidth: true
                            Layout.maximumWidth: 520
                            spacing: 14

                            Label {
                                text: qsTr("Productify Gamezone")
                                font.family: uiFont
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                                color: muted
                            }
                            Label {
                                Layout.fillWidth: true
                                text: qsTr("Join your game")
                                font.family: uiFont
                                font.pixelSize: 40
                                font.weight: Font.Black
                                font.letterSpacing: -0.8
                                color: ink
                            }
                            Label {
                                Layout.fillWidth: true
                                text: qsTr("Enter the session code from your Productify session page. PG Connect connects, pairs and opens your launcher for you.")
                                font.family: uiFont
                                font.pixelSize: 16
                                lineHeight: 1.35
                                wrapMode: Text.Wrap
                                color: ink
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.topMargin: 10
                                implicitHeight: 64
                                CutRect {
                                    anchors.fill: parent
                                    notch: 12
                                    fill: paper
                                    stroke: codeField.activeFocus ? accent : "transparent"
                                    strokeWidth: codeField.activeFocus ? 3 : 0
                                }
                                TextField {
                                    id: codeField
                                    anchors.fill: parent
                                    enabled: !joinLauncher.busy
                                    font.family: uiFont
                                    font.pixelSize: 26
                                    font.weight: Font.Bold
                                    font.letterSpacing: 3
                                    font.capitalization: Font.AllUppercase
                                    color: ink
                                    horizontalAlignment: TextInput.AlignHCenter
                                    verticalAlignment: TextInput.AlignVCenter
                                    inputMethodHints: Qt.ImhUppercaseOnly | Qt.ImhNoPredictiveText
                                    maximumLength: 24
                                    selectByMouse: true
                                    Accessible.name: qsTr("Session code")
                                    background: Item {}
                                    Text {
                                        anchors.centerIn: parent
                                        visible: codeField.text.length === 0
                                        text: qsTr("Session code, e.g. R929RSEQ")
                                        color: "#9C9D96"
                                        font.family: uiFont
                                        font.pixelSize: 18
                                        Accessible.ignored: true
                                    }
                                    Keys.onReturnPressed: startJoin()
                                    Keys.onEnterPressed: startJoin()
                                }
                            }

                            AccentButton {
 accentColor: accent
 motionScale: motion
                                id: joinButton
                                Layout.fillWidth: true
                                implicitHeight: 52
                                enabled: !joinLauncher.busy && codeField.text.length > 0
                                text: joinLauncher.busy ? qsTr("Connecting…") : qsTr("Join  ▶")
                                onClicked: startJoin()
                                Accessible.name: text
                            }
                        }

                        // ----- launcher picker (connected) -----
                        ColumnLayout {
                            visible: picking
                            Layout.fillWidth: true
                            spacing: 18

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 16
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    Label {
                                        text: info.gpu ? qsTr("Connected · %1 in %2").arg(info.gpu).arg(info.location) : qsTr("Connected")
                                        font.family: uiFont
                                        font.pixelSize: 15
                                        font.weight: Font.DemiBold
                                        color: muted
                                    }
                                    Label {
                                        text: qsTr("Choose a launcher")
                                        font.family: uiFont
                                        font.pixelSize: 40
                                        font.weight: Font.Black
                                        font.letterSpacing: -0.8
                                        color: ink
                                    }
                                }
                                AccentButton {
 accentColor: accent
 motionScale: motion
                                    Layout.alignment: Qt.AlignRight | Qt.AlignTop
                                    primary: false
                                    text: qsTr("Disconnect")
                                    onClicked: {
                                        picking = false
                                        joinLauncher.disconnectFromMachine()
                                    }
                                    Accessible.name: qsTr("Disconnect from the gaming machine")
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 300
                                    ToolTip.text: qsTr("Leave this machine. Your session keeps running until you end it on the website.")
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("Sign in with your own account and play the games you own. You can switch launcher at any time.")
                                font.family: uiFont
                                font.pixelSize: 16
                                wrapMode: Text.Wrap
                                color: ink
                            }

                            Item {
                                id: rowArea
                                readonly property bool scrolls: launcherRow.count > 3
                                Layout.fillWidth: true
                                Layout.topMargin: 2
                                implicitHeight: 332

                                ListView {
                                    id: launcherRow
                                    anchors.fill: parent
                                    anchors.leftMargin: rowArea.scrolls ? 60 : 8
                                    anchors.rightMargin: rowArea.scrolls ? 60 : 8
                                    orientation: ListView.Horizontal
                                    spacing: 22
                                    clip: false
                                    model: appChoices
                                    keyNavigationEnabled: true
                                    focus: picking
                                    boundsBehavior: Flickable.StopAtBounds
                                    highlightMoveDuration: 220 * motion
                                    preferredHighlightBegin: 0
                                    preferredHighlightEnd: width
                                    highlightRangeMode: ListView.ApplyRange
                                    readonly property real tileWidth: count <= 3
                                        ? (width - spacing * (count - 1)) / Math.max(1, count)
                                        : Math.max(240, (width - spacing * 2) / 3)
                                    Keys.onReturnPressed: if (currentIndex >= 0) openLauncher(appChoices[currentIndex])
                                    Keys.onEnterPressed: if (currentIndex >= 0) openLauncher(appChoices[currentIndex])
                                    Keys.onSpacePressed: if (currentIndex >= 0) openLauncher(appChoices[currentIndex])

                                    delegate: AbstractButton {
                                        id: tile
                                        readonly property var meta: launcherMeta(modelData)
                                        readonly property bool lit: (ListView.isCurrentItem && launcherRow.activeFocus) || hovered
                                        width: launcherRow.tileWidth
                                        height: 300
                                        y: 16
                                        hoverEnabled: true
                                        focusPolicy: Qt.NoFocus
                                        scale: tile.down ? 0.98 : (tile.lit ? 1.035 : 1.0)
                                        z: tile.lit ? 2 : 0
                                        Behavior on scale { NumberAnimation { duration: 170 * motion; easing.type: Easing.OutCubic } }
                                        Accessible.name: qsTr("Play %1").arg(modelData)
                                        onHoveredChanged: if (hovered) launcherRow.currentIndex = index
                                        onClicked: openLauncher(modelData)
                                        ToolTip.visible: hovered
                                        ToolTip.delay: 700
                                        ToolTip.text: qsTr("Open %1 on your gaming machine").arg(modelData)

                                        background: Item {
                                            // soft accent glow behind the selected tile
                                            CutRect {
                                                x: -8; y: -8
                                                width: parent.width + 16
                                                height: parent.height + 16
                                                notch: 26
                                                fill: Qt.rgba(accent.r, accent.g, accent.b, 0.35)
                                                opacity: tile.lit ? 1 : 0
                                                Behavior on opacity { NumberAnimation { duration: 170 * motion } }
                                            }
                                            CutRect {
                                                anchors.fill: parent
                                                notch: 20
                                                fill: tile.meta.tile
                                                stroke: tile.lit ? accent : "transparent"
                                                strokeWidth: tile.lit ? 3 : 0
                                            }
                                        }

                                        contentItem: ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: 26
                                            spacing: 0

                                            RowLayout {
                                                Layout.fillWidth: true
                                                Item {
                                                    Layout.preferredWidth: 92
                                                    Layout.preferredHeight: 92
                                                    Rectangle {  // logo plate keeps dark logos readable on any tile
                                                        anchors.fill: parent
                                                        radius: 46
                                                        color: "#FFFFFF"
                                                        visible: tile.meta.logo !== ""
                                                        Image {
                                                            anchors.fill: parent
                                                            anchors.margins: 12
                                                            source: tile.meta.logo
                                                            sourceSize.width: 160
                                                            sourceSize.height: 160
                                                            fillMode: Image.PreserveAspectFit
                                                            smooth: true
                                                            Accessible.ignored: true
                                                        }
                                                    }
                                                    CutRect {  // a launcher without a logo yet gets a monogram
                                                        anchors.fill: parent
                                                        visible: tile.meta.logo === ""
                                                        notch: 14
                                                        fill: accent
                                                        Label {
                                                            anchors.centerIn: parent
                                                            text: modelData.charAt(0)
                                                            color: ink
                                                            font.family: uiFont
                                                            font.pixelSize: 42
                                                            font.weight: Font.Black
                                                        }
                                                    }
                                                }
                                                Item { Layout.fillWidth: true }
                                                Rectangle {
                                                    visible: modelData === currentApp
                                                    Layout.alignment: Qt.AlignTop
                                                    color: accent
                                                    implicitWidth: lastLabel.implicitWidth + 18
                                                    implicitHeight: 26
                                                    Label {
                                                        id: lastLabel
                                                        anchors.centerIn: parent
                                                        text: qsTr("Last played")
                                                        font.family: uiFont
                                                        font.pixelSize: 13
                                                        font.weight: Font.DemiBold
                                                        color: ink
                                                    }
                                                }
                                            }

                                            Item { Layout.fillHeight: true }

                                            Label {
                                                Layout.fillWidth: true
                                                text: modelData
                                                font.family: uiFont
                                                font.pixelSize: 30
                                                font.weight: Font.Black
                                                font.letterSpacing: -0.4
                                                color: "#FFFFFF"
                                                elide: Text.ElideRight
                                            }
                                            Label {
                                                Layout.fillWidth: true
                                                Layout.topMargin: 4
                                                text: tile.meta.description
                                                font.family: uiFont
                                                font.pixelSize: 14
                                                wrapMode: Text.Wrap
                                                maximumLineCount: 2
                                                elide: Text.ElideRight
                                                color: "#E6FFFFFF"
                                            }
                                            CutRect {
                                                Layout.topMargin: 18
                                                Layout.preferredWidth: 120
                                                Layout.preferredHeight: 42
                                                notch: 10
                                                fill: tile.lit ? accent : "#33FFFFFF"
                                                Label {
                                                    anchors.centerIn: parent
                                                    text: qsTr("▶  Play")
                                                    font.family: uiFont
                                                    font.pixelSize: 15
                                                    font.weight: Font.Bold
                                                    color: tile.lit ? ink : "#FFFFFF"
                                                }
                                            }
                                        }
                                    }
                                }

                                // edge arrows when there are more tiles than fit
                                Repeater {
                                    model: [ { dir: -1 }, { dir: 1 } ]
                                    delegate: AbstractButton {
                                        readonly property bool more: modelData.dir < 0 ? !launcherRow.atXBeginning : !launcherRow.atXEnd
                                        visible: rowArea.scrolls
                                        enabled: more
                                        opacity: more ? 1 : 0.3
                                        width: 44
                                        height: 44
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: modelData.dir < 0 ? 0 : parent.width - width
                                        ToolTip.visible: hovered
                                        ToolTip.delay: 300
                                        ToolTip.text: modelData.dir < 0 ? qsTr("Previous launchers") : qsTr("More launchers")
                                        z: 5
                                        hoverEnabled: true
                                        Accessible.name: modelData.dir < 0 ? qsTr("Previous launchers") : qsTr("More launchers")
                                        onClicked: launcherRow.currentIndex = Math.max(0, Math.min(launcherRow.count - 1,
                                                       launcherRow.currentIndex + modelData.dir * 2))
                                        background: CutRect { notch: 10; fill: hovered ? Qt.darker(accent, 1.08) : accent }
                                        contentItem: Label {
                                            text: modelData.dir < 0 ? "◀" : "▶"
                                            font.family: "Segoe UI Symbol"
                                            font.pixelSize: 16
                                            color: ink
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                textFormat: Text.StyledText
                                text: qsTr("<b>← →</b> choose   <b>Enter</b> play   ·   In game, <b>Ctrl + Alt + Shift + Q</b> brings you back here to switch.")
                                font.family: uiFont
                                font.pixelSize: 14
                                color: muted
                            }
                        }

                        // ----- progress and errors -----
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 520
                            visible: joinLauncher.busy && !picking
                            spacing: 10

                            BusyIndicator {
                                running: joinLauncher.busy
                                Layout.preferredHeight: 30
                                Layout.preferredWidth: 30
                            }
                            Label {
                                id: stageLabel
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                font.family: uiFont
                                font.pixelSize: 15
                                color: ink
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.maximumWidth: picking ? 100000 : 520
                            visible: errorLabel.text !== ""
                            implicitHeight: errorLabel.implicitHeight + 24
                            color: "#FDECEA"
                            Label {
                                id: errorLabel
                                anchors.fill: parent
                                anchors.margins: 12
                                wrapMode: Text.Wrap
                                font.family: uiFont
                                font.pixelSize: 14
                                color: "#8A2B2B"
                            }
                        }
                    }
                }
            }

            // ===== 1: Session =====
            Item {
                ColumnLayout {
                    x: 40
                    y: 32
                    width: Math.min(parent.width - 80, 760)
                    spacing: 22

                    Label {
                        text: qsTr("Session")
                        font.family: uiFont
                        font.pixelSize: 40
                        font.weight: Font.Black
                        font.letterSpacing: -0.8
                        color: ink
                    }

                    Label {
                        visible: info.connected !== true
                        Layout.fillWidth: true
                        text: qsTr("Not connected. Join a session from Play to see your machine, time and credit here.")
                        font.family: uiFont
                        font.pixelSize: 16
                        wrapMode: Text.Wrap
                        color: ink
                    }

                    // zero-balance countdown
                    CutRect {
                        visible: info.connected === true && info.graceEndsMs > 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: 96
                        notch: 14
                        fill: "#FDECEA"
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 18
                            spacing: 2
                            Label {
                                text: qsTr("Balance is zero · machine shuts down in %1").arg(clock(info.graceEndsMs - nowMs))
                                font.family: uiFont; font.pixelSize: 20; font.weight: Font.Bold; color: "#8A2B2B"
                            }
                            Label {
                                textFormat: Text.StyledText
                                text: qsTr("Top up at least $%1 to keep playing. <a href=\"https://www.productifynow.com/pricing\">Top up</a>").arg(Number(info.minTopup || 0).toFixed(2))
                                font.family: uiFont; font.pixelSize: 14; color: ink
                                onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                            }
                        }
                    }

                    GridLayout {
                        visible: info.connected === true
                        Layout.fillWidth: true
                        columns: 3
                        columnSpacing: 16
                        rowSpacing: 16
                        Repeater {
                            model: [
                                { k: qsTr("Machine"), v: info.gpu || "" },
                                { k: qsTr("Location"), v: info.location || "" },
                                { k: qsTr("Price"), v: info.hourlyPrice ? "$" + Number(info.hourlyPrice).toFixed(2) + qsTr(" / hour") : "" },
                                { k: qsTr("Connected for"), v: info.connectedAtMs ? clock(nowMs - info.connectedAtMs) : "" },
                                { k: qsTr("Credit left"), v: info.minutesLeft >= 0 ? qsTr("about %1").arg(clock(info.minutesLeft * 60000)) : "" },
                                { k: qsTr("Session code"), v: info.code || "" }
                            ]
                            delegate: CutRect {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 92
                                notch: 12
                                fill: paper
                                Fact {
                                    anchors.fill: parent
                                    anchors.margins: 18
                                    label: modelData.k
                                    value: modelData.v
                                }
                            }
                        }
                    }

                    RowLayout {
                        visible: info.connected === true
                        spacing: 12
                        AccentButton {
 accentColor: accent
 motionScale: motion
                            text: qsTr("Back to launchers")
                            onClicked: page = 0
                        }
                        AccentButton {
 accentColor: accent
 motionScale: motion
                            primary: false
                            text: qsTr("Disconnect")
                            onClicked: {
                                picking = false
                                joinLauncher.disconnectFromMachine()
                            }
                        }
                    }

                    Label {
                        visible: info.connected === true
                        Layout.fillWidth: true
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        text: qsTr("To stop paying, end the session on <a href=\"https://www.productifynow.com/gamezone\">productifynow.com/gamezone</a>. A session with nobody connected ends by itself after 10 minutes.")
                        font.family: uiFont
                        font.pixelSize: 14
                        color: muted
                        onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                    }
                }
            }

            // ===== 2: Settings (look) =====
            Item {
                ColumnLayout {
                    x: 40
                    y: 32
                    width: Math.min(parent.width - 80, 760)
                    spacing: 22

                    Label {
                        text: qsTr("Customise")
                        font.family: uiFont
                        font.pixelSize: 40
                        font.weight: Font.Black
                        font.letterSpacing: -0.8
                        color: ink
                    }

                    Label { text: qsTr("Accent colour"); font.family: uiFont; font.pixelSize: 18; font.weight: Font.Bold; color: ink }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 14
                        Repeater {
                            model: accentPresets
                            delegate: AbstractButton {
                                id: sw
                                readonly property bool chosen: Qt.colorEqual(look.accent, modelData.color)
                                width: 108
                                height: 96
                                hoverEnabled: true
                                focusPolicy: Qt.StrongFocus
                                Accessible.name: modelData.name
                                onClicked: look.accent = modelData.color
                                background: CutRect {
                                    notch: 12
                                    fill: paper
                                    stroke: sw.chosen ? ink : (sw.hovered || sw.visualFocus ? "#B8B9B2" : "transparent")
                                    strokeWidth: sw.chosen ? 2 : 1
                                }
                                contentItem: ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 8
                                    CutRect {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 38
                                        notch: 8
                                        fill: modelData.color
                                    }
                                    Label {
                                        Layout.fillWidth: true
                                        text: modelData.name
                                        font.family: uiFont
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                        color: ink
                                    }
                                }
                            }
                        }
                    }

                    RowLayout {
                        spacing: 10
                        Label { text: qsTr("Custom colour"); font.family: uiFont; font.pixelSize: 15; color: ink }
                        TextField {
                            id: hexField
                            Layout.preferredWidth: 140
                            text: String(look.accent).toUpperCase()
                            font.family: uiFont
                            font.pixelSize: 15
                            maximumLength: 7
                            Accessible.name: qsTr("Custom accent colour, as #RRGGBB")
                            onEditingFinished: {
                                if (/^#[0-9A-Fa-f]{6}$/.test(text)) look.accent = text
                                else text = String(look.accent).toUpperCase()
                            }
                        }
                        Label { text: qsTr("as #RRGGBB"); font.family: uiFont; font.pixelSize: 13; color: muted }
                    }

                    Label { text: qsTr("Look and feel"); font.family: uiFont; font.pixelSize: 18; font.weight: Font.Bold; color: ink; Layout.topMargin: 6 }
                    Switch {
                        text: qsTr("Background pattern")
                        checked: look.pattern
                        onToggled: look.pattern = checked
                        font.family: uiFont
                        font.pixelSize: 15
                    }
                    Switch {
                        text: qsTr("Reduce motion (no zoom or sliding)")
                        checked: look.reduceMotion
                        onToggled: look.reduceMotion = checked
                        font.family: uiFont
                        font.pixelSize: 15
                    }

                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: qsTr("Stream quality, resolution and controller options are under the gear at the top right.")
                        font.family: uiFont
                        font.pixelSize: 14
                        color: muted
                    }
                }
            }

            // ===== 3: Help =====
            Item {
                ColumnLayout {
                    x: 40
                    y: 32
                    width: Math.min(parent.width - 80, 760)
                    spacing: 18

                    Label {
                        text: qsTr("Help")
                        font.family: uiFont
                        font.pixelSize: 40
                        font.weight: Font.Black
                        font.letterSpacing: -0.8
                        color: ink
                    }

                    Repeater {
                        model: [
                            { k: "Ctrl + Alt + Shift + Q", v: qsTr("Leave the game and come back to the launchers") },
                            { k: "Ctrl + Alt + Shift + Z", v: qsTr("Release the mouse and keyboard from the game") },
                            { k: "Ctrl + Alt + Shift + X", v: qsTr("Switch between full screen and a window") },
                            { k: "Ctrl + Alt + Shift + S", v: qsTr("Show connection stats") }
                        ]
                        delegate: RowLayout {
                            Layout.fillWidth: true
                            spacing: 16
                            CutRect {
                                Layout.preferredWidth: 230
                                Layout.preferredHeight: 40
                                notch: 8
                                fill: paper
                                Label {
                                    anchors.centerIn: parent
                                    text: modelData.k
                                    font.family: uiFont
                                    font.pixelSize: 14
                                    font.weight: Font.Bold
                                    color: ink
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                text: modelData.v
                                font.family: uiFont
                                font.pixelSize: 15
                                wrapMode: Text.Wrap
                                color: ink
                            }
                        }
                    }

                    Label {
                        Layout.topMargin: 8
                        Layout.fillWidth: true
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        text: qsTr("Trouble connecting? See <a href=\"https://www.productifynow.com/gamezone\">productifynow.com/gamezone</a> or contact Productify support.")
                        font.family: uiFont
                        font.pixelSize: 15
                        color: ink
                        onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: qsTr("PG Connect %1 is free software based on Moonlight, licensed under the GNU GPL v3.").arg(Qt.application.version)
                        font.family: uiFont
                        font.pixelSize: 13
                        color: muted
                    }
                }
            }
        }
    }

    NavigableMessageDialog {
        id: quitAppDialog
        property string appName: ""
        text: qsTr("%1 is still running from an earlier connection. Close it and start again? Unsaved progress will be lost.").arg(appName)
        standardButtons: Dialog.Yes | Dialog.No
        onAccepted: joinLauncher.quitRunningApp()
        onRejected: joinLauncher.cancel()
    }
}
