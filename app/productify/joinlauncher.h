#pragma once

#include "sessionapi.h"
#include "wgtunnel.h"

#include <QObject>
#include <QPointer>

class ComputerManager;
class ComputerSeeker;
class NvComputer;
class Session;
class StreamingPreferences;

namespace CliStartStream { class Launcher; }

namespace Productify
{

// Drives "join with session code": fetch session -> (tunnel) -> find host ->
// pair with the one-time PIN -> launch the session's only app.
// Exposed to JoinView.qml as the "joinLauncher" context property.
class JoinLauncher : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString initialCode READ initialCode CONSTANT)
    Q_PROPERTY(bool busy READ isBusy NOTIFY busyChanged)

public:
    explicit JoinLauncher(QString initialCode, StreamingPreferences* preferences, QObject* parent = nullptr);
    ~JoinLauncher() override;

    QString initialCode() const { return m_InitialCode; }
    bool isBusy() const { return m_State != StateIdle && m_State != StateFailed; }

    Q_INVOKABLE QString normalizeCode(const QString& input) const;
    Q_INVOKABLE void join(const QString& code, ComputerManager* manager);
    Q_INVOKABLE void quitRunningApp();
    Q_INVOKABLE void cancel();

    // Called when the stream ends or the app quits.
    Q_INVOKABLE void finish();

signals:
    void stageChanged(QString text);
    void failed(QString text);
    void sessionCreated(QString appName, Session* session);
    void appQuitRequired(QString appName);
    void busyChanged();

private slots:
    void onSessionReady(Productify::SessionConfig config);
    void onTunnelUp();
    void onComputerFound(NvComputer* computer);
    void onSeekTimeout();
    void onPairingCompleted(NvComputer* computer, QString error);

private:
    enum State {
        StateIdle,
        StateFetchingSession,
        StateTunnel,
        StateSeekingHost,
        StatePairing,
        StateLaunching,
        StateStreaming,
        StateFailed,
    };

    void setState(State state);
    void fail(const QString& message);
    void seekHost();
    void launchApp();

    QString m_InitialCode;
    StreamingPreferences* m_Preferences;
    ComputerManager* m_ComputerManager = nullptr;
    SessionApi* m_Api;
    WireGuardTunnel* m_Tunnel;
    WireGuardKeyPair m_Keys;
    SessionConfig m_Config;
    QPointer<ComputerSeeker> m_Seeker;
    QPointer<CliStartStream::Launcher> m_StreamLauncher;
    State m_State = StateIdle;
};

}
