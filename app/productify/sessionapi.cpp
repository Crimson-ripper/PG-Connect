#include "sessionapi.h"
#include "branding.h"
#include "wgtunnel.h"

#include <QCoreApplication>
#include <QHostInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSysInfo>
#include <QUrlQuery>

namespace Productify
{

static const int kRequestTimeoutMs = 15000;

QString SessionConfig::streamHost() const
{
    QString address = (networkMode == "wireguard") ? wireguard.hostTunnelAddress : hostAddress;
    if (hostHttpPort != 47989 && hostHttpPort > 0) {
        // IPv6 literals need brackets before a port suffix
        if (address.contains(':')) {
            address = "[" + address + "]";
        }
        return address + ":" + QString::number(hostHttpPort);
    }
    return address;
}

SessionApi::SessionApi(QObject* parent)
    : QObject(parent),
      m_Nam(new QNetworkAccessManager(this))
{
    qRegisterMetaType<Productify::SessionConfig>();
    m_Nam->setTransferTimeout(kRequestTimeoutMs);
}

QString SessionApi::normalizeCode(const QString& input)
{
    QString code = input.trimmed().toUpper();
    code.remove(QRegularExpression("[\\s-]"));
    static const QRegularExpression valid("^[A-Z0-9]{6,16}$");
    return valid.match(code).hasMatch() ? code : QString();
}

QString SessionApi::codeFromDeepLink(const QString& url)
{
    QUrl link(url, QUrl::StrictMode);
    if (!link.isValid() || link.scheme().toLower() != PFY_URL_SCHEME) {
        return QString();
    }
    // Accept productify://connect?code=X and productify:connect?code=X
    QString target = link.host().isEmpty() ? link.path() : link.host();
    if (target.toLower().remove('/') != "connect") {
        return QString();
    }
    return normalizeCode(QUrlQuery(link).queryItemValue("code"));
}

QUrl SessionApi::apiBase()
{
    QString base = qEnvironmentVariable("PRODUCTIFY_API_BASE", PFY_DEFAULT_API_BASE);
    while (base.endsWith('/')) {
        base.chop(1);
    }
    QUrl url(base);

    // Session responses carry pairing PINs and tunnel keys: plain HTTP is only
    // acceptable for a backend on this machine (the mock backend).
    const QString host = url.host().toLower();
    bool local = host == "localhost" || host == "127.0.0.1" || host == "::1";
    if (url.scheme() != "https" && !(url.scheme() == "http" && local)) {
        return QUrl();
    }
    return url;
}

QNetworkReply* SessionApi::post(const QString& code, const QString& action, const QByteArray& body)
{
    QUrl base = apiBase();
    QUrl url(base.toString() + "/api/gamezone/sessions/" +
             QString::fromLatin1(QUrl::toPercentEncoding(code)) + "/" + action);

    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QString("PGConnect/%1 (%2)").arg(QCoreApplication::applicationVersion(),
                                                              QSysInfo::prettyProductName()));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    return m_Nam->post(request, body);
}

QString SessionApi::errorMessageFor(QNetworkReply* reply, const QByteArray& body)
{
    int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();

    // FastAPI style {"detail": "..."} or {"detail": {"message": "..."}}
    QJsonObject obj = QJsonDocument::fromJson(body).object();
    QString detail;
    if (obj["detail"].isString()) {
        detail = obj["detail"].toString();
    }
    else if (obj["detail"].isObject()) {
        detail = obj["detail"].toObject()["message"].toString();
    }

    switch (status) {
    case 404:
        return tr("That session code was not found. Check the code on your Productify session page.");
    case 410:
        return tr("That session code has expired or was already used. Start a new session on productifynow.com.");
    case 409:
        return detail.isEmpty() ? tr("Your gaming machine is still starting. Try again in a minute.") : detail;
    case 429:
        return tr("Too many attempts. Wait a minute and try again.");
    case 0:
        return tr("Could not reach Productify: %1").arg(reply->errorString());
    default:
        return detail.isEmpty() ? tr("Productify returned an error (HTTP %1).").arg(status) : detail;
    }
}

void SessionApi::connectSession(const QString& code, const QString& wgPublicKey)
{
    if (apiBase().isEmpty()) {
        emit sessionFailed(tr("This build has an invalid Productify server address (HTTPS is required)."));
        return;
    }

    QJsonObject client;
    client["name"] = PFY_APP_NAME;
    client["version"] = QCoreApplication::applicationVersion();
    client["platform"] = QSysInfo::productType() + "-" + QSysInfo::currentCpuArchitecture();
    client["device_name"] = QHostInfo::localHostName();

    QJsonObject body;
    body["client"] = client;
    body["supports"] = QJsonObject{{"wireguard", WireGuardTunnel::isSupported()}};
    if (!wgPublicKey.isEmpty()) {
        body["wireguard_public_key"] = wgPublicKey;
    }

    QNetworkReply* reply = post(code, "connect", QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, code]() {
        reply->deleteLater();
        QByteArray data = reply->readAll();

        if (reply->error() != QNetworkReply::NoError) {
            emit sessionFailed(errorMessageFor(reply, data));
            return;
        }

        QJsonObject obj = QJsonDocument::fromJson(data).object();
        QJsonObject host = obj["host"].toObject();
        QJsonObject pairing = obj["pairing"].toObject();
        QJsonObject app = obj["app"].toObject();
        QJsonObject network = obj["network"].toObject();

        SessionConfig config;
        config.code = code;
        config.sessionId = obj["session_id"].toString();
        config.expiresAt = obj["expires_at"].toString();
        config.hostName = host["name"].toString();
        config.hostAddress = host["address"].toString();
        config.hostHttpPort = host["http_port"].toInt(47989);
        config.pairingMode = pairing["mode"].toString("pin");
        config.pin = pairing["pin"].toString();
        config.pairToken = pairing["pair_token"].toString();
        config.appName = app["name"].toString();
        config.networkMode = network["mode"].toString("direct");

        if (config.networkMode == "wireguard") {
            QJsonObject wg = network["wireguard"].toObject();
            config.wireguard.interfaceAddress = wg["interface_address"].toString();
            config.wireguard.peerPublicKey = wg["peer_public_key"].toString();
            config.wireguard.presharedKey = wg["preshared_key"].toString();
            config.wireguard.endpoint = wg["endpoint"].toString();
            config.wireguard.allowedIps = wg["allowed_ips"].toString();
            config.wireguard.hostTunnelAddress = wg["host_tunnel_address"].toString();
            config.wireguard.mtu = wg["mtu"].toInt(1420);
            config.wireguard.persistentKeepalive = wg["persistent_keepalive"].toInt(25);
        }

        QString problem;
        if (config.appName.isEmpty()) {
            problem = "app.name";
        }
        else if (config.networkMode == "direct" && config.hostAddress.isEmpty()) {
            problem = "host.address";
        }
        else if (config.networkMode == "wireguard" &&
                 (config.wireguard.peerPublicKey.isEmpty() || config.wireguard.endpoint.isEmpty() ||
                  config.wireguard.hostTunnelAddress.isEmpty() || config.wireguard.interfaceAddress.isEmpty())) {
            problem = "network.wireguard";
        }
        else if (config.networkMode != "direct" && config.networkMode != "wireguard") {
            problem = "network.mode";
        }
        else if (config.pairingMode == "pin" && !QRegularExpression("^[0-9]{4}$").match(config.pin).hasMatch()) {
            problem = "pairing.pin";
        }

        if (!problem.isEmpty()) {
            emit sessionFailed(tr("Productify sent an incomplete session (%1). Please contact support.").arg(problem));
            return;
        }

        emit sessionReady(config);
    });
}

void SessionApi::requestPinSubmission(const SessionConfig& config)
{
    QJsonObject body{{"pair_token", config.pairToken}, {"session_id", config.sessionId}};
    QNetworkReply* reply = post(config.code, "pairing", QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        QByteArray data = reply->readAll();
        if (reply->error() != QNetworkReply::NoError) {
            emit pinSubmissionFailed(errorMessageFor(reply, data));
        }
    });
}

QNetworkReply* SessionApi::reportEvent(const SessionConfig& config, const QString& event, const QString& detail)
{
    QJsonObject body{{"session_id", config.sessionId}, {"event", event}};
    if (!detail.isEmpty()) {
        body["detail"] = detail;
    }
    QNetworkReply* reply = post(config.code, "events", QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, reply, &QObject::deleteLater);
    return reply;
}

}
