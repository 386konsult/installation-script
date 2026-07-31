#!/bin/bash
# ============================================================
#  Heimdall Managed WAF – Server-Side Deploy Script
#  Runs on the Heimdall server (165.245.217.132)
#  One WAF container per managed customer, isolated per network.
#
#  Usage:
#    ./deploy-managed.sh PLATFORM_ID [--internal-secret SECRET]
#
#  HEIMDALL_INTERNAL_SECRET can also be set as an env variable.
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

HEIMDALL_BACKEND_URL="https://api.heimdallsecurity.io/api/v1"
SSL_CERT="/etc/letsencrypt/live/heimdallsecurity.io/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/heimdallsecurity.io/privkey.pem"
NGINX_SITES="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
PORT_REGISTRY="/etc/heimdall/managed-ports"
WAF_IMAGE="docker.io/386konsult/managed-waf:latest"
STUB_IMAGE="386konsult/waf-stub:latest"
WAF_CONFIG_PORT=8083

# ── Parse arguments ──────────────────────────────────────────
PLATFORM_ID=""
INTERNAL_SECRET="${HEIMDALL_INTERNAL_SECRET:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --internal-secret) INTERNAL_SECRET="$2"; shift 2 ;;
        -*) echo -e "${RED}[ERROR] Unknown option: $1${NC}"; exit 1 ;;
        *) PLATFORM_ID="$1"; shift ;;
    esac
done

if [[ -z "$PLATFORM_ID" ]]; then
    echo -e "${RED}Usage: $0 PLATFORM_ID [--internal-secret SECRET]${NC}"
    echo "  PLATFORM_ID         Platform UUID from the Heimdall dashboard"
    echo "  --internal-secret   Value of HEIMDALL_INTERNAL_SECRET (or set as env var)"
    exit 1
fi

echo -e "\n${CYAN}============================================================${NC}"
echo -e "${CYAN}       HEIMDALL MANAGED WAF DEPLOYMENT${NC}"
echo -e "${CYAN}============================================================${NC}\n"

# ── Docker check ─────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Docker is not available or not running.${NC}"
    exit 1
fi

# ── Fetch destination config from backend ────────────────────
echo -e "${CYAN}[FETCH] Getting destination config for $PLATFORM_ID...${NC}"

CURL_ARGS=(-s -f)
[[ -n "$INTERNAL_SECRET" ]] && CURL_ARGS+=(-H "X-Heimdall-Internal: $INTERNAL_SECRET")

RESPONSE=$(curl "${CURL_ARGS[@]}" "$HEIMDALL_BACKEND_URL/platforms/$PLATFORM_ID/destination/") || {
    echo -e "${RED}[ERROR] Could not reach backend or platform not found. Check PLATFORM_ID and backend URL.${NC}"
    exit 1
}

DESTINATION_URL=$(python3 -c "import sys,json; print(json.load(sys.stdin)['destination_url'])" <<< "$RESPONSE")
PROTECTED_HOSTNAME=$(python3 -c "import sys,json; print(json.load(sys.stdin)['protected_hostname'])" <<< "$RESPONSE")

if [[ -z "$DESTINATION_URL" || -z "$PROTECTED_HOSTNAME" ]]; then
    echo -e "${RED}[ERROR] Backend returned invalid data: $RESPONSE${NC}"
    exit 1
fi

echo -e "  Destination URL:    ${GREEN}$DESTINATION_URL${NC}"
echo -e "  Protected hostname: ${GREEN}$PROTECTED_HOSTNAME${NC}"

# ── Parse destination URL into host + port ───────────────────
SCHEME=$(echo "$DESTINATION_URL" | grep -oP '^https?')
HOSTPORT=$(echo "$DESTINATION_URL" | sed 's|https\?://||' | sed 's|/.*||')
BACKEND_HOST=$(echo "$HOSTPORT" | cut -d: -f1)

if echo "$HOSTPORT" | grep -q ':'; then
    BACKEND_PORT=$(echo "$HOSTPORT" | cut -d: -f2)
else
    [[ "$SCHEME" == "https" ]] && BACKEND_PORT=443 || BACKEND_PORT=80
fi

EFFECTIVE_HOST="$BACKEND_HOST"
EFFECTIVE_PORT="$BACKEND_PORT"
EFFECTIVE_SCHEME="$SCHEME"
ORIGIN_PROXY_PORT=""

if [[ "$SCHEME" == "https" ]]; then
    echo -e "${CYAN}[PROXY] HTTPS origin detected — will bridge via local nginx proxy${NC}"
    for port in $(seq 8000 8999); do
        if ! ss -tlnp | grep -q ":${port}[[:space:]]"; then
            ORIGIN_PROXY_PORT="$port"
            break
        fi
    done
    if [[ -z "$ORIGIN_PROXY_PORT" ]]; then
        echo -e "${RED}[ERROR] No available ports for HTTPS origin proxy (8000-8999).${NC}"
        exit 1
    fi
    EFFECTIVE_HOST="host.docker.internal"
    EFFECTIVE_PORT="$ORIGIN_PROXY_PORT"
    EFFECTIVE_SCHEME="http"
fi

echo -e "  Backend host: ${GREEN}$BACKEND_HOST${NC}  port: ${GREEN}$BACKEND_PORT${NC}\n"

# ── Port allocation ───────────────────────────────────────────
mkdir -p /etc/heimdall
touch "$PORT_REGISTRY"

ALLOCATED_PORT=""

# Reuse existing port if this platform was deployed before
EXISTING_PORT=$(grep "=${PLATFORM_ID}$" "$PORT_REGISTRY" | cut -d= -f1 || true)
if [[ -n "$EXISTING_PORT" ]]; then
    ALLOCATED_PORT="$EXISTING_PORT"
    echo -e "${CYAN}[PORT] Reusing existing port $ALLOCATED_PORT for this platform${NC}"
else
    for port in $(seq 9000 9999); do
        if ! ss -tlnp | grep -q ":${port}[[:space:]]"; then
            if ! grep -q "^${port}=" "$PORT_REGISTRY"; then
                ALLOCATED_PORT="$port"
                break
            fi
        fi
    done
    if [[ -z "$ALLOCATED_PORT" ]]; then
        echo -e "${RED}[ERROR] No available ports in range 9000-9999.${NC}"
        exit 1
    fi
    echo "${ALLOCATED_PORT}=${PLATFORM_ID}" >> "$PORT_REGISTRY"
    echo -e "${CYAN}[PORT] Allocated port $ALLOCATED_PORT${NC}"
fi

# ── Names ─────────────────────────────────────────────────────
NETWORK_NAME="heimdall-managed-${PLATFORM_ID}"
WAF_CONTAINER="apisphere-waf-${PLATFORM_ID}"
STUB_CONTAINER="waf-stub-${PLATFORM_ID}"
DATA_MOUNT="/data/waf-managed/${PLATFORM_ID}"
mkdir -p "$DATA_MOUNT"

# ── Isolated Docker network per customer ──────────────────────
echo -e "${CYAN}[NETWORK] Setting up isolated network...${NC}"
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null 2>&1
echo -e "${GREEN}  Network '$NETWORK_NAME' ready${NC}"

# ── Docker volume ─────────────────────────────────────────────
docker volume create "apisphere-config-${PLATFORM_ID}" >/dev/null 2>&1
echo "$PLATFORM_ID"    | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/PLATFORM_ID && chmod 644 /config/PLATFORM_ID"
echo "$ALLOCATED_PORT" | docker run --rm -i -v "apisphere-config-${PLATFORM_ID}:/config" busybox sh -c "cat > /config/WAF_PORT && chmod 644 /config/WAF_PORT"

# ── Pull images ───────────────────────────────────────────────
echo -e "${CYAN}[PULL] Pulling images...${NC}"
docker pull "$STUB_IMAGE" >/dev/null 2>&1
docker pull "$WAF_IMAGE"  >/dev/null 2>&1
echo -e "${GREEN}  Images ready${NC}\n"

# ── Stub container (control plane, internal only) ─────────────
echo -e "${CYAN}[STEP 1] Starting stub (control plane)...${NC}"
docker rm -f "$STUB_CONTAINER" >/dev/null 2>&1 || true

docker run -d --restart=always \
    --network "$NETWORK_NAME" \
    --network-alias waf-stub \
    --name "$STUB_CONTAINER" \
    -v "${DATA_MOUNT}:/data" \
    -e PLATFORM_ID="$PLATFORM_ID" \
    -e BACKEND_URL="$HEIMDALL_BACKEND_URL" \
    -e WAF_PORT="$ALLOCATED_PORT" \
    "$STUB_IMAGE" >/dev/null 2>&1

if ! docker ps --format "{{.Names}}" | grep -q "^${STUB_CONTAINER}$"; then
    echo -e "${RED}[ERROR] Stub failed to start. Check: docker logs $STUB_CONTAINER${NC}"
    exit 1
fi
echo -e "${GREEN}  Stub running (internal only, alias: waf-stub)${NC}"
sleep 3

# ── Main WAF container ────────────────────────────────────────
echo -e "${CYAN}[STEP 2] Starting main WAF on port $ALLOCATED_PORT...${NC}"
docker rm -f "$WAF_CONTAINER" >/dev/null 2>&1 || true

docker run -d --restart=always \
    --name "$WAF_CONTAINER" \
    --network "$NETWORK_NAME" \
    -v "apisphere-config-${PLATFORM_ID}:/app/config:ro" \
    -v "${DATA_MOUNT}:/data/waf:ro" \
    -e PLATFORM_ID="$PLATFORM_ID" \
    -e BACKEND_HOST="$EFFECTIVE_HOST" \
    -e BACKEND_PORT="$EFFECTIVE_PORT" \
    -e ORIGIN_SCHEME="$EFFECTIVE_SCHEME" \
    --add-host=host.docker.internal:host-gateway \
    -e WAF_PORT="$ALLOCATED_PORT" \
    -e WAF_CONFIG_PORT="$WAF_CONFIG_PORT" \
    -p "$ALLOCATED_PORT:$ALLOCATED_PORT" \
    "$WAF_IMAGE" >/dev/null 2>&1

sleep 5

if ! docker ps --format "{{.Names}}" | grep -q "^${WAF_CONTAINER}$"; then
    echo -e "${RED}[ERROR] WAF container failed to start. Check: docker logs $WAF_CONTAINER${NC}"
    exit 1
fi
echo -e "${GREEN}  WAF running on port $ALLOCATED_PORT${NC}\n"

# ── nginx config ──────────────────────────────────────────────
echo -e "${CYAN}[NGINX] Writing config for $PROTECTED_HOSTNAME...${NC}"
NGINX_CONF="${NGINX_SITES}/heimdall-managed-${PLATFORM_ID}.conf"

if [[ "$PROTECTED_HOSTNAME" == *".heimdallsecurity.io" ]]; then
    # Use existing wildcard cert
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PROTECTED_HOSTNAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${PROTECTED_HOSTNAME};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass         http://127.0.0.1:${ALLOCATED_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
else
    # Custom domain — HTTP config; certbot will upgrade to HTTPS automatically
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PROTECTED_HOSTNAME};

    location / {
        proxy_pass         http://127.0.0.1:${ALLOCATED_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
fi

ln -sf "$NGINX_CONF" "$NGINX_ENABLED/"

nginx -t >/dev/null 2>&1 || {
    echo -e "${RED}[ERROR] nginx config invalid. Run: nginx -t${NC}"
    exit 1
}
systemctl reload nginx
echo -e "${GREEN}  nginx configured and reloaded${NC}"

# ── HTTPS origin proxy ────────────────────────────────────────
if [[ -n "$ORIGIN_PROXY_PORT" ]]; then
    ORIGIN_PROXY_CONF="${NGINX_SITES}/heimdall-origin-proxy-${PLATFORM_ID}.conf"
    cat > "$ORIGIN_PROXY_CONF" <<EOF
server {
    listen ${ORIGIN_PROXY_PORT};
    server_name localhost;

    location / {
        proxy_pass         https://${BACKEND_HOST};
        proxy_ssl_server_name on;
        proxy_ssl_verify   off;
        proxy_set_header   Host              ${BACKEND_HOST};
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 60s;
    }
}
EOF
    ln -sf "$ORIGIN_PROXY_CONF" "$NGINX_ENABLED/"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    echo -e "${GREEN}  HTTPS origin proxy active: port $ORIGIN_PROXY_PORT → https://$BACKEND_HOST${NC}"
fi

# ── Auto SSL for custom domains ───────────────────────────────
if [[ "$PROTECTED_HOSTNAME" != *".heimdallsecurity.io" ]]; then
    echo -e "${CYAN}[SSL] Provisioning certificate for $PROTECTED_HOSTNAME...${NC}"
    if certbot --nginx -d "$PROTECTED_HOSTNAME" --non-interactive --agree-tos -m "admin@heimdallsecurity.io" --redirect >/dev/null 2>&1; then
        echo -e "${GREEN}  SSL certificate issued — HTTPS enabled${NC}"
    else
        echo -e "${YELLOW}  [WARN] certbot failed — running HTTP only. Ensure DNS points to this server first.${NC}"
    fi
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}         MANAGED WAF DEPLOYED SUCCESSFULLY${NC}"
echo -e "${CYAN}============================================================${NC}\n"

echo -e "${GREEN}[STATUS]${NC}"
echo "  Platform ID:        $PLATFORM_ID"
echo "  Protected hostname: $PROTECTED_HOSTNAME"
echo "  Origin:             $DESTINATION_URL"
echo "  WAF port:           $ALLOCATED_PORT (internal)"
echo "  WAF container:      $WAF_CONTAINER"
echo "  Stub container:     $STUB_CONTAINER"
echo "  Network:            $NETWORK_NAME"
echo ""
echo -e "${GREEN}[DNS]${NC}"
echo "  Customer must have an A record: $PROTECTED_HOSTNAME → 165.245.217.132"
echo ""
echo -e "${GREEN}[MANAGEMENT]${NC}"
echo "  WAF logs:   docker logs $WAF_CONTAINER"
echo "  Stub logs:  docker logs $STUB_CONTAINER"
echo "  Stop:       docker stop $WAF_CONTAINER $STUB_CONTAINER"
echo "  Remove:     docker rm -f $WAF_CONTAINER $STUB_CONTAINER"
echo "              docker network rm $NETWORK_NAME"
echo "              rm -f ${NGINX_CONF} ${NGINX_ENABLED}/heimdall-managed-${PLATFORM_ID}.conf"
if [[ -n "$ORIGIN_PROXY_PORT" ]]; then
echo "              rm -f ${NGINX_SITES}/heimdall-origin-proxy-${PLATFORM_ID}.conf ${NGINX_ENABLED}/heimdall-origin-proxy-${PLATFORM_ID}.conf"
fi
echo "              nginx -t && systemctl reload nginx"
