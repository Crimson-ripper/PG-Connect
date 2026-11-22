#pragma once

#include "sessionapi.h"
#include "wgtunnel.h"

#include <QObject>
#include <QElapsedTimer>
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
    // Called when the network dropped mid-stream: start the same game again (up to
    // kMaxReconnects times; the count resets after a stream stays up kReconnectResetMs).
    Q_INVOKABLE void reconnect();
    // 0.1.8: switching launchers (Steam, Epic, ...) inside PG Connect instead of on the website.
    Q_INVOKABLE bool canSwitchApps() const;
    Q_INVOKABLE void chooseApp(const QString& name);
    Q_INVOKABLE void backToPicker();

signals:
    void stageChanged(QString text);
    void failed(QString text);
    void sessionCreated(QString appName, Session* session);
    void appQuitRequired(QString appName);
    void appChoicesReady(QStringList choices, QString current);
    // 0.1.9: "" or a warning to show (balance is zero, machine shuts down soon)
    void creditWarning(QString text);
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
        StatePicking,
        StateLaunching,
        StateStreaming,
        StateFailed,
    };

    void setState(State state);
    void fail(const QString& message);
    void seekHost();
    void probeHost(const QString& address, quint16 port, int attemptsLeft);
    void startSeeker();
    void launchApp();
    void readyToLaunch();
    void onStatus(const QJsonObject& status);
    void showCreditWarning();

    QString m_InitialCode;
    StreamingPreferences* m_Preferences;
    int m_SavedPacketSize = -1;  // restored when the join ends (see launchApp)
    int m_SavedBitrateKbps = -1; // restored when the join ends (see launchApp)
    int m_Reconnects = 0;
    QElapsedTimer m_StreamClock;  // how long the current stream has been up
    ComputerManager* m_ComputerManager = nullptr;
    SessionApi* m_Api;
    WireGuardTunnel* m_Tunnel;
    WireGuardKeyPair m_Keys;
    SessionConfig m_Config;
    QPointer<ComputerSeeker> m_Seeker;
    QPointer<CliStartStream::Launcher> m_StreamLauncher;
    State m_State = StateIdle;
    QTimer* m_StatusTimer;         // asks the backend for the credit state while connected
    QTimer* m_CountdownTimer;      // updates the warning every second
    qint64 m_GraceEndsMs = 0;      // when the machine shuts down (0: no warning)
    double m_MinTopup = 0;
    bool m_OverlayShown = false;
};

}
