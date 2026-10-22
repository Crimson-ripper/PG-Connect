#pragma once

#include <QObject>
#include <QString>
#include <QUrl>

class QNetworkAccessManager;
class QNetworkReply;

namespace Productify
{

// WireGuard settings returned by the backend for sessions whose host is only
// reachable through a tunnel (e.g. Vast.ai VMs with randomly mapped ports).
struct WireGuardConfig
{
    QString interfaceAddress;   // client tunnel address, e.g. "10.77.0.2/32"
    QString peerPublicKey;      // host's WireGuard public key (base64)
    QString presharedKey;       // optional (base64)
    QString endpoint;           // host public "ip:port" (the identity-mapped UDP port)
    QString allowedIps;         // e.g. "10.77.0.1/32" - never a default route
    QString hostTunnelAddress;  // Sunshine's address inside the tunnel, e.g. "10.77.0.1"
    int mtu = 1420;
    int persistentKeepalive = 25;
};

struct SessionConfig
{
    QString code;
    QString sessionId;
    QString expiresAt;

    QString hostName;
    QString hostAddress;        // used when networkMode == "direct"
    int hostHttpPort = 47989;

    QString pairingMode;        // "pin" or "already_paired"
    QString pin;                // one-time 4 digit PIN
    QString pairToken;          // opaque token for /pairing

    QString appName;            // the only app the client may launch

    QString networkMode;        // "direct" or "wireguard"
    WireGuardConfig wireguard;

    // Address and port the client should use to reach Sunshine.
    QString streamHost() const;
};

// Client for the Productify Gamezone session API. See DESIGN.md, "Backend API contract".
class SessionApi : public QObject
{
    Q_OBJECT

public:
    explicit SessionApi(QObject* parent = nullptr);

    // Normalises user input ("pfy-7k2m 9qxd" -> "PFY7K2M9QXD"); empty if invalid.
    static QString normalizeCode(const QString& input);

    // Extracts the code from productify://connect?code=... (empty if not a valid link).
    static QString codeFromDeepLink(const QString& url);

    static QUrl apiBase();

    // POST /api/gamezone/sessions/{code}/connect
    // wgPublicKey is the client's freshly generated WireGuard key (may be empty).
    void connectSession(const QString& code, const QString& wgPublicKey);

    // POST /api/gamezone/sessions/{code}/pairing - asks the backend to submit the PIN to Sunshine
    void requestPinSubmission(const SessionConfig& config);

    // POST /api/gamezone/sessions/{code}/events - best effort; the reply deletes itself
    QNetworkReply* reportEvent(const SessionConfig& config, const QString& event, const QString& detail = QString());

signals:
    void sessionReady(Productify::SessionConfig config);
    void sessionFailed(QString message);
    void pinSubmissionFailed(QString message);

private:
    QNetworkReply* post(const QString& code, const QString& action, const QByteArray& body);
    static QString errorMessageFor(QNetworkReply* reply, const QByteArray& body);

    QNetworkAccessManager* m_Nam;
};

}

Q_DECLARE_METATYPE(Productify::SessionConfig)
