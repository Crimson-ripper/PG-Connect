#include "wgtunnel.h"

#include <QDir>
#include <QFile>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QThread>

#include <openssl/evp.h>

#ifdef Q_OS_WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#endif

namespace Productify
{

WireGuardTunnel::WireGuardTunnel(QObject* parent)
    : QObject(parent)
{
}

WireGuardTunnel::~WireGuardTunnel()
{
    down();
}

WireGuardKeyPair WireGuardTunnel::generateKeyPair()
{
    WireGuardKeyPair pair;

    EVP_PKEY* pkey = EVP_PKEY_Q_keygen(nullptr, nullptr, "X25519");
    if (pkey == nullptr) {
        return pair;
    }

    unsigned char priv[32], pub[32];
    size_t privLen = sizeof(priv), pubLen = sizeof(pub);
    if (EVP_PKEY_get_raw_private_key(pkey, priv, &privLen) == 1 &&
            EVP_PKEY_get_raw_public_key(pkey, pub, &pubLen) == 1 &&
            privLen == 32 && pubLen == 32) {
        pair.privateKey = QByteArray(reinterpret_cast<char*>(priv), 32).toBase64();
        pair.publicKey = QByteArray(reinterpret_cast<char*>(pub), 32).toBase64();
    }

    OPENSSL_cleanse(priv, sizeof(priv));
    EVP_PKEY_free(pkey);
    return pair;
}

#ifdef Q_OS_WIN32
static QString wireguardExePath()
{
    QString programFiles = qEnvironmentVariable("ProgramW6432", qEnvironmentVariable("ProgramFiles", "C:\\Program Files"));
    QString path = QDir(programFiles).filePath("WireGuard/wireguard.exe");
    return QFile::exists(path) ? QDir::toNativeSeparators(path) : QString();
}

// Runs wireguard.exe elevated (UAC prompt) and waits for it. Returns the exit code, or -1.
static int runElevated(const QString& exe, const QString& args)
{
    std::wstring file = exe.toStdWString();
    std::wstring params = args.toStdWString();

    SHELLEXECUTEINFOW info = {};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    info.lpVerb = L"runas";
    info.lpFile = file.c_str();
    info.lpParameters = params.c_str();
    info.nShow = SW_HIDE;

    if (!ShellExecuteExW(&info) || info.hProcess == nullptr) {
        return -1;
    }
    WaitForSingleObject(info.hProcess, 60000);
    DWORD exitCode = (DWORD)-1;
    GetExitCodeProcess(info.hProcess, &exitCode);
    CloseHandle(info.hProcess);
    return (int)exitCode;
}
#endif

bool WireGuardTunnel::isSupported(QString* reason)
{
#ifdef Q_OS_WIN32
    if (wireguardExePath().isEmpty()) {
        if (reason) {
            *reason = tr("This session needs WireGuard. Install it from https://www.wireguard.com/install/ and try again.");
        }
        return false;
    }
    return true;
#else
    if (reason) {
        *reason = tr("Tunnelled sessions are not supported on this platform yet.");
    }
    return false;
#endif
}

QString WireGuardTunnel::renderConfig(const WireGuardConfig& config, const QString& privateKey)
{
    QString conf;
    conf += "[Interface]\n";
    conf += "PrivateKey = " + privateKey + "\n";
    conf += "Address = " + config.interfaceAddress + "\n";
    conf += "MTU = " + QString::number(config.mtu) + "\n";
    // No DNS line: the tunnel only carries traffic to the Gamezone host.
    conf += "\n[Peer]\n";
    conf += "PublicKey = " + config.peerPublicKey + "\n";
    if (!config.presharedKey.isEmpty()) {
        conf += "PresharedKey = " + config.presharedKey + "\n";
    }
    conf += "Endpoint = " + config.endpoint + "\n";
    conf += "AllowedIPs = " + (config.allowedIps.isEmpty() ? config.hostTunnelAddress + "/32" : config.allowedIps) + "\n";
    conf += "PersistentKeepalive = " + QString::number(config.persistentKeepalive) + "\n";
    return conf;
}

void WireGuardTunnel::up(const WireGuardConfig& config, const QString& privateKey, const QString& sessionId)
{
    QString reason;
    if (!isSupported(&reason)) {
        emit tunnelFailed(reason);
        return;
    }

    // Refuse configs that would capture all traffic: a session tunnel must stay split.
    const QStringList allowed = config.allowedIps.split(',', Qt::SkipEmptyParts);
    for (const QString& net : allowed) {
        if (net.trimmed().endsWith("/0")) {
            emit tunnelFailed(tr("Productify sent a tunnel configuration that would route all traffic. Refusing to connect."));
            return;
        }
    }

    // WireGuard tunnel names: max 32 chars of [a-zA-Z0-9_=+.-]
    QString suffix = QString(sessionId).remove(QRegularExpression("[^a-zA-Z0-9]")).left(12);
    m_TunnelName = "pfy-" + (suffix.isEmpty() ? QString("session") : suffix);

    QDir dir(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation) + "/tunnels");
    dir.mkpath(".");
    m_ConfigPath = dir.filePath(m_TunnelName + ".conf");

    QFile file(m_ConfigPath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        emit tunnelFailed(tr("Could not write the tunnel configuration."));
        return;
    }
    file.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
    file.write(renderConfig(config, privateKey).toUtf8());
    file.close();

#ifdef Q_OS_WIN32
    QString exe = wireguardExePath();
    QString args = "/installtunnelservice \"" + QDir::toNativeSeparators(m_ConfigPath) + "\"";
    QThread* worker = QThread::create([this, exe, args]() {
        int rc = runElevated(exe, args);
        QMetaObject::invokeMethod(this, [this, rc]() {
            if (rc == 0) {
                m_Up = true;
                emit tunnelUp();
            }
            else {
                QFile::remove(m_ConfigPath);
                emit tunnelFailed(rc == -1 ? tr("The secure tunnel needs administrator permission to start.")
                                           : tr("WireGuard could not start the tunnel (error %1).").arg(rc));
            }
        }, Qt::QueuedConnection);
    });
    connect(worker, &QThread::finished, worker, &QObject::deleteLater);
    worker->start();
#endif
}

void WireGuardTunnel::down()
{
#ifdef Q_OS_WIN32
    if (m_Up) {
        m_Up = false;
        runElevated(wireguardExePath(), "/uninstalltunnelservice " + m_TunnelName);
    }
#endif
    // The config holds this session's private key; never leave it behind.
    if (!m_ConfigPath.isEmpty()) {
        QFile::remove(m_ConfigPath);
        m_ConfigPath.clear();
    }
}

}
