#pragma once

#include "sessionapi.h"

#include <QObject>
#include <QString>

namespace Productify
{

struct WireGuardKeyPair
{
    QString privateKey; // base64, never leaves this device
    QString publicKey;  // base64, sent to the backend

    bool isValid() const { return !privateKey.isEmpty() && !publicKey.isEmpty(); }
};

// Brings up a split-tunnel WireGuard interface to the Gamezone host for the
// duration of one session. Only the host's tunnel address is routed through it.
//
// Phase 1 (this file, Windows): drives an installed WireGuard for Windows
// (wireguard.exe /installtunnelservice), which needs one UAC prompt to start and
// one to stop. Phase 2 replaces this with an embedded tunnel (see DESIGN.md).
class WireGuardTunnel : public QObject
{
    Q_OBJECT

public:
    explicit WireGuardTunnel(QObject* parent = nullptr);
    ~WireGuardTunnel() override;

    static WireGuardKeyPair generateKeyPair();

    // True if this platform/installation can bring up a tunnel at all.
    static bool isSupported(QString* reason = nullptr);

    // Renders a wg-quick style config. Exposed for tests and for the Linux/macOS path.
    static QString renderConfig(const WireGuardConfig& config, const QString& privateKey);

    void up(const WireGuardConfig& config, const QString& privateKey, const QString& sessionId);

    // Synchronous best-effort teardown (also called from the destructor).
    void down();

    bool isUp() const { return m_Up; }

signals:
    void tunnelUp();
    void tunnelFailed(QString message);

private:
    QString m_TunnelName;
    QString m_ConfigPath;
    bool m_Up = false;
};

}
