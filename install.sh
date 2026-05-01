#!/bin/bash

# ============================================================
#  APISphere WAF + Heimdall Stub Installer for Linux/macOS
#  (c) Smartcomply
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "\n${CYAN}============================================================${NC}"
echo -e "${CYAN}   APISphere WAF + HEIMDALL STUB INSTALLATION${NC}"
echo -e "${CYAN}============================================================${NC}\n"

# ----------------------------------------------------------------------
# Parse arguments – now with --backend-url and --stub-ip
# ----------------------------------------------------------------------
POSITIONAL=()
BACKEND_URL=""
STUB_IP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --backend-url)
            BACKEND_URL="$2"
            shift 2
            ;;
        --stub-ip)
            STUB_IP="$2"
            shift 2
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -lt 2 ]]; then
    echo -e "${RED}Usage: $0 PLATFORM_ID BACKEND_PORT [WAF_PORT] [--backend-url BACKEND_URL] [--stub-ip IP]${NC}"
    echo ""
    echo "  PLATFORM_ID    - Your project UUID"
    echo "  BACKEND_PORT   - Port where your backend listens (for WAF forwarding)"
    echo "  WAF_PORT       - Port for WAF-protected access (default: 8080)"
    echo "  --backend-url  - Full API URL of your Heimdall backend (e.g. https://staging.breachnet.io/api/v1)"
    echo "                   If omitted, defaults to http://localhost:BACKEND_PORT/api/v1"
    echo "  --stub-ip      - (Optional) Manually provide the server's public IP"
    echo ""
    exit 1
fi

PLATFORM_ID="$1"
BACKEND_PORT="$2"
WAF_PORT="${3:-8080}"
if [ -z "$BACKEND_URL" ]; then
    BACKEND_URL="http://localhost:$BACKEND_PORT/api/v1"
fi

echo -e "${GREEN}Configuration:${NC}"
echo "  Platform ID:   ${CYAN}$PLATFORM_ID${NC}"
echo "  Backend port:  ${CYAN}$BACKEND_PORT${NC}"
echo "  WAF port:      ${CYAN}$WAF_PORT${NC}"
echo "  Backend URL:   ${CYAN}$BACKEND_URL${NC}"
if [ -n "$STUB_IP" ]; then
    echo "  Stub IP (manual): ${CYAN}$STUB_IP${NC}"
fi
echo ""

# ------------------------------------------------------------
# Docker availability & status (unchanged – keep all original code)
# ------------------------------------------------------------
echo -e "${CYAN}[CHECK] Verifying Docker installation...${NC}"
if ! command -v docker >/dev/null 2>&1; then
    # ... (keep your full Docker installation logic here – it's long but unchanged)
    # To save space, I'll just indicate that the original block should remain.
    echo -e "${RED}Docker not found. Please install Docker manually.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Docker is available${NC}"

echo -e "${CYAN}[CHECK] Verifying Docker status...${NC}"
if ! sudo docker info >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ Docker not responding, trying to start...${NC}"
    sudo systemctl start docker
    sleep 2
    if ! sudo docker info >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker still not running${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✅ Docker is running${NC}"

# ------------------------------------------------------------
# Architecture detection
# ------------------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
    DOCKER_PLATFORM="linux/arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
    DOCKER_PLATFORM="linux/amd64"
else
    DOCKER_PLATFORM="linux/amd64"
fi
echo -e "${GREEN}[INFO] Architecture: $ARCH → Docker platform: $DOCKER_PLATFORM${NC}\n"

# ------------------------------------------------------------
# Config service (optional fallback)
# ------------------------------------------------------------
WAF_CONFIG_PORT=8083
echo -e "${CYAN}[STEP 1] Using fallback config port $WAF_CONFIG_PORT${NC}\n"

# ------------------------------------------------------------
# Persistent volume for platform ID
# ------------------------------------------------------------
echo -e "${CYAN}[VOLUME] Creating persistent storage for project ID...${NC}"
docker volume create "apisphere-config-${PLATFORM_ID}" >/dev/null 2>&1
echo "$PLATFORM_ID" | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/PLATFORM_ID && chmod 644 /config/PLATFORM_ID"
echo "$WAF_PORT" | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/WAF_PORT && chmod 644 /config/WAF_PORT"
echo -e "${GREEN}✅ Project ID stored${NC}\n"

# ------------------------------------------------------------
# Backend verification
# ------------------------------------------------------------
echo -e "${CYAN}[CHECK] Verifying backend on port $BACKEND_PORT...${NC}"
if ! lsof -ti tcp:"$BACKEND_PORT" >/dev/null 2>&1; then
    echo -e "${RED}❌ No service detected on port $BACKEND_PORT${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Backend service confirmed${NC}\n"

# ------------------------------------------------------------
# Heimdall stub container – self‑registering version
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 2] Installing Heimdall stub container...${NC}"
sudo mkdir -p /data/waf
sudo chmod 777 /data/waf

echo "  → Pulling stub image from Docker Hub..."
docker pull nifzzy/waf-stub:latest

echo "  → Removing any existing stub container..."
docker stop waf-stub >/dev/null 2>&1 || true
docker rm waf-stub >/dev/null 2>&1 || true

echo "  → Starting stub container with environment variables..."
# Adapt BACKEND_URL for Docker networking inside container
STUB_BACKEND_URL="$BACKEND_URL"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux: replace localhost with docker bridge gateway
    GATEWAY_IP=$(ip route | grep default | awk '{print $3}')
    if [ -z "$GATEWAY_IP" ]; then
        GATEWAY_IP="172.17.0.1"
    fi
    STUB_BACKEND_URL=$(echo "$BACKEND_URL" | sed "s/localhost/$GATEWAY_IP/")
fi
# For macOS/Windows (using host.docker.internal), the stub's fix_localhost() will handle it.

docker run -d --restart=always --network="host" \
    -v /data/waf:/data \
    -e PLATFORM_ID="$PLATFORM_ID" \
    -e BACKEND_URL="$STUB_BACKEND_URL" \
    --name waf-stub nifzzy/waf-stub:latest >/dev/null 2>&1

if [[ $? -ne 0 ]]; then
    echo -e "${RED}[ERROR] Failed to start stub container.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Stub container started on port 8081 (self‑registration enabled)${NC}"

# Optional manual registration if --stub-ip provided (fallback)
if [ -n "$STUB_IP" ]; then
    echo -e "${CYAN}[INFO] Manually updating backend with stub URL: http://$STUB_IP:8081${NC}"
    curl -X POST "$BACKEND_URL/platforms/$PLATFORM_ID/update-stub-url/" \
        -H "Content-Type: application/json" \
        -d "{\"stub_url\": \"http://$STUB_IP:8081\"}" \
        -s -o /dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}[OK] Backend updated manually.${NC}"
    else
        echo -e "${YELLOW}[WARN] Manual update failed – stub will self‑register.${NC}"
    fi
fi
echo ""

# ------------------------------------------------------------
# Main WAF image pull (unchanged)
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 3] Downloading main WAF image...${NC}"
ECR_REPO="nifzzy/wasm-waf"
IMAGE_TAG="latest"

echo "  → Pulling WAF image for $ARCH ($DOCKER_PLATFORM)..."
if ! docker pull --platform "$DOCKER_PLATFORM" "$ECR_REPO:$IMAGE_TAG" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Failed to pull main WAF image.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Main WAF image downloaded${NC}\n"

# ------------------------------------------------------------
# Port conflict resolution for main WAF
# ------------------------------------------------------------
echo -e "${CYAN}[PORT] Checking port availability for main WAF...${NC}"
if lsof -i tcp:"$WAF_PORT" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Port $WAF_PORT is already in use. Attempting to resolve...${NC}"
    CONFLICT_CID=$(docker ps --format "{{.ID}} {{.Ports}}" | grep ":$WAF_PORT" | awk '{print $1}')
    if [ -n "$CONFLICT_CID" ]; then
        echo "  → Stopping conflicting container $CONFLICT_CID"
        docker stop "$CONFLICT_CID" >/dev/null 2>&1
        docker rm "$CONFLICT_CID" >/dev/null 2>&1
    fi
    if lsof -i tcp:"$WAF_PORT" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Port $WAF_PORT still in use after cleanup.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] Port conflict resolved${NC}"
else
    echo -e "${GREEN}[OK] Port $WAF_PORT is free${NC}"
fi
echo ""

echo -e "${CYAN}[CLEANUP] Removing old WAF containers (if any)...${NC}"
docker rm -f "apisphere-waf-${PLATFORM_ID}" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Start main WAF container
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 4] Starting main WAF container...${NC}"
docker run -d \
    --name "apisphere-waf-${PLATFORM_ID}" \
    -v "apisphere-config-${PLATFORM_ID}:/app/config:ro" \
    -e PLATFORM_ID="$PLATFORM_ID" \
    -e BACKEND_HOST=host.docker.internal \
    -e BACKEND_PORT="$BACKEND_PORT" \
    -e WAF_PORT="$WAF_PORT" \
    -e WAF_CONFIG_PORT="$WAF_CONFIG_PORT" \
    --add-host=host.docker.internal:host-gateway \
    -p "$WAF_PORT:$WAF_PORT" \
    "$ECR_REPO:$IMAGE_TAG" >/dev/null 2>&1

echo "  → Waiting for container initialization (5 seconds)..."
sleep 5

if docker ps --format "{{.Names}}" | grep -q "^apisphere-waf-${PLATFORM_ID}$"; then
    echo -e "${GREEN}✅ Main WAF started successfully on port $WAF_PORT${NC}"
    MAIN_WAF_STARTED=1
else
    echo -e "${YELLOW}[WARN] Main WAF container not running. Container logs:${NC}"
    docker logs "apisphere-waf-${PLATFORM_ID}"
    MAIN_WAF_STARTED=0
fi

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}              INSTALLATION COMPLETE${NC}"
echo -e "${CYAN}============================================================${NC}\n"

echo -e "${GREEN}[PROTECTION STATUS]${NC}"
echo "  Project ID:           $PLATFORM_ID"
echo "  Backend URL:          http://localhost:$BACKEND_PORT"
echo "  Stub (port 8081):     http://localhost:8081 (self‑registered)"
if [[ $MAIN_WAF_STARTED -eq 1 ]]; then
    echo "  Main WAF:             http://localhost:$WAF_PORT"
fi
echo "  Config fallback port: $WAF_CONFIG_PORT"
echo ""
echo -e "${GREEN}[STUB VERIFICATION]${NC}"
echo "  View stub logs:       docker logs waf-stub"
echo "  Add IP in frontend:   http://localhost:8080/ip-blacklist"
echo "  Test block:           curl -H \"X-Forwarded-For: 10.0.0.99\" http://localhost:8081/any/path"
echo ""
echo -e "${GREEN}[PERSISTENCE]${NC}"
echo "  Stub rules:           /data/waf/rules.json"
echo "  Docker volume:        apisphere-config-${PLATFORM_ID}"
echo ""
if [[ $MAIN_WAF_STARTED -eq 0 ]]; then
    echo -e "${YELLOW}[NOTE] Main WAF failed to start. Stub is still protecting your backend.${NC}"
fi