#pragma once

#include <QString>

namespace Productify
{

// Registers productify:// for the current user (HKCU\Software\Classes on Windows).
// The MSI installer does this at install time; this is for portable builds and is
// only run when the user invokes "PGConnect register-url-handler".
bool registerUrlHandler(QString* error);

}
