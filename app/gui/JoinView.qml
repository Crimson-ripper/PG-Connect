// PG Connect: start screen. The player enters a session code (or opens a
// productify://connect?code=... link) and everything else is automatic.
// Styled like Productify Node: paper background, white panel, ink text,
// monospace labels, square corners, lime primary button.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import ComputerManager 1.0

Item {
    id: joinView
    objectName: ""  // no toolbar title: the panel heading says it

    // Productify palette (productify-node v2/app/src/style.css)
    readonly property color ink: "#101112"
    readonly property color paper: "#F7F7F4"
    readonly property color line: "#DEDFD9"
    readonly property color muted: "#6A6A63"
    readonly property color lime: "#C8F04C"
    readonly property string monoFont: "Consolas"
    readonly property string uiFont: "Segoe UI"

    function startJoin() {
        if (joinLauncher.busy) {
            return
        }
        var code = joinLauncher.normalizeCode(codeField.text)
        if (code === "") {
            errorLabel.text = qsTr("Session codes are 6 to 16 letters and numbers, for example PFY-7K2M-9QXD.")
            return
        }
        errorLabel.text = ""
        stageLabel.text = ""
        joinLauncher.join(code, ComputerManager)
    }

    function onStageChanged(text) {
        stageLabel.text = text
    }

    function onFailed(message) {
        stageLabel.text = ""
        errorLabel.text = message
        console.error(message)
    }

    function onSessionCreated(appName, session) {
        var component = Qt.createComponent("StreamSegue.qml")
        var segue = component.createObject(stackView, {
            "appName": appName,
            "session": session,
            // A Gamezone session has exactly one app: close when the stream ends.
            "quitAfter": true
        })
        stackView.push(segue)
    }

    function onAppQuitRequired(appName) {
        quitAppDialog.appName = appName
        quitAppDialog.open()
    }

    Component.onCompleted: {
        joinLauncher.stageChanged.connect(onStageChanged)
        joinLauncher.failed.connect(onFailed)
        joinLauncher.sessionCreated.connect(onSessionCreated)
        joinLauncher.appQuitRequired.connect(onAppQuitRequired)
    }

    StackView.onActivated: {
        codeField.forceActiveFocus()
        if (joinLauncher.initialCode !== "" && !joinLauncher.busy && codeField.text === "") {
            // Opened from a productify://connect link
            codeField.text = joinLauncher.initialCode
            startJoin()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: paper
    }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 460)
        height: content.implicitHeight + 40
        color: "#FFFFFF"
        border.color: line
        border.width: 1

        ColumnLayout {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 20
            spacing: 12

            Label {
                text: qsTr("PRODUCTIFY GAMEZONE")
                font.family: monoFont
                font.pixelSize: 11
                font.letterSpacing: 1
                color: muted
            }

            Label {
                Layout.fillWidth: true
                text: qsTr("Join your game")
                font.family: uiFont
                font.pixelSize: 26
                font.weight: Font.DemiBold
                color: ink
            }

            Label {
                Layout.fillWidth: true
                text: qsTr("Enter the session code from your Productify session page. PG Connect connects, pairs and starts your game for you.")
                font.family: uiFont
                font.pixelSize: 14
                lineHeight: 1.3
                wrapMode: Text.Wrap
                color: muted
            }

            Label {
                Layout.topMargin: 6
                text: qsTr("SESSION CODE")
                font.family: monoFont
                font.pixelSize: 11
                font.letterSpacing: 0.6
                color: muted
            }

            TextField {
                id: codeField
                Layout.fillWidth: true
                enabled: !joinLauncher.busy
                placeholderText: "PFY-XXXX-XXXX"
                placeholderTextColor: "#A3A39C"
                font.family: monoFont
                font.pixelSize: 22
                font.capitalization: Font.AllUppercase
                color: ink
                horizontalAlignment: TextInput.AlignHCenter
                inputMethodHints: Qt.ImhUppercaseOnly | Qt.ImhNoPredictiveText
                maximumLength: 24
                selectByMouse: true
                leftPadding: 10
                rightPadding: 10
                topPadding: 10
                bottomPadding: 10
                Accessible.name: qsTr("Session code")
                background: Rectangle {
                    color: "#FFFFFF"
                    border.width: 1
                    border.color: codeField.activeFocus ? ink : line
                }

                Keys.onReturnPressed: startJoin()
                Keys.onEnterPressed: startJoin()
            }

            Button {
                id: joinButton
                Layout.fillWidth: true
                enabled: !joinLauncher.busy && codeField.text.length > 0
                text: joinLauncher.busy ? qsTr("Connecting…") : qsTr("Join")
                onClicked: startJoin()
                Accessible.name: text

                contentItem: Label {
                    text: joinButton.text
                    font.family: uiFont
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: ink
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    implicitHeight: 42
                    color: lime
                    opacity: joinButton.enabled ? (joinButton.down ? 0.85 : 1.0) : 0.45
                    border.width: joinButton.visualFocus ? 2 : 0
                    border.color: ink
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: joinLauncher.busy
                spacing: 8

                BusyIndicator {
                    running: joinLauncher.busy
                    Layout.preferredHeight: 28
                    Layout.preferredWidth: 28
                }

                Label {
                    id: stageLabel
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    font.family: uiFont
                    font.pixelSize: 13
                    color: ink
                }
            }

            // Error box, same colours as Productify Node's .error
            Rectangle {
                Layout.fillWidth: true
                visible: errorLabel.text !== ""
                implicitHeight: errorLabel.implicitHeight + 20
                color: "#FDEAEA"
                border.color: "#F1C8C8"
                border.width: 1

                Label {
                    id: errorLabel
                    anchors.fill: parent
                    anchors.margins: 10
                    wrapMode: Text.Wrap
                    font.family: uiFont
                    font.pixelSize: 13
                    color: "#8A2B2B"
                }
            }

            Label {
                Layout.fillWidth: true
                Layout.topMargin: 8
                text: qsTr("PG Connect is free software based on Moonlight, licensed under the GNU GPL v3.")
                font.family: uiFont
                font.pixelSize: 11
                color: muted
                wrapMode: Text.Wrap
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
