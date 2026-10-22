@echo off
rem Productify Connect: local x64 development build (no MSI, no signing, no 7-Zip).
rem Release builds use scripts\build-arch.bat (see .github\workflows\productify-windows.yml).
rem
rem Usage: scripts\productify-build-dev.bat [debug|release] [path\to\Qt\6.12.0\msvc2022_64]
rem Needs: Visual Studio 2022 (Build Tools is enough) with the C++ workload, Qt 6.12.0 msvc2022_64,
rem        and the prebuilt dependencies from setup-deps.ps1. Uses jom.exe if it is on PATH.
setlocal enableDelayedExpansion

set BUILD_CONFIG=%1
if "%BUILD_CONFIG%"=="" set BUILD_CONFIG=release
set QT_DIR=%2
if "%QT_DIR%"=="" set QT_DIR=%~dp0..\..\.toolchain\Qt\6.12.0\msvc2022_64

set SOURCE_ROOT=%~dp0..
set BUILD_FOLDER=%SOURCE_ROOT%\build\dev-x64-%BUILD_CONFIG%
set DEPLOY_FOLDER=%SOURCE_ROOT%\build\dev-deploy-x64-%BUILD_CONFIG%

if not exist "%QT_DIR%\bin\qmake.exe" (
    echo Qt not found at %QT_DIR%
    exit /b 1
)
if not exist "%SOURCE_ROOT%\libs\windows\lib\x64\SDL2.dll" (
    echo Prebuilt dependencies missing: run "powershell -ExecutionPolicy Bypass -File setup-deps.ps1"
    exit /b 1
)

call "%SOURCE_ROOT%\scripts\find-vswhere.bat"
if !ERRORLEVEL! NEQ 0 exit /b 1
for /f "usebackq delims=" %%i in (`%VSWHERE% -latest -products * -property installationPath`) do (
    call "%%i\VC\Auxiliary\Build\vcvarsall.bat" x64
)
if !ERRORLEVEL! NEQ 0 exit /b 1

set PATH=%QT_DIR%\bin;%PATH%

where /q jom.exe
if !ERRORLEVEL! EQU 0 (set MAKE_CMD=jom.exe) else (set MAKE_CMD=nmake.exe)

if not exist "%BUILD_FOLDER%" mkdir "%BUILD_FOLDER%"
pushd "%BUILD_FOLDER%"
qmake.exe "%SOURCE_ROOT%\moonlight-qt.pro"
if !ERRORLEVEL! NEQ 0 (popd & exit /b 1)
%MAKE_CMD% %BUILD_CONFIG%
if !ERRORLEVEL! NEQ 0 (popd & echo Build failed & exit /b 1)
popd

if exist "%DEPLOY_FOLDER%" rmdir /s /q "%DEPLOY_FOLDER%"
mkdir "%DEPLOY_FOLDER%"
copy "%SOURCE_ROOT%\libs\windows\lib\x64\*.dll" "%DEPLOY_FOLDER%" >nul
copy "%BUILD_FOLDER%\AntiHooking\%BUILD_CONFIG%\AntiHooking.dll" "%DEPLOY_FOLDER%" >nul
copy "%SOURCE_ROOT%\app\SDL_GameControllerDB\gamecontrollerdb.txt" "%DEPLOY_FOLDER%" >nul
copy "%BUILD_FOLDER%\app\%BUILD_CONFIG%\ProductifyConnect.exe" "%DEPLOY_FOLDER%" >nul
copy "%SOURCE_ROOT%\LICENSE" "%DEPLOY_FOLDER%\LICENSE.txt" >nul
copy "%SOURCE_ROOT%\NOTICE.md" "%DEPLOY_FOLDER%\NOTICE.md" >nul

windeployqt.exe --dir "%DEPLOY_FOLDER%" --%BUILD_CONFIG% --qmldir "%SOURCE_ROOT%\app\gui" --no-opengl-sw --no-compiler-runtime --no-sql --no-system-d3d-compiler --no-system-dxc-compiler --skip-plugin-types qmltooling,generic --no-ffmpeg "%DEPLOY_FOLDER%\ProductifyConnect.exe"
if !ERRORLEVEL! NEQ 0 exit /b 1

for /f "usebackq delims=" %%i in (`%VSWHERE% -latest -products * -find VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT`) do set VC_REDIST_DLL_PATH=%%i
if defined VC_REDIST_DLL_PATH copy "%VC_REDIST_DLL_PATH%\*.dll" "%DEPLOY_FOLDER%" >nul

echo. > "%DEPLOY_FOLDER%\portable.dat"
echo Dev build ready: %DEPLOY_FOLDER%\ProductifyConnect.exe
exit /b 0
