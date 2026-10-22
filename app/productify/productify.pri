# Productify Connect additions, kept out of upstream's app.pro as far as possible.
SOURCES += \
    $$PWD/sessionapi.cpp \
    $$PWD/wgtunnel.cpp \
    $$PWD/joinlauncher.cpp \
    $$PWD/urlhandler.cpp

HEADERS += \
    $$PWD/branding.h \
    $$PWD/sessionapi.h \
    $$PWD/wgtunnel.h \
    $$PWD/joinlauncher.h \
    $$PWD/urlhandler.h

# Production builds set PFY_API_BASE (qmake variable or environment variable).
isEmpty(PFY_API_BASE): PFY_API_BASE = $$(PFY_API_BASE)
!isEmpty(PFY_API_BASE) {
    DEFINES += PFY_DEFAULT_API_BASE=\\\"$$PFY_API_BASE\\\"
}

win32 {
    LIBS += -lshell32
}
