#!/usr/bin/env bash
# ==============================================================================
# Script: db-create.sh
# Purpose: Create an additional isolated Database and User inside the DB container
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
    echo "[ERROR] .env file not found. Please deploy the stack first."
    exit 1
fi

# Load variables
set -a
# shellcheck disable=SC1091
source .env
set +a

# Check if database container is running
if ! docker ps --filter "name=wp_db" --filter "status=running" | grep -q "wp_db"; then
    echo "[ERROR] Database container (wp_db) is not currently running."
    echo "[INFO] Start the stack first or check status using the main menu."
    exit 1
fi

echo "===================================================================="
echo "              CREATE NEW DATABASE & USER (ISOLATED)"
echo "===================================================================="

# Prompt for Database Name
read -r -p "Enter New Database Name: " NEW_DB_NAME
while [[ -z "${NEW_DB_NAME}" || ! "${NEW_DB_NAME}" =~ ^[a-zA-Z0-9_]+$ ]]; do
    echo "[WARN] Database name must only contain alphanumeric characters and underscores."
    read -r -p "Enter New Database Name: " NEW_DB_NAME
done

# Prompt for Database User
read -r -p "Enter New Database User: " NEW_DB_USER
while [[ -z "${NEW_DB_USER}" || ! "${NEW_DB_USER}" =~ ^[a-zA-Z0-9_]+$ ]]; do
    echo "[WARN] Database username must only contain alphanumeric characters and underscores."
    read -r -p "Enter New Database User: " NEW_DB_USER
done

# Prompt for Database Password (or generate)
read -r -s -p "Enter New Database Password (leave blank to auto-generate): " NEW_DB_PASS
echo ""
if [[ -z "${NEW_DB_PASS}" ]]; then
    NEW_DB_PASS=$(tr -dc 'A-Za-z0-9!#%*+,-./:=?@_' </dev/urandom | head -c 24 || true)
    echo "[INFO] Auto-generated secure password."
fi

echo "[INFO] Creating database and granting privileges..."

SQL_CMD="
CREATE DATABASE IF NOT EXISTS \`${NEW_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${NEW_DB_USER}'@'%' IDENTIFIED BY '${NEW_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${NEW_DB_NAME}\`.* TO '${NEW_DB_USER}'@'%';
FLUSH PRIVILEGES;
"

if docker exec -i wp_db mysql -u root -p"${DB_ROOT_PASSWORD}" -e "${SQL_CMD}" 2>/dev/null; then
    echo ""
    echo "===================================================================="
    echo "         DATABASE & USER CREATED SUCCESSFULLY!"
    echo "===================================================================="
    echo " Database Host:     db"
    echo " Internal Port:     3306"
    echo " Database Name:     ${NEW_DB_NAME}"
    echo " Database User:     ${NEW_DB_USER}"
    echo " Database Password: ${NEW_DB_PASS}"
    echo "===================================================================="
    echo " Note: In WordPress / Duplicator / Backupino, use 'db' as the DB Host."
    echo "===================================================================="
else
    echo "[ERROR] Failed to execute database queries inside container."
    exit 1
fi
