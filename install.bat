@echo off
REM ============================================================
REM  HEIMDALL WAF Installation Script for Windows
REM  CORRECT ARCHITECTURE: Main WAF as ingress, stub as control plane
REM  Updated: nginx points to main WAF (WAF_PORT), stub is internal only
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
echo   WAF will listen on: %WAF_PORT%
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

REM ---- Config port (for Envoy admin) ----
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

REM ---- Port conflict resolution for WAF_PORT ----
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

echo [STEP 1] Starting Heimdall Main WAF (Envoy + WASM)...
docker run -d --name apisphere-waf-%PLATFORM_ID% ^
    --add-host host.docker.internal:host-gateway ^
    -v apisphere-config-%PLATFORM_ID%:/app/config:ro ^
    -v C:\data\waf:/data/waf:ro ^
    -e PLATFORM_ID=%PLATFORM_ID% ^
    -e BACKEND_HOST=host.docker.internal ^
    -e BACKEND_PORT=%BACKEND_PORT% ^
    -e WAF_PORT=%WAF_PORT% ^
    -e WAF_CONFIG_PORT=%WAF_CONFIG_PORT% ^
    -p %WAF_PORT%:%WAF_PORT% ^
    %ECR_REPO%:%IMAGE_TAG% >nul 2>&1

echo [STATUS] Waiting for main WAF initialization (5 seconds)...
timeout /t 5 /nobreak >nul

docker exec apisphere-waf-%PLATFORM_ID% ls -l /app/config >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to start main WAF container
    exit /b 1
)

echo [OK] Main WAF started successfully on port %WAF_PORT%
echo.

REM ---- Stub container (control plane) - NO PUBLIC EXPOSURE ----
echo [STEP 2] Installing Heimdall stub (control plane – internal only)...
if not exist "C:\data\waf" mkdir C:\data\waf

echo   - Pulling stub image from Docker Hub...
docker pull nifzzy/waf-stub:latest >nul 2>&1

echo   - Removing any existing stub container...
docker stop waf-stub >nul 2>&1
docker rm waf-stub >nul 2>&1

echo   - Starting stub container (no host port exposure – only reachable internally)...
set STUB_BACKEND_URL=%BACKEND_URL:localhost=host.docker.internal%
docker run -d --restart=always ^
    --add-host host.docker.internal:host-gateway ^
    -v C:\data\waf:/data ^
    -e PLATFORM_ID=%PLATFORM_ID% ^
    -e BACKEND_URL=%STUB_BACKEND_URL% ^
    -e WAF_PORT=%WAF_PORT% ^
    --name waf-stub nifzzy/waf-stub:latest >nul 2>&1

if errorlevel 1 (
    echo [ERROR] Failed to start stub container.
    exit /b 1
)

echo [OK] Stub container started (internal, not exposed to host).
echo [INFO] The stub will automatically register its public IP with the backend.
echo.

REM ---- Final status output (CORRECT ARCHITECTURE) ----
echo.
echo ============================================================
echo [PROTECTION STATUS]
echo   Project ID:           %PLATFORM_ID%
echo   Your backend runs on: http://localhost:%BACKEND_PORT%
echo   Main WAF listens on:  http://localhost:%WAF_PORT%
echo   Stub (control plane): internal, no public port
echo   Config Admin Port:    %WAF_CONFIG_PORT%
echo.
echo [TRAFFIC FLOW - CORRECT ARCHITECTURE]
echo   Your gateway (nginx, Apache, Envoy) MUST proxy traffic to the MAIN WAF:
echo        proxy_pass http://localhost:%WAF_PORT%;
echo.
echo   The main WAF will:
echo     1. Detect SQLi / XSS attacks (block them)
echo     2. Forward clean requests to your backend (port %BACKEND_PORT%)
echo     3. Internally communicate with the stub for blacklist/rate-limit rules
echo.
echo   The stub is NOT in the data path – it only serves as control plane.
echo   Do NOT point your gateway to port 8081 (stub) – that would cause high latency.
echo.
echo [SECURITY VERIFICATION]
echo   Test a safe request (should reach your backend):
echo        curl -I http://localhost:%WAF_PORT%/
echo.
echo   Test SQLi attack (should be blocked with 403):
echo        curl "http://localhost:%WAF_PORT%/?id=1' OR '1'='1"
echo.
echo [MANAGEMENT COMMANDS]
echo   View main WAF logs:   docker logs apisphere-waf-%PLATFORM_ID%
echo   View stub logs:       docker logs waf-stub
echo   Stop main WAF:        docker stop apisphere-waf-%PLATFORM_ID%
echo   Restart main WAF:     docker start apisphere-waf-%PLATFORM_ID%
echo   Remove WAF:           docker rm -f apisphere-waf-%PLATFORM_ID%
echo   Remove volume:        docker volume rm apisphere-config-%PLATFORM_ID%
echo.
echo [IMPORTANT]
echo   The backend (Heimdall) must be updated to send blacklist/rate-limit
echo   updates to the main WAF (http://localhost:%WAF_PORT%/api/v1/waf/control)
echo   with header X-Heimdall-Control: true – NOT directly to the stub.
echo.
echo ============================================================
echo [SUCCESS] Heimdall WAF Installation Complete!