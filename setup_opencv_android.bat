@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: setup_opencv_android.bat
:: Downloads OpenCV 4.10.0 Android SDK and writes the path to
:: android/local.properties so the NDK build can find it.
::
:: Run once from the project root:
::   cd shelf_monitor_app
::   setup_opencv_android.bat
:: ============================================================

set OPENCV_VERSION=4.10.0
set OPENCV_ZIP=opencv-%OPENCV_VERSION%-android-sdk.zip
set OPENCV_URL=https://github.com/opencv/opencv/releases/download/%OPENCV_VERSION%/%OPENCV_ZIP%
set INSTALL_DIR=%~dp0OpenCV-android-sdk

echo ============================================================
echo  OpenCV %OPENCV_VERSION% Android SDK Setup
echo ============================================================
echo.

:: ---- Check if already installed --------------------------------
if exist "%INSTALL_DIR%\sdk\native\jni\OpenCVConfig.cmake" (
    echo [OK] OpenCV SDK already present at:
    echo      %INSTALL_DIR%
    goto :write_props
)

:: ---- Download --------------------------------------------------
echo [1/3] Downloading %OPENCV_ZIP% ...
echo       Source: %OPENCV_URL%
echo.

where curl >nul 2>&1
if %errorlevel% equ 0 (
    curl -L --progress-bar -o "%OPENCV_ZIP%" "%OPENCV_URL%"
) else (
    echo curl not found — trying PowerShell ...
    powershell -Command "& { $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%OPENCV_URL%' -OutFile '%OPENCV_ZIP%' }"
)

if not exist "%OPENCV_ZIP%" (
    echo.
    echo [ERROR] Download failed. Please download manually:
    echo   %OPENCV_URL%
    echo and extract to:
    echo   %INSTALL_DIR%
    echo Then re-run this script.
    pause
    exit /b 1
)

:: ---- Extract ---------------------------------------------------
echo.
echo [2/3] Extracting to %INSTALL_DIR% ...
powershell -Command "& { Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::ExtractToDirectory('%~dp0%OPENCV_ZIP%', '%~dp0') }"

:: The zip contains a top-level folder named "OpenCV-android-sdk"
if not exist "%INSTALL_DIR%" (
    echo [ERROR] Extraction failed or unexpected folder structure.
    pause
    exit /b 1
)

:: Clean up zip
del "%OPENCV_ZIP%" >nul 2>&1

echo [OK] Extraction complete.

:write_props
:: ---- Write local.properties ------------------------------------
echo.
echo [3/3] Writing opencv.sdk.path to android\local.properties ...

set PROPS_FILE=%~dp0android\local.properties

:: Normalise backslashes to forward slashes for Gradle
set OPENCV_PATH_FWD=%INSTALL_DIR:\=/%

:: Remove existing opencv.sdk.path line if present, then append
if exist "%PROPS_FILE%" (
    :: Use PowerShell to filter out the old entry cleanly
    powershell -Command "& { (Get-Content '%PROPS_FILE%') | Where-Object { $_ -notmatch '^opencv\.sdk\.path' } | Set-Content '%PROPS_FILE%' }"
)

echo opencv.sdk.path=%OPENCV_PATH_FWD%>> "%PROPS_FILE%"

echo.
echo ============================================================
echo  Setup complete!
echo  SDK path: %OPENCV_PATH_FWD%
echo ============================================================
echo.
echo Next steps:
echo   1. flutter pub get
echo   2. flutter build apk --release
echo   3. flutter install --release
echo.
pause
