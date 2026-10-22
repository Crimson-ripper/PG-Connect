#include "urlhandler.h"
#include "branding.h"

#include <QCoreApplication>
#include <QDir>
#include <QSettings>

namespace Productify
{

bool registerUrlHandler(QString* error)
{
#ifdef Q_OS_WIN32
    QString exe = QDir::toNativeSeparators(QCoreApplication::applicationFilePath());
    QSettings classes("HKEY_CURRENT_USER\\Software\\Classes\\" PFY_URL_SCHEME, QSettings::NativeFormat);
    classes.setValue(".", "URL:" PFY_APP_NAME " Protocol");
    classes.setValue("URL Protocol", "");
    classes.setValue("DefaultIcon/.", "\"" + exe + "\",0");
    classes.setValue("shell/open/command/.", "\"" + exe + "\" \"%1\"");
    classes.sync();
    if (classes.status() != QSettings::NoError) {
        *error = "could not write HKCU\\Software\\Classes\\" PFY_URL_SCHEME;
        return false;
    }
    return true;
#else
    // Linux: the .desktop file declares x-scheme-handler/productify. macOS: Info.plist CFBundleURLTypes.
    *error = "URL handler registration is done by the package on this platform";
    return false;
#endif
}

}
