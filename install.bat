@echo off
REM ============================================================
REM  HEIMDALL WAF Installation Script for Windows
REM  Enhanced with port conflict resolution and stub self‑registration
REM  Updated: stub receives WAF_PORT, nginx points to stub (8081)
REM ============================================================

setlocal enabledelayedexpansion

echo [SETUP] HEIMDALL WAF Installation Starting...
echo.

REM ---- Parse arguments ----
set PLATFORM_ID=%~1
set BACKEND_PORT=%~2
if "%~3"=="" (set WAF_PORT=8080) else (set WAF_PORT=%~3)
set BACKEND_URL=https://staging.breachnet.io/api/v1

echo [CONFIG] Configuration:
echo   Platform ID: %PLATFORM_ID%
echo   Your app runs on: %BACKEND_PORT%
echo   WAF will run on: %WAF_PORT%
echo.

REM ---- Docker availability check ----
echo [CHECK] Verifying Docker availability...
docker --version >nul 2>&1
if errorlevel 1 (
    echo [WARN] Docker is not installed or not available in PATH.
    echo [INSTALL] Attempting to install Docker Desktop...
    
    net session >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] Docker installation requires administrator privileges.
        echo [ACTION] Please run this script as Administrator or install Docker Desktop manually:
        echo          https://www.docker.com/products/docker-desktop
        exit /b 1
    )
    
    echo [DOWNLOAD] Downloading Docker Desktop installer...
    powershell -Command "& {[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://desktop.docker.com/win/main/amd64/Docker%%20Desktop%%20Installer.exe' -OutFile 'DockerDesktopInstaller.exe'}"
    
    if not exist "DockerDesktopInstaller.exe" (
        echo [ERROR] Failed to download Docker Desktop installer.
        echo [TIP]  Please install Docker Desktop manually from https://www.docker.com/products/docker-desktop
        exit /b 1
    )
    
    echo [INSTALL] Installing Docker Desktop... This may take several minutes.
    "DockerDesktopInstaller.exe" install --quiet --accept-license
    
    if errorlevel 1 (
        echo [ERROR] Docker Desktop installation failed.
        echo [TIP]  Please install Docker Desktop manually from https://www.docker.com/products/docker-desktop
        del "DockerDesktopInstaller.exe" >nul 2>&1
        exit /b 1
    )
    
    del "DockerDesktopInstaller.exe" >nul 2>&1
    echo [OK] Docker Desktop installed successfully.
    echo [INFO] Please restart this script after Docker Desktop has fully started.
    echo [INFO] You may need to restart your computer for Docker to work properly.
    exit /b 0
)
echo [OK] Docker is available

REM ---- Docker running check ----
echo [CHECK] Verifying Docker status...
docker info >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker is not running. Please start Docker Desktop and try again.
    exit /b 1
)
echo [OK] Docker is running

REM ---- Architecture detection ----
echo [DETECT] Detecting system architecture...
for /f "tokens=*" %%i in ('wmic os get osarchitecture ^| findstr /r "[0-9]"') do set ARCH=%%i
set ARCH=%ARCH: =%
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
    set DOCKER_PLATFORM=linux/arm64
) else (
    set DOCKER_PLATFORM=linux/amd64
)
echo [INFO] Architecture: %PROCESSOR_ARCHITECTURE%, Docker Platform: %DOCKER_PLATFORM%

REM ---- Config port ----
set WAF_CONFIG_PORT=8083

REM ---- Persistent volume for configuration ----
echo [VOLUME] Creating persistent storage for project ID...
docker volume create apisphere-config-%PLATFORM_ID% >nul 2>&1

echo %PLATFORM_ID% > temp_id
docker run --rm -i -v apisphere-config-%PLATFORM_ID%:/config busybox sh -c "cat > /config/PLATFORM_ID && chmod 644 /config/PLATFORM_ID" < temp_id
del temp_id

echo %WAF_PORT% > temp_waf
docker run --rm -i -v apisphere-config-%PLATFORM_ID%:/config busybox sh -c "cat > /config/WAF_PORT && chmod 644 /config/WAF_PORT" < temp_waf
del temp_waf

docker run --rm -v apisphere-config-%PLATFORM_ID%:/config busybox sh -c "ls -l /config && cat /config/PLATFORM_ID" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to store PLATFORM_ID in Docker volume
    exit /b 1
)
echo [OK] Project ID stored securely in Docker volume

REM ---- Pull main WAF image ----
set ECR_REPO=docker.io/nifzzy/waf
set IMAGE_TAG=latest

echo [PULL] Pulling WAF image for %PROCESSOR_ARCHITECTURE% (%DOCKER_PLATFORM%)...
docker pull --platform %DOCKER_PLATFORM% %ECR_REPO%:%IMAGE_TAG% >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to pull Docker image for %PROCESSOR_ARCHITECTURE%
    echo [TIP]  1. Check your internet connection
    echo        2. Verify access: docker pull %ECR_REPO%:%IMAGE_TAG%
    echo        3. Try with VPN if on corporate network
    exit /b 1
)
echo [OK] WAF Protection image downloaded successfully
echo.

REM ---- Verify backend is listening ----
echo [CHECK] Verifying backend on port %BACKEND_PORT%...
set SERVICE_RUNNING=false
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%BACKEND_PORT%"') do (
    tasklist /FI "PID eq %%a" | findstr /i "java node python" >nul && set SERVICE_RUNNING=true
)
if "%SERVICE_RUNNING%"=="false" (
    echo [ERROR] No valid service detected on port %BACKEND_PORT%
    echo [TIP]  1. Ensure your app is running before installation
    echo        2. Confirm port matches your app configuration
    echo        3. Check for firewall blocking
    exit /b 1
)
echo [OK] Backend service confirmed

REM ---- Port conflict resolution ----
echo [PORT] Checking port availability...
set PORT_CONFLICT=false
netstat -ano | findstr ":%WAF_PORT% " >nul && set PORT_CONFLICT=true
docker ps --format "{{.Ports}}" | findstr ":%WAF_PORT%" >nul && set PORT_CONFLICT=true

if "%PORT_CONFLICT%"=="true" (
    echo [WARN] Port %WAF_PORT% is already in use
    echo [RESOLVE] Attempting to resolve port conflict...
    for /f "tokens=1" %%i in ('docker ps --format "{{.ID}} {{.Ports}}" ^| findstr ":%WAF_PORT%"') do (
        echo [CLEANUP] Stopping conflicting container: %%i
        docker stop %%i >nul 2>&1
        docker rm %%i >nul 2>&1
    )
    netstat -ano | findstr ":%WAF_PORT% " >nul && (
        echo [ERROR] Port %WAF_PORT% still in use after cleanup
        echo [TIP]  1. Close applications using port %WAF_PORT%
        echo        2. Choose a different WAF_PORT
        echo        3. Run: netstat -ano | findstr ":%WAF_PORT%"
        exit /b 1
    )
    echo [OK] Port conflict resolved
)

REM ---- Remove old main WAF container ----
echo [CLEANUP] Removing old WAF containers (if any)...
docker rm -f apisphere-waf-%PLATFORM_ID% >nul 2>&1

if not exist "C:\data\waf" mkdir C:\data\waf

echo [STEP 3] Starting Heimdall WAF Protection...
docker run -d --name apisphere-waf-%PLATFORM_ID% ^
    -v apisphere-config-%PLATFORM_ID%:/app/config:ro ^
    -v C:\data\waf:/data/waf:ro ^
    -e PLATFORM_ID=%PLATFORM_ID% ^
    -e BACKEND_HOST=host.docker.internal ^
    -e BACKEND_PORT=%BACKEND_PORT% ^
    -e WAF_PORT=%WAF_PORT% ^
    -e WAF_CONFIG_PORT=%WAF_CONFIG_PORT% ^
    -p %WAF_PORT%:%WAF_PORT% ^
    %ECR_REPO%:%IMAGE_TAG% >nul 2>&1

echo [STATUS] Waiting for container initialization (5 seconds)...
timeout /t 5 /nobreak >nul

docker exec apisphere-waf-%PLATFORM_ID% ls -l /app/config >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to start WAF container
    exit /b 1
)

echo [OK] Heimdall WAF started successfully
echo.
echo [SUCCESS] Main WAF Installation Complete!

REM ---- Stub container installation ----
echo.
echo [STEP 2] Installing Heimdall stub container...
if not exist "C:\data\waf" mkdir C:\data\waf

echo   - Pulling stub image from Docker Hub...
docker pull nifzzy/waf-stub:latest

echo   - Removing any existing stub container...
docker stop waf-stub >nul 2>&1
docker rm waf-stub >nul 2>&1

echo   - Starting stub container on port 8081...
set STUB_BACKEND_URL=%BACKEND_URL:localhost=host.docker.internal%
docker run -d --restart=always -p 8081:8081 ^
    -v C:\data\waf:/data ^
    -e PLATFORM_ID=%PLATFORM_ID% ^
    -e BACKEND_URL=%STUB_BACKEND_URL% ^
    -e WAF_PORT=%WAF_PORT% ^
    --name waf-stub nifzzy/waf-stub:latest >nul 2>&1

if errorlevel 1 (
    echo [ERROR] Failed to start stub container.
    exit /b 1
)

echo [OK] Heimdall stub container started successfully on port 8081.
echo [INFO] The stub will automatically register its public IP with the backend.
echo.

REM ---- Final status output ----
echo [PROTECTION STATUS]
echo   Project ID:           %PLATFORM_ID%
echo   Backend URL:          http://localhost:%BACKEND_PORT%
echo   Stub (front door):    http://localhost:8081 (forwards to main WAF)
echo   Main WAF (internal):  http://localhost:%WAF_PORT%
echo   Config Service Port:  %WAF_CONFIG_PORT%
echo.
echo [TRAFFIC FLOW]
echo   Nginx must be configured to proxy traffic to the STUB port:
echo     proxy_pass http://localhost:8081;
echo   Stub handles IP blacklisting + rate limiting, then forwards to main WAF.
echo   Main WAF handles SQLi/XSS detection and forwards to backend.
echo.
echo [SECURITY VERIFICATION]
echo   Test safe request:
echo     curl -I http://localhost:8081/
echo.
echo   Test blocked request (SQLi in query):
echo     curl "http://localhost:8081/?exec=/bin/bash"
echo.
echo [MANAGEMENT COMMANDS]
echo   View stub logs:       docker logs waf-stub
echo   View WAF logs:        docker logs apisphere-waf-%PLATFORM_ID%
echo   Stop WAF:             docker stop apisphere-waf-%PLATFORM_ID%
echo   Restart WAF:          docker start apisphere-waf-%PLATFORM_ID%
echo   Remove WAF:           docker rm -f apisphere-waf-%PLATFORM_ID%
echo   Remove volume:        docker volume rm apisphere-config-%PLATFORM_ID%
echo.
echo [NOTE] All incoming traffic must go through port 8081 (stub) for full protection.