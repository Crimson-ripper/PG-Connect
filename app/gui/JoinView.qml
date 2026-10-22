// Productify Connect: start screen. The player enters a session code (or opens a
// productify://connect?code=... link) and everything else is automatic.
import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3

import ComputerManager 1.0

Item {
    id: joinView
    objectName: qsTr("Join a session")

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

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 460)
        spacing: 16

        Label {
            Layout.fillWidth: true
            text: qsTr("Productify Connect")
            font.pointSize: 26
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
        }

        Label {
            Layout.fillWidth: true
            text: qsTr("Enter the session code from your Productify session page.")
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            opacity: 0.8
        }

        TextField {
            id: codeField
            Layout.fillWidth: true
            enabled: !joinLauncher.busy
            placeholderText: qsTr("Session code")
            font.pointSize: 20
            font.capitalization: Font.AllUppercase
            horizontalAlignment: TextInput.AlignHCenter
            inputMethodHints: Qt.ImhUppercaseOnly | Qt.ImhNoPredictiveText
            maximumLength: 24
            selectByMouse: true
            Accessible.name: qsTr("Session code")

            Keys.onReturnPressed: startJoin()
            Keys.onEnterPressed: startJoin()
        }

        Button {
            id: joinButton
            Layout.fillWidth: true
            text: joinLauncher.busy ? qsTr("Connecting...") : qsTr("Join")
            enabled: !joinLauncher.busy && codeField.text.length > 0
            highlighted: true
            font.pointSize: 14
            onClicked: startJoin()
        }

        RowLayout {
            Layout.fillWidth: true
            visible: joinLauncher.busy
            spacing: 8

            BusyIndicator {
                running: joinLauncher.busy
                Layout.preferredHeight: 36
                Layout.preferredWidth: 36
            }

            Label {
                id: stageLabel
                Layout.fillWidth: true
                wrapMode: Text.Wrap
            }
        }

        Label {
            id: errorLabel
            Layout.fillWidth: true
            visible: text !== ""
            color: "#ff8a80"
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Label {
            Layout.fillWidth: true
            Layout.topMargin: 24
            text: qsTr("Productify Connect is free software based on Moonlight, licensed under the GNU GPL v3.")
            font.pointSize: 9
            opacity: 0.6
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
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
