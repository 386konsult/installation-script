from flask import Flask, request, jsonify
from time import time
import requests
import json
import os
import ast
import logging
import time as time_module
import socket   # <-- added for host detection

app = Flask(__name__)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DATA_FILE = "/data/rules.json"
blacklist = set()
alert_rate_limits = {}
endpoint_rules = {}
endpoint_counters = {}

# Default trigger URL (original, unchanged)
DJANGO_TRIGGER_URL = "http://host.docker.internal:8000/api/v1/waf/backendalert/"

# ------------------------------------------------------------------
# NEW helper functions – they do not delete anything
# ------------------------------------------------------------------
def get_docker_host():
    """Return the host address that the Docker container can use to reach the host machine."""
    if not os.path.exists('/.dockerenv'):
        return "localhost"
    try:
        socket.gethostbyname('host.docker.internal')
        return "host.docker.internal"
    except socket.gaierror:
        return "172.17.0.1"

def fix_localhost(url):
    """Replace 'localhost' with the appropriate Docker host address if needed."""
    if "localhost" in url and os.path.exists('/.dockerenv'):
        host = get_docker_host()
        return url.replace("localhost", host)
    return url
# ------------------------------------------------------------------

def get_public_ip():
    services = [
        "https://ifconfig.me/ip",
        "https://icanhazip.com",
        "https://ipinfo.io/ip"
    ]
    for url in services:
        try:
            resp = requests.get(url, timeout=5)
            if resp.status_code == 200:
                ip = resp.text.strip()
                if ip:
                    return ip
        except Exception:
            continue
    return None

def register_stub():
    platform_id = os.environ.get("PLATFORM_ID")
    backend_url = os.environ.get("BACKEND_URL")
    if not platform_id or not backend_url:
        logger.warning("Missing PLATFORM_ID or BACKEND_URL – stub registration skipped")
        return

    # --- ADDED: fix localhost in backend_url ---
    backend_url = fix_localhost(backend_url)

    public_ip = get_public_ip()
    if not public_ip:
        logger.warning("Could not detect public IP – stub registration skipped")
        return

    stub_url = f"http://{public_ip}:8081"
    endpoint = f"{backend_url.rstrip('/')}/platforms/{platform_id}/update-stub-url/"

    try:
        resp = requests.post(endpoint, json={"stub_url": stub_url}, timeout=10)
        if resp.status_code == 200:
            logger.info(f"✅ Stub registered: {stub_url}")
        else:
            logger.error(f"Registration failed: {resp.status_code} – {resp.text}")
    except Exception as e:
        logger.error(f"Registration error: {e}")

def get_platform_id():
    platform_id = request.headers.get('X-Platform-ID')
    if not platform_id:
        platform_id = os.environ.get('PLATFORM_ID')
    if not platform_id:
        logger.warning("No platform_id found in headers or env – using placeholder")
        platform_id = "unknown-platform"
    return platform_id

def load_data():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, 'r') as f:
            data = json.load(f)
            blacklist.update(data.get('blacklist', []))
            for key_str, val in data.get('alert_rate_limits', {}).items():
                key = ast.literal_eval(key_str)
                alert_rate_limits[key] = val
            for key_str, val in data.get('endpoint_rules', {}).items():
                key = ast.literal_eval(key_str)
                endpoint_rules[key] = val
            for key_str, val in data.get('endpoint_counters', {}).items():
                key = ast.literal_eval(key_str)
                endpoint_counters[key] = val
            logger.info(f"Loaded {len(blacklist)} IPs, {len(alert_rate_limits)} alert rules, {len(endpoint_rules)} endpoint rules.")

def save_data():
    data = {
        'blacklist': list(blacklist),
        'alert_rate_limits': {str(k): v for k, v in alert_rate_limits.items()},
        'endpoint_rules': {str(k): v for k, v in endpoint_rules.items()},
        'endpoint_counters': {str(k): v for k, v in endpoint_counters.items()},
    }
    with open(DATA_FILE, 'w') as f:
        json.dump(data, f)
    logger.info(f"Saved {len(blacklist)} IPs, {len(alert_rate_limits)} alert rules, {len(endpoint_rules)} endpoint rules.")

def send_trigger(platform_id, alert_id, client_ip, alert_type, evidence, threat_level):
    # --- ADDED: fix localhost in trigger URL ---
    trigger_url = fix_localhost(DJANGO_TRIGGER_URL)

    payload = {
        "platform_id": platform_id,
        "alert_id": alert_id,
        "client_ip": client_ip,
        "alert_type": alert_type,
        "evidence": evidence,
        "threat_level": threat_level,
        "url": request.url,
        "method": request.method,
        "headers": dict(request.headers),
    }
    try:
        resp = requests.post(trigger_url, json=payload, timeout=2)
        if not 200 <= resp.status_code < 300:
            logger.error(f"Trigger notification failed: {resp.status_code} {resp.text}")
    except Exception as e:
        logger.error(f"Could not send trigger: {e}")

def match_endpoint(rule_endpoint, request_path):
    if rule_endpoint == "*":
        return True
    if rule_endpoint.endswith('*'):
        prefix = rule_endpoint[:-1]
        return request_path.startswith(prefix)
    return rule_endpoint == request_path

# ------------------ IP Blacklist ------------------
@app.route('/api/apisentry-blacklisted-ips', methods=['POST'])
def add_blacklist():
    data = request.json
    ip = data.get('ip')
    if ip:
        blacklist.add(ip)
        save_data()
        logger.info(f"[BLACKLIST] Added {ip} → Total: {len(blacklist)}")
    else:
        logger.warning("[BLACKLIST] Received request without 'ip' field")
    return jsonify(success=True)

@app.route('/api/apisentry-blacklisted-ips/remove', methods=['POST'])
def remove_blacklist():
    data = request.json
    ip = data.get('ip')
    if ip and ip in blacklist:
        blacklist.remove(ip)
        save_data()
        logger.info(f"[BLACKLIST] Removed {ip}")
    else:
        logger.warning(f"[BLACKLIST] Attempt to remove non-existent IP: {ip}")
    return jsonify(success=True)

# ------------------ Rate Limits ------------------
@app.route('/api/apisentry-rate-limits', methods=['POST'])
def add_rate_limit():
    data = request.json
    logger.info(f"[RATE LIMIT] Received: {data}")

    if 'endpoint' in data:
        endpoint = data['endpoint']
        method = data.get('method', '*')
        rule_id = str(data.get('id', f"rule_{len(endpoint_rules)+1}"))
        max_requests = data.get('max_requests')
        time_window = data.get('time_window_seconds')
        action = data.get('action', 'block')
        active = data.get('active', True)
        if not max_requests or not time_window:
            logger.error("Missing max_requests or time_window_seconds")
            return jsonify(error="Missing max_requests or time_window_seconds"), 400
        key = (endpoint, method, rule_id)
        endpoint_rules[key] = {
            "endpoint": endpoint,
            "method": method,
            "max_requests": max_requests,
            "time_window": time_window,
            "action": action,
            "active": active,
            "rule_id": rule_id
        }
        save_data()
        logger.info(f"[RATE LIMIT] Added endpoint rule: {key} -> {max_requests} req/{time_window}s")
        return jsonify(success=True)

    ip = data.get('ip')
    limit = data.get('limit')
    window = data.get('time_window')
    rule_id = data.get('rule_id', f"alert_rule_{len(alert_rate_limits)+1}")
    if not limit or not window:
        logger.error("Missing limit or time_window")
        return jsonify(error="Missing limit or time_window"), 400
    key = (ip if ip else "global", rule_id)
    alert_rate_limits[key] = {
        "limit": limit,
        "window": window,
        "remaining": limit,
        "reset_at": time() + window,
        "alert_id": rule_id
    }
    save_data()
    logger.info(f"[RATE LIMIT] Added alert rule: {key} -> {limit} req/{window}s")
    return jsonify(success=True)

@app.route('/api/apisentry-rate-limits/remove', methods=['POST'])
def remove_rate_limit():
    data = request.json
    rule_id = data.get('rule_id')
    ip = data.get('ip')
    to_delete = None
    for key, rule in endpoint_rules.items():
        if rule.get('rule_id') == rule_id:
            to_delete = key
            break
    if to_delete:
        del endpoint_rules[to_delete]
        to_delete_counters = [k for k in endpoint_counters.keys() if k[3] == rule_id]
        for k in to_delete_counters:
            del endpoint_counters[k]
        save_data()
        logger.info(f"[RATE LIMIT] Removed endpoint rule: {to_delete}")
        return jsonify(success=True)
    if rule_id:
        key = (ip if ip else "global", rule_id)
        if key in alert_rate_limits:
            del alert_rate_limits[key]
            save_data()
            logger.info(f"[RATE LIMIT] Removed alert rule: {key}")
    return jsonify(success=True)

# ------------------ Log every request ------------------
@app.before_request
def log_request():
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    logger.info(f"REQUEST: {request.method} {request.path} from {client_ip}")

# ------------------ Main request handler (block & rate limit) ------------------
@app.before_request
def block_and_rate_limit():
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    path = request.path
    method = request.method

    if client_ip in blacklist:
        logger.info(f"[BLOCK] Blacklisted IP {client_ip} tried to access {path}")
        send_trigger(
            platform_id=get_platform_id(),
            alert_id=None,
            client_ip=client_ip,
            alert_type="ip_blacklist",
            evidence=f"IP {client_ip} is blacklisted",
            threat_level="high"
        )
        return jsonify(error="IP is blacklisted"), 403

    now = time()

    for (rule_ip, rule_id), rule in list(alert_rate_limits.items()):
        if rule_ip == "global" or rule_ip == client_ip:
            if now >= rule["reset_at"]:
                rule["remaining"] = rule["limit"]
                rule["reset_at"] = now + rule["window"]
            if rule["remaining"] <= 0:
                logger.info(f"[RATE LIMIT] Alert rule {rule_id} exceeded for {client_ip}")
                send_trigger(
                    platform_id=get_platform_id(),
                    alert_id=rule["alert_id"],
                    client_ip=client_ip,
                    alert_type="rate_anomaly",
                    evidence=f"Rate limit exceeded: {rule['limit']} requests in {rule['window']}s",
                    threat_level="medium"
                )
                return jsonify(error="Rate limit exceeded"), 429
            rule["remaining"] -= 1

    for (endpoint, ep_method, rule_id), rule in endpoint_rules.items():
        if not rule.get("active", True):
            continue
        if ep_method != "*" and ep_method != method:
            continue
        if not match_endpoint(endpoint, path):
            continue

        key = (client_ip, endpoint, ep_method, rule_id)
        if key not in endpoint_counters:
            endpoint_counters[key] = {
                "remaining": rule["max_requests"],
                "reset_at": now + rule["time_window"],
                "rule_id": rule_id
            }
        counter = endpoint_counters[key]
        if now >= counter["reset_at"]:
            counter["remaining"] = rule["max_requests"]
            counter["reset_at"] = now + rule["time_window"]
        if counter["remaining"] <= 0:
            logger.info(f"[RATE LIMIT] Endpoint rule {rule_id} exceeded for {client_ip} on {endpoint}")
            if rule.get("action") == "block":
                send_trigger(
                    platform_id=get_platform_id(),
                    alert_id=rule_id,
                    client_ip=client_ip,
                    alert_type="rate_anomaly",
                    evidence=f"Endpoint rate limit exceeded: {rule['max_requests']} req/{rule['time_window']}s on {endpoint}",
                    threat_level="medium"
                )
                return jsonify(error="Rate limit exceeded"), 429
        counter["remaining"] -= 1

@app.route('/')
def alive():
    return "WAF stub running (blacklist + IP rate limits + endpoint rate limits)"

if __name__ == '__main__':
    load_data()
    time_module.sleep(5)
    register_stub()
    app.run(host='0.0.0.0', port=8081, debug=False)