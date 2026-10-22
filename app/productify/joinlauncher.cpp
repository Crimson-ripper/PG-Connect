#include "joinlauncher.h"

#include "backend/computermanager.h"
#include "backend/computerseeker.h"
#include "cli/startstream.h"
#include "streaming/session.h"

#include <QEventLoop>
#include <QTcpSocket>

#include <memory>
#include <QNetworkReply>
#include <QTimer>

namespace Productify
{

// Sunshine on a fresh VM (or through a tunnel that is still handshaking) can take a while
static const int kHostSeekTimeoutMs = 45000;
// Give the pairing request time to reach Sunshine before asking the backend to submit the PIN
static const int kPinSubmitDelayMs = 1500;

JoinLauncher::JoinLauncher(QString initialCode, StreamingPreferences* preferences, QObject* parent)
    : QObject(parent),
      m_InitialCode(SessionApi::normalizeCode(initialCode)),
      m_Preferences(preferences),
      m_Api(new SessionApi(this)),
      m_Tunnel(new WireGuardTunnel(this))
{
    connect(m_Api, &SessionApi::sessionReady, this, &JoinLauncher::onSessionReady);
    connect(m_Api, &SessionApi::sessionFailed, this, &JoinLauncher::fail);
    connect(m_Api, &SessionApi::pinSubmissionFailed, this, [this](QString message) {
        if (m_State == StatePairing) {
            fail(tr("Automatic pairing failed: %1").arg(message));
        }
    });
    connect(m_Tunnel, &WireGuardTunnel::tunnelUp, this, &JoinLauncher::onTunnelUp);
    connect(m_Tunnel, &WireGuardTunnel::tunnelFailed, this, &JoinLauncher::fail);
}

JoinLauncher::~JoinLauncher()
{
    finish();
}

QString JoinLauncher::normalizeCode(const QString& input) const
{
    return SessionApi::normalizeCode(input);
}

void JoinLauncher::setState(State state)
{
    bool wasBusy = isBusy();
    m_State = state;
    if (wasBusy != isBusy()) {
        emit busyChanged();
    }
}

void JoinLauncher::fail(const QString& message)
{
    if (m_State == StateFailed || m_State == StateIdle) {
        return;
    }
    if (m_Seeker) {
        m_Seeker->deleteLater();
    }
    if (m_StreamLauncher) {
        m_StreamLauncher->deleteLater();
    }
    if (m_ComputerManager) {
        disconnect(m_ComputerManager, nullptr, this, nullptr);
    }
    if (!m_Config.sessionId.isEmpty()) {
        m_Api->reportEvent(m_Config, "client_error", message);
    }
    m_Tunnel->down();
    setState(StateFailed);
    emit failed(message);
}

void JoinLauncher::join(const QString& rawCode, ComputerManager* manager)
{
    if (isBusy()) {
        return;
    }

    QString code = SessionApi::normalizeCode(rawCode);
    m_ComputerManager = manager;
    m_Config = SessionConfig();
    setState(StateFetchingSession);

    if (code.isEmpty()) {
        fail(tr("Enter the session code shown on your Productify session page."));
        return;
    }

    // A fresh key per session; only the public half is sent to Productify. Generated even when
    // WireGuard is missing, so a tunnelled session can tell the player what to install.
    m_Keys = WireGuardTunnel::generateKeyPair();

    emit stageChanged(tr("Checking your session code..."));
    m_Api->connectSession(code, m_Keys.publicKey);
}

void JoinLauncher::onSessionReady(SessionConfig config)
{
    if (m_State != StateFetchingSession) {
        return;
    }
    m_Config = config;

    if (config.networkMode == "wireguard") {
        if (!m_Keys.isValid()) {
            fail(tr("Could not create a secure tunnel key."));
            return;
        }
        setState(StateTunnel);
        emit stageChanged(tr("Opening a secure tunnel to your gaming machine..."));
        m_Tunnel->up(config.wireguard, m_Keys.privateKey, config.sessionId);
    }
    else {
        seekHost();
    }
}

void JoinLauncher::onTunnelUp()
{
    if (m_State == StateTunnel) {
        seekHost();
    }
}

void JoinLauncher::seekHost()
{
    setState(StateSeekingHost);
    emit stageChanged(tr("Connecting to your gaming machine..."));

    // ComputerSeeker adds an unknown host with a single request. A tunnel that is still
    // handshaking (or a VM still booting) loses that request, so first wait until
    // Sunshine's HTTP port accepts a connection.
    QString address = (m_Config.networkMode == "wireguard") ? m_Config.wireguard.hostTunnelAddress
                                                            : m_Config.hostAddress;
    probeHost(address, (quint16)m_Config.hostHttpPort, kHostSeekTimeoutMs / 1000);
}

void JoinLauncher::probeHost(const QString& address, quint16 port, int attemptsLeft)
{
    if (m_State != StateSeekingHost) {
        return;
    }

    auto* socket = new QTcpSocket(this);
    auto finished = std::make_shared<bool>(false);
    auto done = [this, socket, finished, address, port, attemptsLeft](bool ok) {
        if (*finished) {
            return;
        }
        *finished = true;
        socket->abort();
        socket->deleteLater();
        if (m_State != StateSeekingHost) {
            return;
        }
        if (ok) {
            startSeeker();
        }
        else if (attemptsLeft > 1) {
            QTimer::singleShot(1000, this, [this, address, port, attemptsLeft]() {
                probeHost(address, port, attemptsLeft - 1);
            });
        }
        else {
            onSeekTimeout();
        }
    };
    connect(socket, &QTcpSocket::connected, this, [done]() { done(true); });
    connect(socket, &QTcpSocket::errorOccurred, this, [done]() { done(false); });
    QTimer::singleShot(2000, this, [done]() { done(false); });
    socket->connectToHost(address, port);
}

void JoinLauncher::startSeeker()
{
    connect(m_ComputerManager, &ComputerManager::pairingCompleted,
            this, &JoinLauncher::onPairingCompleted, Qt::UniqueConnection);

    m_Seeker = new ComputerSeeker(m_ComputerManager, m_Config.streamHost(), this);
    connect(m_Seeker, &ComputerSeeker::computerFound, this, &JoinLauncher::onComputerFound);
    connect(m_Seeker, &ComputerSeeker::errorTimeout, this, &JoinLauncher::onSeekTimeout);
    m_Seeker->start(kHostSeekTimeoutMs);
}

void JoinLauncher::onSeekTimeout()
{
    if (m_State == StateSeekingHost) {
        fail(tr("Your gaming machine did not answer. It may still be starting; try again in a minute."));
    }
}

void JoinLauncher::onComputerFound(NvComputer* computer)
{
    if (m_State != StateSeekingHost) {
        return;
    }
    m_Seeker->deleteLater();

    if (computer->pairState == NvComputer::PS_PAIRED) {
        launchApp();
        return;
    }

    if (m_Config.pairingMode != "pin") {
        fail(tr("This device is not paired with the session's machine. Start a new session to pair again."));
        return;
    }

    setState(StatePairing);
    emit stageChanged(tr("Pairing securely..."));
    m_ComputerManager->pairHost(computer, m_Config.pin);

    // Sunshine only accepts the PIN while our pairing request is waiting for it.
    QTimer::singleShot(kPinSubmitDelayMs, this, [this]() {
        if (m_State == StatePairing) {
            m_Api->requestPinSubmission(m_Config);
        }
    });
}

void JoinLauncher::onPairingCompleted(NvComputer*, QString error)
{
    if (m_State != StatePairing) {
        return;
    }
    if (!error.isEmpty()) {
        fail(tr("Pairing failed: %1").arg(error));
        return;
    }
    launchApp();
}

void JoinLauncher::launchApp()
{
    setState(StateLaunching);
    emit stageChanged(tr("Starting %1...").arg(m_Config.appName));

    // Reuse upstream's CLI stream launcher: it waits for the app list, handles a
    // running app and creates the Session. Only the session's app is ever requested.
    m_StreamLauncher = new CliStartStream::Launcher(m_Config.streamHost(), m_Config.appName, m_Preferences, this);
    connect(m_StreamLauncher, &CliStartStream::Launcher::failed, this, &JoinLauncher::fail);
    connect(m_StreamLauncher, &CliStartStream::Launcher::appQuitRequired, this, &JoinLauncher::appQuitRequired);
    connect(m_StreamLauncher, &CliStartStream::Launcher::sessionCreated, this,
            [this](QString appName, Session* session) {
        setState(StateStreaming);
        m_Api->reportEvent(m_Config, "stream_started");
        emit sessionCreated(appName, session);
    });
    m_StreamLauncher->execute(m_ComputerManager);
}

void JoinLauncher::quitRunningApp()
{
    if (m_StreamLauncher) {
        m_StreamLauncher->quitRunningApp();
    }
}

void JoinLauncher::cancel()
{
    fail(tr("Cancelled."));
}

void JoinLauncher::finish()
{
    if (m_State == StateStreaming) {
        // The process usually exits right after this, so wait briefly for delivery.
        QNetworkReply* reply = m_Api->reportEvent(m_Config, "stream_ended");
        QEventLoop loop;
        connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
        QTimer::singleShot(2000, &loop, &QEventLoop::quit);
        loop.exec();
    }
    m_Tunnel->down();
    if (m_State != StateFailed) {
        setState(StateIdle);
    }
}

}
