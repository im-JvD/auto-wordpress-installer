#!/usr/bin/env bash
# ==============================================================================
# Script: ssl-init.sh
# Purpose: Two-stage Let's Encrypt SSL Certificate Bootstrap with Nginx & Certbot
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

echo "[INFO] Initializing SSL setup for domain: ${DOMAIN_NAME}..."

# Step 1: Create directories if not exist
mkdir -p certbot/conf certbot/www nginx/conf.d

# Step 2: Prepare temporary HTTP config
echo "[INFO] Generating temporary HTTP challenge configuration..."
sed "s/\${DOMAIN_NAME}/${DOMAIN_NAME}/g" nginx/conf.d/http.conf.template > nginx/conf.d/default.conf

# Step 3: Start Nginx container only for ACME challenge
echo "[INFO] Starting Nginx for ACME challenge..."
docker compose up -d nginx

# Wait for Nginx to spin up
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
    
    # Step 6: Apply production SSL configuration
    echo "[INFO] Applying production HTTPS Nginx configuration..."
    sed "s/\${DOMAIN_NAME}/${DOMAIN_NAME}/g" nginx/conf.d/ssl.conf.template > nginx/conf.d/default.conf
    
    echo "[INFO] Reloading Nginx with SSL configuration..."
    docker compose exec nginx nginx -s reload || docker compose restart nginx
    echo "[SUCCESS] HTTPS configuration is active."
    exit 0
else
    echo "[ERROR] SSL certificate was not created. Check Certbot output above for errors."
    exit 1
fi
