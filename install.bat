@echo off
REM APISphere WAF Installation Script for Windows
REM Enhanced with port conflict resolution

echo [SETUP] APISphere WAF Installation Starting...
echo.

if 1==0 (
    exit /b 1
)

set PLATFORM_ID=%~1
set BACKEND_PORT=%~2
if "%~3"=="" (set WAF_PORT=8080) else (set WAF_PORT=%~3)
set BACKEND_URL=%4
if "%BACKEND_URL%"=="" set BACKEND_URL=http://localhost:%BACKEND_PORT%



echo [CONFIG] Configuration:
echo   Platform ID: %PLATFORM_ID%
echo   Your app runs on: %BACKEND_PORT%
echo   WAF will run on: %WAF_PORT%
echo   Backend URL: %BACKEND_URL%
echo.

echo [CHECK] Verifying Docker availability...
docker --version >nul 2>&1
if errorlevel 1 (
    echo [WARN] Docker is not installed or not available in PATH.
    echo [INSTALL] Attempting to install Docker Desktop...
    
    REM Check if we have admin privileges
    net session >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] Docker installation requires administrator privileges.
        echo [ACTION] Please run this script as Administrator or install Docker Desktop manually:
        echo          https://www.docker.com/products/docker-desktop
        exit /b 1
    )
    
    REM Download and install Docker Desktop
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

echo [CHECK] Verifying Docker status...
docker info >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker is not running. Please start Docker Desktop and try again.
    exit /b 1
)
echo [OK] Docker is running

REM Detect architecture and set Docker platform
echo [DETECT] Detecting system architecture...
for /f "tokens=*" %%i in ('wmic os get osarchitecture ^| findstr /r "[0-9]"') do set ARCH=%%i
set ARCH=%ARCH: =%

REM Set Docker platform based on architecture
REM Windows typically runs amd64, but check for ARM64
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
    set DOCKER_PLATFORM=linux/arm64
) else (
    set DOCKER_PLATFORM=linux/amd64
)

echo [INFO] Architecture: %PROCESSOR_ARCHITECTURE%, Docker Platform: %DOCKER_PLATFORM%

REM Pull and run FastAPI WAF Config App to get WAF_CONFIG_PORT
echo.
echo [STEP 1] Config service skipped (using fallback port 8083).
set WAF_CONFIG_PORT=8083
echo [VOLUME] Creating persistent storage for project ID...
docker volume create apisphere-config-%PLATFORM_ID% >nul 2>&1

REM Store in Docker volume with proper permissions
echo %PLATFORM_ID% > temp_id
docker run --rm -i -v apisphere-config-%PLATFORM_ID%:/config busybox sh -c "cat > /config/PLATFORM_ID && chmod 644 /config/PLATFORM_ID" < temp_id
del temp_id

REM Store WAF_PORT in Docker volume
echo %WAF_PORT% > temp_waf
docker run --rm -i -v apisphere-config-%PLATFORM_ID%:/config busybox sh -c "cat > /config/WAF_PORT && chmod 644 /config/WAF_PORT" < temp_waf
del temp_waf

REM Verify storage
docker run --rm -v apisphere-config-%PLATFORM_ID%:/config busybox sh -c "ls -l /config && cat /config/PLATFORM_ID"

if errorlevel 1 (
    echo [ERROR] Failed to store PLATFORM_ID in Docker volume
    exit /b 1
)
echo [OK] Project ID stored securely in Docker volume

echo [STEP 2] Downloading APISphere WAF Protection Image
REM Public ECR repository URL format: public.ecr.aws/[registry-alias]/[repository-name]:[tag]
REM Private ECR repository URL format: [aws-account-id].dkr.ecr.[region].amazonaws.com/[repository-name]:[tag]

REM Replace with your actual ECR repository URL
set ECR_REPO=docker.io/sylviapaul/waf
set IMAGE_TAG=latest
REM ------------------------------------------------------------
REM Heimdall stub container (blacklist + rate limits)
REM ------------------------------------------------------------
echo.
echo [STEP 2] Installing Heimdall stub container...

if not exist "C:\data\waf" mkdir C:\data\waf

echo   - Pulling stub image from Docker Hub...
docker pull nifzzy/waf-stub:latest

echo   - Removing any existing stub container...
docker stop waf-stub >nul 2>&1
docker rm waf-stub >nul 2>&1

echo   - Starting stub container on port 8081...
docker run -d --restart=always -p 8081:8081 -v C:\data\waf:/data --name waf-stub nifzzy/waf-stub:latest

echo [OK] Stub container started on port 8081
REM ============================================================
REM Report stub URL to backend
REM ============================================================
echo.
echo [INFO] Detecting public IP address...
set PUBLIC_IP=
curl -s ifconfig.me/ip > pubip.tmp
set /p PUBLIC_IP=<pubip.tmp
del pubip.tmp
if defined PUBLIC_IP (
    echo [OK] Public IP detected: %PUBLIC_IP%
    ...
) else (
    echo [WARN] Could not detect public IP.
)

echo [PULL] Pulling WAF image for %PROCESSOR_ARCHITECTURE% (%DOCKER_PLATFORM%)...
docker pull --platform %DOCKER_PLATFORM% %ECR_REPO%:%IMAGE_TAG% >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to pull Docker image from Amazon ECR for %PROCESSOR_ARCHITECTURE%
    echo [TIP]  1. Check your internet connection
    echo        2. Verify ECR access: docker pull %ECR_REPO%:%IMAGE_TAG%
    echo        3. Try with VPN if on corporate network
    exit /b 1
)
echo [OK] WAF Protection image downloaded successfully
echo.

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

REM Check for port conflicts and resolve
echo [PORT] Checking port availability...
set PORT_CONFLICT=false
netstat -ano | findstr ":%WAF_PORT% " >nul && set PORT_CONFLICT=true
docker ps --format "{{.Ports}}" | findstr ":%WAF_PORT%" >nul && set PORT_CONFLICT=true

if "%PORT_CONFLICT%"=="true" (
    echo [WARN] Port %WAF_PORT% is already in use
    echo [RESOLVE] Attempting to resolve port conflict...
    
    REM Find and stop conflicting containers
    for /f "tokens=1" %%i in ('docker ps --format "{{.ID}} {{.Ports}}" ^| findstr ":%WAF_PORT%"') do (
        echo [CLEANUP] Stopping conflicting container: %%i
        docker stop %%i >nul 2>&1
        docker rm %%i >nul 2>&1
    )
    
    REM Verify port is now available
    netstat -ano | findstr ":%WAF_PORT% " >nul && (
        echo [ERROR] Port %WAF_PORT% still in use after cleanup
        echo [TIP]  1. Close applications using port %WAF_PORT%
        echo        2. Choose a different WAF_PORT
        echo        3. Run: netstat -ano | findstr ":%WAF_PORT%"
        exit /b 1
    )
    echo [OK] Port conflict resolved
)

echo [CLEANUP] Removing old WAF containers (if any)...
docker rm -f apisphere-waf-%PLATFORM_ID% >nul 2>&1

echo [STEP 3] Starting APISphere WAF Protection
echo [START] Starting WAF protection service...
docker run -d --name apisphere-waf-%PLATFORM_ID% ^
    -v apisphere-config-%PLATFORM_ID%:/app/config:ro ^
    -e PLATFORM_ID=%PLATFORM_ID% ^
    -e BACKEND_HOST=host.docker.internal ^
    -e BACKEND_PORT=%BACKEND_PORT% ^
    -e WAF_PORT=%WAF_PORT% ^
    -e WAF_CONFIG_PORT=%WAF_CONFIG_PORT% ^
    -p %WAF_PORT%:%WAF_PORT% ^
    %ECR_REPO%:%IMAGE_TAG% >nul 2>&1


echo [STATUS] Waiting for container initialization (5 seconds)...
timeout /t 5 /nobreak >nul

REM Verify PLATFORM_ID inside the running container
docker exec apisphere-waf-%PLATFORM_ID% ls -l /app/config
docker exec apisphere-waf-%PLATFORM_ID% cat /app/config/PLATFORM_ID

if errorlevel 1 (
    echo [ERROR] Failed to start WAF container
    exit /b 1
)

echo [OK] APISphere WAF started successfully
echo.
echo [SUCCESS] Installation Complete!
echo.
echo [PROTECTION STATUS]
echo   Project ID:           %PLATFORM_ID%
echo   Backend URL:          http://localhost:%BACKEND_PORT%
echo   Protected URL:        http://localhost:%WAF_PORT%
echo   Config Service Port:  %WAF_CONFIG_PORT%

echo.
echo [SECURITY VERIFICATION]
echo   Test safe request:
echo     curl -I http://localhost:%WAF_PORT%/
echo.
echo   Test blocked request:
echo     curl "http://localhost:%WAF_PORT%/?exec=/bin/bash"
echo.
echo [MANAGEMENT COMMANDS]
echo   View WAF logs:        docker logs apisphere-waf-%PLATFORM_ID%
echo   View Config logs:     docker logs %FASTAPI_CONTAINER_NAME%
echo   Stop WAF:             docker stop apisphere-waf-%PLATFORM_ID%
echo   Stop Config Service:  docker stop %FASTAPI_CONTAINER_NAME%
echo   Restart WAF:          docker start apisphere-waf-%PLATFORM_ID%
echo   Remove WAF:           docker rm -f apisphere-waf-%PLATFORM_ID%
echo   Remove Config:        docker rm -f %FASTAPI_CONTAINER_NAME%
echo   Remove volume:        docker volume rm apisphere-config-%PLATFORM_ID%
echo.
echo [PERSISTENCE INFO]
echo   PLATFORM_ID is stored in Docker volume:
echo     apisphere-config-%PLATFORM_ID%
echo.
echo [NOTE] All traffic should now go through the protected port!
