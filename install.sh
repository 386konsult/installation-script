#!/bin/bash

# APISphere WAF Installation Script for Mac/Linux
# Uses Docker volumes for persistent PLATFORM_ID storage

set -e

echo "🔧 APISphere WAF Installation Starting..."

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "\n${CYAN}============================================================${NC}"
echo -e "${CYAN}         HEIMDALL WAF INSTALLATION SCRIPT${NC}"
echo -e "${CYAN}============================================================${NC}\n"

# Check arguments
# Check arguments – now with optional 4th argument BACKEND_URL
if [[ $# -lt 2 ]]; then
  echo -e "${RED}❌ Usage: ./install.sh PLATFORM_ID BACKEND_PORT [WAF_PORT] [BACKEND_URL]${NC}"
  echo ""
  echo "  PLATFORM_ID    - Your project UUID"
  echo "  BACKEND_PORT   - Port where local backend listens (only used for local check)"
  echo "  WAF_PORT       - Port for WAF-protected access (default: 8080)"
  echo "  BACKEND_URL    - Full API URL of your backend (e.g., https://staging.breachnet.io/api/v1)"
  echo "                   If not provided, falls back to http://localhost:BACKEND_PORT"
  echo ""
  exit 1
fi

# Read arguments
PLATFORM_ID="$1"
BACKEND_PORT="$2"
WAF_PORT="${3:-8080}"
BACKEND_URL="${4:-http://localhost:$BACKEND_PORT}"


echo -e "${GREEN}⚙️ Configuration:${NC}"
echo "  Platform ID:   ${CYAN}$PLATFORM_ID${NC}"
echo "  Backend port:  ${CYAN}$BACKEND_PORT${NC}"
echo "  WAF port:      ${CYAN}$WAF_PORT${NC}"
echo "  Backend URL:   ${CYAN}$BACKEND_URL${NC}"
echo ""

# Docker availability check
# ------------------------------------------------------------
# Docker check
# ------------------------------------------------------------
echo -e "${CYAN}[CHECK] Verifying Docker installation...${NC}"
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${RED}❌ Docker is not installed or not available in PATH${NC}"
  echo -e "${YELLOW}🔧 Attempting to install Docker...${NC}"
  
  # Detect OS and install Docker accordingly
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    echo "📥 Installing Docker Desktop for macOS..."
    if command -v brew >/dev/null 2>&1; then
      echo "🍺 Using Homebrew to install Docker Desktop..."
      brew install --cask docker
      if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Docker Desktop installed via Homebrew${NC}"
        echo -e "${YELLOW}⚠️  Please start Docker Desktop from Applications and rerun this script${NC}"
        exit 0
      fi
    fi
    
    # Fallback: Direct download for macOS
    echo "📦 Downloading Docker Desktop for macOS..."
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
      DOCKER_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
    else
      DOCKER_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
    fi
    
    curl -L "$DOCKER_URL" -o Docker.dmg
    if [ $? -eq 0 ]; then
      echo "💿 Mounting and installing Docker Desktop..."
      hdiutil attach Docker.dmg
      cp -R "/Volumes/Docker/Docker.app" /Applications/
      hdiutil detach "/Volumes/Docker"
      rm Docker.dmg
      echo -e "${GREEN}✅ Docker Desktop installed${NC}"
      echo -e "${YELLOW}⚠️  Please start Docker Desktop from Applications and rerun this script${NC}"
      exit 0
    fi
    
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    echo "🐧 Installing Docker for Linux..."
    
    # Try package manager based installation
    if command -v apt-get >/dev/null 2>&1; then
      # Ubuntu/Debian
      echo "📦 Installing Docker via apt..."
      sudo apt-get update
      sudo apt-get install -y ca-certificates curl gnupg lsb-release
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      sudo systemctl start docker
      sudo systemctl enable docker
      sudo usermod -aG docker $USER
      echo -e "${GREEN}✅ Docker installed${NC}"
      echo -e "${YELLOW}⚠️  Please log out and log back in, then rerun this script${NC}"
      exit 0
      
    elif command -v yum >/dev/null 2>&1; then
      # CentOS/RHEL
      echo "📦 Installing Docker via yum..."
      sudo yum install -y yum-utils
      sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      sudo systemctl start docker
      sudo systemctl enable docker
      sudo usermod -aG docker $USER
      echo -e "${GREEN}✅ Docker installed${NC}"
      echo -e "${YELLOW}⚠️  Please log out and log back in, then rerun this script${NC}"
      exit 0
      
    elif command -v pacman >/dev/null 2>&1; then
      # Arch Linux
      echo "📦 Installing Docker via pacman..."
      sudo pacman -S --noconfirm docker docker-compose
      sudo systemctl start docker
      sudo systemctl enable docker
      sudo usermod -aG docker $USER
      echo -e "${GREEN}✅ Docker installed${NC}"
      echo -e "${YELLOW}⚠️  Please log out and log back in, then rerun this script${NC}"
      exit 0
    fi
  fi
  
  # If automatic installation failed
  echo -e "${RED}❌ Automatic Docker installation failed${NC}"
  echo -e "${YELLOW}Please install Docker manually:${NC}"
  echo "  📖 macOS: https://docs.docker.com/desktop/install/mac-install/"
  echo "  📖 Linux: https://docs.docker.com/engine/install/"
  echo "  📖 Windows: https://docs.docker.com/desktop/install/windows-install/"
  exit 1
fi
echo -e "${GREEN}✅ Docker is available${NC}"

# Docker status check
echo "🐳 Checking Docker status..."
if ! sudo docker info >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠️  Docker is installed but not responding. Trying to start it...${NC}"
  sudo systemctl start docker
  sleep 2
if ! sudo docker info >/dev/null 2>&1; then
    echo -e "${RED}❌ Docker is still not running${NC}"
    echo -e "${YELLOW}Check logs with:${NC} sudo journalctl -u docker -n 50"
    exit 1
  fi
fi
echo -e "${GREEN}✅ Docker is running${NC}"

# Detect architecture and set Docker platform
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
  DOCKER_PLATFORM="linux/arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
  DOCKER_PLATFORM="linux/amd64"
else
  DOCKER_PLATFORM="linux/amd64"  # Default fallback
fi

# Config service is optional – fallback port for main WAF (unused)
WAF_CONFIG_PORT=8083

# Create config volume
echo "💾 Creating persistent storage for project ID..."
if ! docker volume create apisphere-config-"$PLATFORM_ID" >/dev/null; then
  echo -e "${RED}❌ Failed to create Docker volume${NC}"
  exit 1
fi

# Store in Docker volume with proper permissions
echo "$PLATFORM_ID" > temp_id
docker run --rm -i -v apisphere-config-"$PLATFORM_ID":/config busybox sh -c "cat > /config/PLATFORM_ID && chmod 644 /config/PLATFORM_ID" < temp_id
rm temp_id

# Store WAF_PORT in Docker volume
echo "$WAF_PORT" > temp_waf
docker run --rm -i -v apisphere-config-"$PLATFORM_ID":/config busybox sh -c "cat > /config/WAF_PORT && chmod 644 /config/WAF_PORT" < temp_waf
rm temp_waf

# Verify storage
docker run --rm -v apisphere-config-"$PLATFORM_ID":/config busybox sh -c "ls -l /config && cat /config/PLATFORM_ID"

if [ $? -ne 0 ]; then
  echo -e "${RED}❌ Failed to store PLATFORM_ID in Docker volume${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Project ID stored securely in Docker volume${NC}"

# Pull Docker image from Amazon ECR
# Public ECR repository URL format: public.ecr.aws/[registry-alias]/[repository-name]:[tag]
# Private ECR repository URL format: [aws-account-id].dkr.ecr.[region].amazonaws.com/[repository-name]:[tag]

# Replace with your actual ECR repository URL
ECR_REPO="docker.io/sylviapaul/waf"
IMAGE_TAG="latest"

echo -e "${CYAN}📦 Step 2: Downloading APISphere WAF Protection Image${NC}"
echo "📥 Pulling WAF image for ${ARCH} (${DOCKER_PLATFORM})..."
if ! docker pull --platform ${DOCKER_PLATFORM} ${ECR_REPO}:${IMAGE_TAG} >/dev/null 2>&1; then
  echo -e "${RED}❌ Failed to pull Docker image from Amazon ECR for ${ARCH}${NC}"
  echo -e "${YELLOW}Possible solutions:"
  echo "  1. Check your internet connection"
  echo "  2. Verify ECR access: docker pull ${ECR_REPO}:${IMAGE_TAG}"
  echo "  3. Try with VPN if on corporate network"
  echo "  4. If you are on Apple Silicon (M1/M2), the script will use linux/amd64 automatically"
  echo -e "${NC}"
  exit 1
fi
echo -e "${GREEN}✅ WAF Protection image downloaded successfully${NC}"
echo ""

# Backend service check (improved)
echo "🔍 Verifying backend service on port $BACKEND_PORT..."

get_pid_from_port() {
  local port="$1"
  local pid

  pid=$(sudo ss -ltnp "( sport = :$port )" 2>/dev/null \
    | awk -F'pid=' 'NR>1 && NF>1 {split($2,a,","); print a[1]; exit}')

  if [ -z "$pid" ]; then
    pid=$(sudo lsof -ti tcp:"$port" 2>/dev/null | head -n1)
  fi

  echo "$pid"
}

BACKEND_PID=$(get_pid_from_port "$BACKEND_PORT")

if [ -z "$BACKEND_PID" ]; then
  echo -e "${RED}❌ No service detected on port $BACKEND_PORT${NC}"
  echo -e "${YELLOW}Please start your backend application first:${NC}"
  echo ""
  echo "Common startup commands:"
  echo "  ${CYAN}Node.js:${NC}    npm start"
  echo "  ${CYAN}Python:${NC}     flask run -p $BACKEND_PORT"
  echo "  ${CYAN}Ruby:${NC}       rails server -p $BACKEND_PORT"
  echo "  ${CYAN}Java:${NC}       mvn spring-boot:run"
  echo ""
  echo -e "${YELLOW}After starting your app, rerun this script${NC}"
  exit 1
fi

BACKEND_CMD=$(ps -p "$BACKEND_PID" -o comm= 2>/dev/null | tr -d '[:space:]')

if [ -n "$BACKEND_CMD" ]; then
  if [[ ! "$BACKEND_CMD" =~ ^(node|next-server|python|python3|java|ruby|gunicorn|uwsgi|dotnet|rails|flask|go|php|nginx|httpd|apache2)$ ]]; then
    echo -e "${YELLOW}⚠️  Service detected on port $BACKEND_PORT, but process looks unusual ($BACKEND_CMD)${NC}"
    echo -e "${YELLOW}Proceeding, but please ensure your backend is running as expected.${NC}"
  fi

  echo -e "${GREEN}✅ Backend service confirmed on port $BACKEND_PORT ($BACKEND_CMD)${NC}"
else
  echo -e "${GREEN}✅ Backend service confirmed on port $BACKEND_PORT${NC}"
fi

# Port conflict check for WAF_PORT (matches .bat logic)
echo "🔎 Checking if WAF port $WAF_PORT is available..."
WAF_PORT_IN_USE=0

# Check if any process is using the port
if lsof -i tcp:"$WAF_PORT" >/dev/null 2>&1; then
  WAF_PORT_IN_USE=1
fi

# Check if any Docker container is using the port
DOCKER_CONFLICT_CONTAINER_IDS=$(docker ps --format '{{.ID}} {{.Ports}}' | grep ":$WAF_PORT->8080" | awk '{print $1}')
if [ -n "$DOCKER_CONFLICT_CONTAINER_IDS" ]; then
  WAF_PORT_IN_USE=1
fi

if [ "$WAF_PORT_IN_USE" -eq 1 ]; then
  echo -e "${YELLOW}⚠️  Port $WAF_PORT is already in use${NC}"
  # Try to stop conflicting Docker containers
  if [ -n "$DOCKER_CONFLICT_CONTAINER_IDS" ]; then
    for cid in $DOCKER_CONFLICT_CONTAINER_IDS; do
      echo "🧹 Stopping conflicting Docker container: $cid"
      docker stop "$cid" >/dev/null 2>&1
      docker rm "$cid" >/dev/null 2>&1
    done
  fi
  # Check again if port is still in use
  if lsof -i tcp:"$WAF_PORT" >/dev/null 2>&1; then
    echo -e "${RED}❌ Port $WAF_PORT is still in use after Docker cleanup${NC}"
    echo -e "${YELLOW}Tips:${NC}"
    echo "  1. Close any application using port $WAF_PORT"
    echo "  2. Choose a different WAF_PORT"
    echo "  3. Run: lsof -i :$WAF_PORT"
    exit 1
  fi
  echo -e "${GREEN}✅ Port conflict resolved${NC}"
fi

# Stop and remove any container using the target WAF port
existing_container=$(docker ps --format '{{.ID}} {{.Ports}}' | grep ":$WAF_PORT->8080" | awk '{print $1}')
if [ -n "$existing_container" ]; then
  echo "🧹 Stopping container using port $WAF_PORT: $existing_container"
  docker stop "$existing_container" >/dev/null 2>&1
  docker rm "$existing_container" >/dev/null 2>&1
fi

# Cleanup existing containers
echo "🧹 Removing old WAF containers (if any)..."
docker rm -f apisphere-waf-"$PLATFORM_ID" >/dev/null 2>&1 || true

echo -e "${CYAN}📦 Step 3: Starting APISphere WAF Protection${NC}"
echo "🛡️ Starting WAF protection service..."

CONTAINER_NAME="apisphere-waf-$PLATFORM_ID"

CONTAINER_ID=$(docker run -d \
  --name "$CONTAINER_NAME" \
  -v apisphere-config-"$PLATFORM_ID":/app/config:ro \
  -e PLATFORM_ID="$PLATFORM_ID" \
  -e BACKEND_HOST=host.docker.internal \
  -e BACKEND_PORT="$BACKEND_PORT" \
  -e WAF_PORT="$WAF_PORT" \
  -e WAF_CONFIG_PORT="$WAF_CONFIG_PORT" \
  --add-host=host.docker.internal:host-gateway \
  -p "$WAF_PORT":"$WAF_PORT" \
  "$ECR_REPO:$IMAGE_TAG" 2>&1)

RUN_EXIT_CODE=$?

if [ $RUN_EXIT_CODE -ne 0 ] || [ -z "$CONTAINER_ID" ]; then
  echo -e "${RED}❌ Failed to start WAF container${NC}"
  echo "$CONTAINER_ID"
  exit 1
fi

echo "⏳ Waiting for container initialization (5 seconds)..."
sleep 5

if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "🔍 Verifying container config..."
  docker exec "$CONTAINER_NAME" ls -l /app/config || true
  docker exec "$CONTAINER_NAME" cat /app/config/PLATFORM_ID || true

  echo -e "${GREEN}✅ WAF started successfully${NC}"
  echo ""
  echo -e "${GREEN}🎉 APISphere WAF Setup Complete!${NC}"
  echo ""
  echo -e "${CYAN}=== Protection Status ========================${NC}"
  echo "  Project ID:           $PLATFORM_ID"
  echo "  Backend URL:          http://localhost:$BACKEND_PORT"
  echo "  Protected URL:        http://localhost:$WAF_PORT"
  echo "  Config Service Port:  $WAF_CONFIG_PORT"
  echo ""
  echo -e "${CYAN}=== Security Verification ===================${NC}"
  echo "  Test safe request:"
  echo "    curl -I http://localhost:$WAF_PORT/"
  echo ""
  echo "  Test blocked request:"
  echo "    curl 'http://localhost:$WAF_PORT/?exec=/bin/bash'"
  echo ""
  echo -e "${CYAN}=== Management Commands =====================${NC}"
  echo "  View WAF logs:        docker logs $CONTAINER_NAME"
  echo "  Stop WAF:             docker stop $CONTAINER_NAME"
  echo "  Restart WAF:          docker start $CONTAINER_NAME"
  echo "  Remove WAF:           docker rm -f $CONTAINER_NAME"
  echo "  Remove volume:        docker volume rm apisphere-config-$PLATFORM_ID"
  echo ""
  echo -e "${GREEN}All traffic should now go through the protected port!${NC}"
else
  echo -e "${RED}❌ WAF failed to start${NC}"
  echo ""
  echo "Container logs:"
  docker logs "$CONTAINER_NAME" 2>&1 || true
  echo ""
  echo "Troubleshooting steps:"
  echo "  1. Check container logs:"
  echo "     ${CYAN}docker logs $CONTAINER_NAME${NC}"
  echo "  2. Verify port availability:"
  echo "     ${CYAN}ss -ltnp '( sport = :$WAF_PORT )'${NC}"
  echo "  3. Ensure backend is still running"
  exit 1
fi

# ------------------------------------------------------------
# Stub container (IP blacklist + rate limiting)
# ------------------------------------------------------------
echo -e "${CYAN}[STEP 2/4] Installing Heimdall stub container...${NC}"
sudo mkdir -p /data/waf
sudo chmod 777 /data/waf

echo -e "  ${CYAN}→ Pulling stub image from Docker Hub...${NC}"
docker pull nifzzy/waf-stub:latest
if [[ $? -ne 0 ]]; then
    echo -e "${RED}[ERROR] Failed to pull stub image.${NC}"
    exit 1
fi

echo -e "  ${CYAN}→ Removing any existing stub container...${NC}"
docker stop waf-stub >/dev/null 2>&1 || true
docker rm waf-stub >/dev/null 2>&1 || true

echo -e "  ${CYAN}→ Starting stub container on port 8081...${NC}"
docker run -d --restart=always --network="host" -v /data/waf:/data --name waf-stub nifzzy/waf-stub:latest >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    echo -e "${RED}[ERROR] Failed to start stub container.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Heimdall stub container started successfully on port 8081.${NC}"
# ============================================================
# Report stub URL to backend
# ============================================================
echo ""
echo -e "${CYAN}[INFO] Detecting public IP address...${NC}"
PUBLIC_IP=$(curl -s ifconfig.me/ip)
if [[ -n "$PUBLIC_IP" ]]; then
    echo -e "${GREEN}[OK] Public IP detected: $PUBLIC_IP${NC}"
    echo -e "${CYAN}[POST] Updating backend ($BACKEND_URL) with stub URL...${NC}"
    curl -X POST "$BACKEND_URL/api/v1/platforms/$PLATFORM_ID/update-stub-url/" \
        -H "Content-Type: application/json" \
        -d "{\"stub_url\": \"http://$PUBLIC_IP:8081\"}" \
        -s -o /dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}[OK] Backend updated. Stub URL: http://$PUBLIC_IP:8081${NC}"
    else
        echo -e "${YELLOW}[WARN] Failed to update backend. You may need to set stub_url manually in Django admin.${NC}"
    fi
else
    echo -e "${YELLOW}[WARN] Could not detect public IP. Please set platform.stub_url manually in Django admin.${NC}"
fi
echo ""