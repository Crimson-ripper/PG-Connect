// PG Connect branding and build-time settings.
//
// PG Connect is a modified version of Moonlight (https://moonlight-stream.org),
// distributed under the GNU GPL v3. "Moonlight" is a trademark of its authors; this
// product is not endorsed by or affiliated with the Moonlight Game Streaming Project.
#pragma once

#define PFY_APP_NAME        "PG Connect"
#define PFY_ORG_NAME        "Productify"
#define PFY_ORG_DOMAIN      "productifynow.com"
#define PFY_URL_SCHEME      "productify"
#define PFY_SOURCE_URL      "https://github.com/Crimson-ripper/productify-connect"  // TODO: confirm repo URL before first release

// Base URL of the Productify backend. Overridable at build time
// (qmake "DEFINES+=PFY_DEFAULT_API_BASE=\\\"https://...\\\"") and at run time with the
// PRODUCTIFY_API_BASE environment variable. Deep links can never change it.
// Development builds talk to the local mock backend (tools/mock-backend).
#ifndef PFY_DEFAULT_API_BASE
#define PFY_DEFAULT_API_BASE "http://127.0.0.1:8765"
#endif
