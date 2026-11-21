#!/usr/bin/env bash
# ==============================================================================
# Script: ssl-init.sh
# Purpose: Two-stage Let's Encrypt SSL Certificate Bootstrap
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
    echo "[ERROR] .env file not found in ${SCRIPT_DIR}. Please run setup.sh first."
    exit 1
fi

# Load variables from .env
set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${DOMAIN_NAME:-}" ]] || [[ -z "${CERTBOT_EMAIL:-}" ]]; then
    echo "[ERROR] DOMAIN_NAME or CERTBOT_EMAIL is empty in .env"
    exit 1
fi

local_web_server="${WEB_SERVER:-openlitespeed}"

echo "[INFO] Initializing SSL setup for domain: ${DOMAIN_NAME}..."

# Step 1: Create directories if not exist
mkdir -p certbot/conf certbot/www nginx/conf.d ols/conf/vhosts/localhost

# Step 2: Prepare temporary HTTP challenge config via Nginx
echo "[INFO] Generating temporary HTTP challenge configuration..."
sed "s/\${DOMAIN_NAME}/${DOMAIN_NAME}/g" nginx/conf.d/http.conf.template > nginx/conf.d/default.conf

# Step 3: Start Nginx container specifically for ACME challenge
echo "[INFO] Starting lightweight ACME challenge responder..."
docker compose --profile nginx up -d nginx

# Wait for container to spin up
sleep 3

# Step 4: Request SSL certificate via Certbot container
echo "[INFO] Requesting SSL certificate from Let's Encrypt..."
docker compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
  --email ${CERTBOT_EMAIL} \
  -d ${DOMAIN_NAME} \
  --agree-tos \
  --no-eff-email \
  --force-renewal" certbot

# Step 5: Check if certificate files exist
CERT_PATH="certbot/conf/live/${DOMAIN_NAME}/fullchain.pem"
KEY_PATH="certbot/conf/live/${DOMAIN_NAME}/privkey.pem"

if [[ -f "${CERT_PATH}" ]] && [[ -f "${KEY_PATH}" ]]; then
    echo "[SUCCESS] SSL Certificate obtained successfully for ${DOMAIN_NAME}!"
    
    if [[ "$local_web_server" == "nginx" ]]; then
        echo "[INFO] Applying production HTTPS Nginx configuration..."
        sed "s/\${DOMAIN_NAME}/${DOMAIN_NAME}/g" nginx/conf.d/ssl.conf.template > nginx/conf.d/default.conf
        docker compose --profile nginx exec nginx nginx -s reload 2>/dev/null || docker compose --profile nginx restart nginx 2>/dev/null || true
        echo "[SUCCESS] HTTPS Nginx configuration is active."
    else
        echo "[INFO] SSL ready. Stopping temporary ACME responder for OpenLiteSpeed transition..."
        docker compose --profile nginx stop nginx 2>/dev/null || true
    fi
    exit 0
else
    echo "[ERROR] SSL certificate was not created. Check Certbot output above for errors."
    exit 1
fi
