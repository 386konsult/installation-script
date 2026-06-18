#!/bin/bash
# ============================================================
#  Heimdall WAF for Linux/macOS – CORRECT ARCHITECTURE
#  Main WAF (Envoy+WASM) is the ingress point.
#  Stub is control plane (internal) – NOT exposed to host.
#  Gateway (nginx) must proxy to main WAF on WAF_PORT.
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

# Parse arguments
POSITIONAL=()
STUB_IP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --stub-ip) STUB_IP="$2"; shift 2 ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -lt 2 ]]; then
    echo -e "${RED}Usage: $0 PLATFORM_ID BACKEND_PORT [WAF_PORT]${NC}"
    exit 1
fi

PLATFORM_ID="$1"
BACKEND_PORT="$2"
WAF_PORT="${3:-8080}"
BACKEND_URL="https://heimdall.smartcomply.com/api/v1"

echo -e "${GREEN}Configuration:${NC}"
echo "  Platform ID:   ${CYAN}$PLATFORM_ID${NC}"
echo "  Backend port:  ${CYAN}$BACKEND_PORT${NC}"
echo "  WAF port:      ${CYAN}$WAF_PORT${NC}"
[ -n "$STUB_IP" ] && echo "  Stub IP:       ${CYAN}$STUB_IP${NC}"
echo ""

# ------------------------------------------------------------
# Docker check (same as before, keep it)
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

WAF_CONFIG_PORT=8081

# ------------------------------------------------------------
# Persistent volume
# ------------------------------------------------------------
echo -e "${CYAN}[VOLUME] Creating persistent storage for config...${NC}"
docker volume create "apisphere-config-${PLATFORM_ID}" >/dev/null 2>&1
echo "$PLATFORM_ID" | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/PLATFORM_ID && chmod 644 /config/PLATFORM_ID"
echo "$WAF_PORT"    | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/WAF_PORT && chmod 644 /config/WAF_PORT"
echo -e "${GREEN}✅ Config stored in Docker volume${NC}\n"

# ------------------------------------------------------------
# Backend port check
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
# Create Docker network for internal comms (main WAF ↔ stub)
# ------------------------------------------------------------
echo -e "${CYAN}[NETWORK] Creating internal Docker network for WAF ↔ stub...${NC}"
docker network inspect heimdall-internal >/dev/null 2>&1 || docker network create heimdall-internal >/dev/null 2>&1
echo -e "${GREEN}✅ Network 'heimdall-internal' ready${NC}\n"

# ------------------------------------------------------------
# Data mount
# ------------------------------------------------------------
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo mkdir -p /data/waf && sudo chown 1000:1000 /data/waf && sudo chmod 755 /data/waf
    DATA_MOUNT="/data/waf"
else
    mkdir -p "$HOME/.heimdall/waf"
    DATA_MOUNT="$HOME/.heimdall/waf"
fi

# ------------------------------------------------------------
# Stub container – INTERNAL only (no host port exposure)
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 1] Installing stub (control plane – internal only)...${NC}"
docker pull 386konsult/waf-stub:latest

docker stop waf-stub >/dev/null 2>&1 || true
docker rm   waf-stub >/dev/null 2>&1 || true

# Stub needs to talk to backend for registration – use host's gateway
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    GATEWAY_IP=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1)
    [ -z "$GATEWAY_IP" ] && GATEWAY_IP="172.17.0.1"
    STUB_BACKEND_URL=$(echo "$BACKEND_URL" | sed "s/localhost/$GATEWAY_IP/g")
elif [[ "$OSTYPE" == "darwin"* ]]; then
    STUB_BACKEND_URL=$(echo "$BACKEND_URL" | sed "s/localhost/host.docker.internal/g")
fi

# Run stub WITHOUT publishing port 8081 to host
docker run -d --restart=always \
    --network heimdall-internal \
    --name waf-stub \
    -v "${DATA_MOUNT}:/data" \
    -e PLATFORM_ID="$PLATFORM_ID" \
    -e BACKEND_URL="$STUB_BACKEND_URL" \
    -e WAF_PORT="$WAF_PORT" \
    386konsult/waf-stub:latest >/dev/null 2>&1


if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR] Failed to start stub container.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Stub running internally (no host port)${NC}"
sleep 3

# ------------------------------------------------------------
# Main WAF image pull
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 2] Pulling main WAF image...${NC}"
ECR_REPO="docker.io/386konsult/waf"
IMAGE_TAG="latest"

docker pull --platform "$DOCKER_PLATFORM" "$ECR_REPO:$IMAGE_TAG" >/dev/null 2>&1 || {
    echo -e "${RED}[ERROR] Failed to pull main WAF image.${NC}"
    exit 1
}
echo -e "${GREEN}✅ Main WAF image ready${NC}\n"

# ------------------------------------------------------------
# Port conflict check on WAF_PORT
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
        echo -e "${RED}[ERROR] Port $WAF_PORT still busy.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] Conflict resolved${NC}"
else
    echo -e "${GREEN}[OK] Port $WAF_PORT is free${NC}"
fi
echo ""

docker rm -f "apisphere-waf-${PLATFORM_ID}" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Main WAF container – ingress point, exposes WAF_PORT to host
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 3] Starting main WAF (ingress) on port $WAF_PORT...${NC}"
docker run -d \
    --name "apisphere-waf-${PLATFORM_ID}" \
    --network heimdall-internal \
    --add-host host.docker.internal:host-gateway \
    -v "apisphere-config-${PLATFORM_ID}:/app/config:ro" \
    -v "${DATA_MOUNT}:/data/waf:ro" \
    -e PLATFORM_ID="$PLATFORM_ID" \
    -e BACKEND_HOST=host.docker.internal \
    -e BACKEND_PORT="$BACKEND_PORT" \
    -e WAF_PORT="$WAF_PORT" \
    -e WAF_CONFIG_PORT="$WAF_CONFIG_PORT" \
    -p "$WAF_PORT:$WAF_PORT" \
    "$ECR_REPO:$IMAGE_TAG" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR] Failed to start main WAF container.${NC}"
    exit 1
fi

sleep 5

if docker ps --format "{{.Names}}" | grep -q "^apisphere-waf-${PLATFORM_ID}$"; then
    echo -e "${GREEN}✅ Main WAF running on port $WAF_PORT (ingress)${NC}"
    MAIN_WAF_STARTED=1
else
    echo -e "${YELLOW}[WARN] Main WAF exited. Check logs: docker logs apisphere-waf-${PLATFORM_ID}${NC}"
    MAIN_WAF_STARTED=0
fi

# ------------------------------------------------------------
# Optional manual stub IP registration (if provided)
# ------------------------------------------------------------
if [ -n "$STUB_IP" ]; then
    echo -e "${CYAN}[INFO] Manually registering stub: http://$STUB_IP:8081${NC}"
    curl -s -o /dev/null -X POST "$BACKEND_URL/platforms/$PLATFORM_ID/update-stub-url/" \
        -H "Content-Type: application/json" \
        -d "{\"stub_url\": \"http://$STUB_IP:8081\"}" \
        && echo -e "${GREEN}[OK] Backend updated.${NC}" \
        || echo -e "${YELLOW}[WARN] Manual update failed – stub will self-register.${NC}"
fi

# ------------------------------------------------------------
# Summary – CORRECT ARCHITECTURE
# ------------------------------------------------------------
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}              INSTALLATION COMPLETE${NC}"
echo -e "${CYAN}============================================================${NC}\n"

echo -e "${GREEN}[PROTECTION STATUS]${NC}"
echo "  Project ID:    $PLATFORM_ID"
echo "  Your backend:  http://localhost:$BACKEND_PORT"
echo "  Main WAF:      http://localhost:$WAF_PORT (INGRESS – expose this to users)"
echo "  Stub:          internal only (no host port) – control plane"
echo "  Config port:   $WAF_CONFIG_PORT (Envoy admin)"
echo ""
echo -e "${GREEN}[CORRECT TRAFFIC FLOW]${NC}"
echo "  → Your gateway (nginx, Apache, Envoy) MUST proxy traffic to the MAIN WAF:"
echo "       proxy_pass http://localhost:$WAF_PORT;"
echo ""
echo "  → Main WAF does:"
echo "      - SQLi/XSS detection (blocks attacks)"
echo "      - Forwards clean requests to your backend (port $BACKEND_PORT)"
echo "      - Forwards control requests (from backend) to the stub internally"
echo ""
echo "  → Stub is NOT in the data path – only receives control updates from the WAF."
echo ""
echo -e "${YELLOW}⚠️  Do NOT point your gateway to port 8081 – that would put stub in data path and cause high latency.${NC}"
echo ""
echo -e "${GREEN}[MANAGEMENT]${NC}"
echo "  Main WAF logs:  docker logs apisphere-waf-${PLATFORM_ID}"
echo "  Stub logs:      docker logs waf-stub"
echo "  Stop WAF:       docker stop apisphere-waf-${PLATFORM_ID}"
echo "  Restart WAF:    docker start apisphere-waf-${PLATFORM_ID}"
echo "  Remove WAF:     docker rm -f apisphere-waf-${PLATFORM_ID}"
echo "  Remove volume:  docker volume rm apisphere-config-${PLATFORM_ID}"
echo ""
echo -e "${GREEN}[NEXT STEPS FOR BACKEND INTEGRATION]${NC}"
echo "  The backend (Heimdall) must be updated to send blacklist/rate-limit updates"
echo "  to the MAIN WAF endpoint: http://localhost:$WAF_PORT/api/v1/waf/control"
echo "  with header 'X-Heimdall-Control: true' – NOT directly to the stub."
echo ""
[ $MAIN_WAF_STARTED -eq 0 ] && echo -e "${YELLOW}[NOTE] Main WAF failed to start. Check logs.${NC}"