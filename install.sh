#!/bin/bash
# ============================================================
#  Heimdall WAF for Linux/macOS
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "\n${CYAN}============================================================${NC}"
echo -e "${CYAN}         HEIMDALL WAF INSTALLATION SCRIPT${NC}"
echo -e "${CYAN}============================================================${NC}\n"

POSITIONAL=()
BACKEND_URL=""
STUB_IP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --backend-url) BACKEND_URL="$2"; shift 2 ;;
        --stub-ip) STUB_IP="$2"; shift 2 ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -lt 2 ]]; then
    echo -e "${RED}Usage: $0 PLATFORM_ID BACKEND_PORT [WAF_PORT] [--backend-url URL] [--stub-ip IP]${NC}"
    exit 1
fi

PLATFORM_ID="$1"
BACKEND_PORT="$2"
WAF_PORT="${3:-8080}"

if [ -z "$BACKEND_URL" ]; then
    if [ "$BACKEND_PORT" = "8000" ] && [[ "$OSTYPE" != "linux-gnu"* ]]; then
        BACKEND_URL="http://localhost:$BACKEND_PORT/api/v1"
        echo -e "${YELLOW}⚠️  No --backend-url provided. Using $BACKEND_URL (local dev only).${NC}"
    else
        echo -e "${RED}❌ ERROR: --backend-url is required.${NC}"
        echo "   Example: --backend-url https://staging.breachnet.io/api/v1"
        exit 1
    fi
fi

echo -e "${GREEN}Configuration:${NC}"
echo "  Platform ID:   ${CYAN}$PLATFORM_ID${NC}"
echo "  Backend port:  ${CYAN}$BACKEND_PORT${NC}"
echo "  WAF port:      ${CYAN}$WAF_PORT${NC}"
echo "  Backend URL:   ${CYAN}$BACKEND_URL${NC}"
[ -n "$STUB_IP" ] && echo "  Stub IP:       ${CYAN}$STUB_IP${NC}"
echo ""

# ------------------------------------------------------------
# Docker check
# ------------------------------------------------------------
echo -e "${CYAN}[CHECK] Verifying Docker installation...${NC}"
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}❌ Docker not found.${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew >/dev/null 2>&1; then
            brew install --cask docker
            echo -e "${GREEN}✅ Docker Desktop installed. Start it from Applications, then rerun.${NC}"
            exit 0
        else
            echo -e "${RED}Install Docker Desktop manually: https://www.docker.com/products/docker-desktop${NC}"
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gnupg lsb-release
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            sudo systemctl start docker && sudo systemctl enable docker
            sudo usermod -aG docker "$USER"
            echo -e "${GREEN}✅ Docker installed. Log out and back in, then rerun.${NC}"
            exit 0
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            sudo systemctl start docker && sudo systemctl enable docker
            sudo usermod -aG docker "$USER"
            echo -e "${GREEN}✅ Docker installed. Log out and back in, then rerun.${NC}"
            exit 0
        else
            echo -e "${RED}Unsupported distro. Install Docker manually.${NC}"; exit 1
        fi
    else
        echo -e "${RED}Unsupported OS.${NC}"; exit 1
    fi
fi
echo -e "${GREEN}✅ Docker is available${NC}"

echo -e "${CYAN}[CHECK] Verifying Docker status...${NC}"
if ! docker info >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ Docker not running. Attempting to start...${NC}"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo systemctl start docker
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        open -a Docker
        echo -e "${YELLOW}Waiting 15s for Docker Desktop...${NC}"
        sleep 15
    fi
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}❌ Could not start Docker. Start Docker Desktop manually and rerun.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✅ Docker is running${NC}"

# ------------------------------------------------------------
# Architecture
# ------------------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
    DOCKER_PLATFORM="linux/arm64"
else
    DOCKER_PLATFORM="linux/amd64"
fi
echo -e "${GREEN}[INFO] Architecture: $ARCH → $DOCKER_PLATFORM${NC}\n"

WAF_CONFIG_PORT=8083

# ------------------------------------------------------------
# Persistent volume
# ------------------------------------------------------------
echo -e "${CYAN}[VOLUME] Creating persistent storage...${NC}"
docker volume create "apisphere-config-${PLATFORM_ID}" >/dev/null 2>&1
echo "$PLATFORM_ID" | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/PLATFORM_ID && chmod 644 /config/PLATFORM_ID"
echo "$WAF_PORT"    | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/WAF_PORT && chmod 644 /config/WAF_PORT"
echo -e "${GREEN}✅ Project ID stored${NC}\n"

# ------------------------------------------------------------
# Backend port check  (lsof on macOS, ss on Linux)
# ------------------------------------------------------------
echo -e "${CYAN}[CHECK] Verifying backend on port $BACKEND_PORT...${NC}"
PORT_IN_USE=false
if [[ "$OSTYPE" == "darwin"* ]]; then
    lsof -ti tcp:"$BACKEND_PORT" >/dev/null 2>&1 && PORT_IN_USE=true
else
    ss -tlnp 2>/dev/null | grep -q ":${BACKEND_PORT}[[:space:]]" && PORT_IN_USE=true
fi
if [ "$PORT_IN_USE" = false ]; then
    echo -e "${RED}❌ No service on port $BACKEND_PORT. Start your backend first.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Backend confirmed on port $BACKEND_PORT${NC}\n"

# ------------------------------------------------------------
# Stub container
# FIX: --network=host is unsupported on macOS Docker Desktop.
#      Use -p 8081:8081 on macOS; keep --network=host on Linux
#      (host networking gives the stub the real public IP on Linux).
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 2] Installing Heimdall stub container...${NC}"

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo mkdir -p /data/waf && sudo chmod 777 /data/waf
    DATA_MOUNT="/data/waf"
else
    mkdir -p "$HOME/.heimdall/waf"
    DATA_MOUNT="$HOME/.heimdall/waf"
fi

echo "  → Pulling stub image..."
docker pull nifzzy/waf-stub:latest

echo "  → Removing existing stub container..."
docker stop waf-stub >/dev/null 2>&1 || true
docker rm   waf-stub >/dev/null 2>&1 || true

# Resolve BACKEND_URL for inside-container networking
STUB_BACKEND_URL="$BACKEND_URL"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    GATEWAY_IP=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1)
    [ -z "$GATEWAY_IP" ] && GATEWAY_IP="172.17.0.1"
    STUB_BACKEND_URL=$(echo "$BACKEND_URL" | sed "s/localhost/$GATEWAY_IP/g")
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # host.docker.internal resolves correctly on macOS Docker Desktop
    STUB_BACKEND_URL=$(echo "$BACKEND_URL" | sed "s/localhost/host.docker.internal/g")
fi

echo -e "${CYAN}[INFO] Stub will register to: $STUB_BACKEND_URL${NC}"

# FIX: macOS gets -p flag; Linux gets --network=host so stub sees public IP
if [[ "$OSTYPE" == "darwin"* ]]; then
    STUB_RUN_CMD=(docker run -d --restart=always
        -p 8081:8081
        -v "${DATA_MOUNT}:/data"
        -e PLATFORM_ID="$PLATFORM_ID"
        -e BACKEND_URL="$STUB_BACKEND_URL"
        --name waf-stub
        nifzzy/waf-stub:latest)
else
    STUB_RUN_CMD=(docker run -d --restart=always
        --network=host
        -v "${DATA_MOUNT}:/data"
        -e PLATFORM_ID="$PLATFORM_ID"
        -e BACKEND_URL="$STUB_BACKEND_URL"
        --name waf-stub
        nifzzy/waf-stub:latest)
fi

# FIX: don't redirect stderr — capture failure and print logs
if ! "${STUB_RUN_CMD[@]}"; then
    echo -e "${RED}[ERROR] Failed to start stub container. Logs:${NC}"
    docker logs waf-stub 2>/dev/null || true
    exit 1
fi

# FIX: open firewall on Linux so backend can actually reach stub
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if command -v ufw >/dev/null 2>&1; then
        sudo ufw allow 8081/tcp >/dev/null 2>&1 && echo -e "${GREEN}✅ ufw: port 8081 opened${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --add-port=8081/tcp >/dev/null 2>&1
        sudo firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}✅ firewalld: port 8081 opened${NC}"
    fi
fi

# Give stub 5s to start and attempt self-registration
echo "  → Waiting for stub to start and register..."
sleep 5

# Verify stub is actually running
if ! docker ps --format "{{.Names}}" | grep -q "^waf-stub$"; then
    echo -e "${RED}[ERROR] Stub container exited immediately. Logs:${NC}"
    docker logs waf-stub
    exit 1
fi
echo -e "${GREEN}✅ Stub container running on port 8081${NC}"

# Verify self-registration in logs
if docker logs waf-stub 2>&1 | grep -qi "registered\|registration"; then
    echo -e "${GREEN}✅ Stub self-registration attempted${NC}"
else
    echo -e "${YELLOW}⚠️  No registration log found. Check: docker logs waf-stub${NC}"
fi

# Optional manual registration fallback
if [ -n "$STUB_IP" ]; then
    echo -e "${CYAN}[INFO] Manually registering stub: http://$STUB_IP:8081${NC}"
    curl -s -o /dev/null -X POST "$BACKEND_URL/platforms/$PLATFORM_ID/update-stub-url/" \
        -H "Content-Type: application/json" \
        -d "{\"stub_url\": \"http://$STUB_IP:8081\"}" \
        && echo -e "${GREEN}[OK] Backend updated.${NC}" \
        || echo -e "${YELLOW}[WARN] Manual update failed – stub will self-register.${NC}"
fi
echo ""

# ------------------------------------------------------------
# Main WAF image
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 3] Downloading main WAF image...${NC}"
ECR_REPO="docker.io/sylviapaul/waf"
IMAGE_TAG="latest"

if ! docker pull --platform "$DOCKER_PLATFORM" "$ECR_REPO:$IMAGE_TAG" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Failed to pull main WAF image.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Main WAF image downloaded${NC}\n"

# ------------------------------------------------------------
# Port conflict check for WAF port (lsof on macOS, ss on Linux)
# ------------------------------------------------------------
echo -e "${CYAN}[PORT] Checking port $WAF_PORT...${NC}"
WAF_PORT_BUSY=false
if [[ "$OSTYPE" == "darwin"* ]]; then
    lsof -i tcp:"$WAF_PORT" >/dev/null 2>&1 && WAF_PORT_BUSY=true
else
    ss -tlnp 2>/dev/null | grep -q ":${WAF_PORT}[[:space:]]" && WAF_PORT_BUSY=true
fi

if [ "$WAF_PORT_BUSY" = true ]; then
    echo -e "${YELLOW}⚠️ Port $WAF_PORT in use. Attempting cleanup...${NC}"
    CONFLICT_CID=$(docker ps --format "{{.ID}} {{.Ports}}" | grep ":$WAF_PORT" | awk '{print $1}')
    [ -n "$CONFLICT_CID" ] && docker stop "$CONFLICT_CID" >/dev/null 2>&1 && docker rm "$CONFLICT_CID" >/dev/null 2>&1

    STILL_BUSY=false
    if [[ "$OSTYPE" == "darwin"* ]]; then
        lsof -i tcp:"$WAF_PORT" >/dev/null 2>&1 && STILL_BUSY=true
    else
        ss -tlnp 2>/dev/null | grep -q ":${WAF_PORT}[[:space:]]" && STILL_BUSY=true
    fi
    if [ "$STILL_BUSY" = true ]; then
        echo -e "${RED}[ERROR] Port $WAF_PORT still busy.${NC}"; exit 1
    fi
    echo -e "${GREEN}[OK] Conflict resolved${NC}"
else
    echo -e "${GREEN}[OK] Port $WAF_PORT is free${NC}"
fi
echo ""

docker rm -f "apisphere-waf-${PLATFORM_ID}" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Main WAF container
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 4] Starting main WAF container...${NC}"
if ! docker run -d \
    --name "apisphere-waf-${PLATFORM_ID}" \
    -v "apisphere-config-${PLATFORM_ID}:/app/config:ro" \
    -e PLATFORM_ID="$PLATFORM_ID" \
    -e BACKEND_HOST=host.docker.internal \
    -e BACKEND_PORT="$BACKEND_PORT" \
    -e WAF_PORT="$WAF_PORT" \
    -e WAF_CONFIG_PORT="$WAF_CONFIG_PORT" \
    --add-host=host.docker.internal:host-gateway \
    -p "$WAF_PORT:$WAF_PORT" \
    "$ECR_REPO:$IMAGE_TAG" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Failed to start main WAF container.${NC}"
    docker logs "apisphere-waf-${PLATFORM_ID}" 2>/dev/null || true
    exit 1
fi

sleep 5

if docker ps --format "{{.Names}}" | grep -q "^apisphere-waf-${PLATFORM_ID}$"; then
    echo -e "${GREEN}✅ Main WAF running on port $WAF_PORT${NC}"
    MAIN_WAF_STARTED=1
else
    echo -e "${YELLOW}[WARN] Main WAF exited. Logs:${NC}"
    docker logs "apisphere-waf-${PLATFORM_ID}"
    MAIN_WAF_STARTED=0
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}              INSTALLATION COMPLETE${NC}"
echo -e "${CYAN}============================================================${NC}\n"

echo -e "${GREEN}[PROTECTION STATUS]${NC}"
echo "  Project ID:    $PLATFORM_ID"
echo "  Backend:       http://localhost:$BACKEND_PORT"
echo "  Stub:          http://localhost:8081 (self-registered)"
[ $MAIN_WAF_STARTED -eq 1 ] && echo "  Main WAF:      http://localhost:$WAF_PORT"
echo "  Config port:   $WAF_CONFIG_PORT"
echo ""
echo -e "${GREEN}[VERIFY BLACKLISTING]${NC}"
echo "  Stub logs:     docker logs waf-stub"
echo "  Test block:    curl -H \"X-Forwarded-For: 10.0.0.99\" http://localhost:8081/any/path"
echo "  Add IP at:     http://localhost:$WAF_PORT/ip-blacklist"
echo ""
echo -e "${GREEN}[PERSISTENCE]${NC}"
echo "  Stub rules:    ${DATA_MOUNT}/rules.json"
echo "  Docker volume: apisphere-config-${PLATFORM_ID}"
echo ""
[ $MAIN_WAF_STARTED -eq 0 ] && echo -e "${YELLOW}[NOTE] Main WAF failed. Stub is still protecting your backend.${NC}"