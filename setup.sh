#!/usr/bin/env bash
# ==============================================================================
# Script: setup.sh
# Purpose: Automated, Isolated & Secure WordPress & LAMP Stack Manager for Docker
# ==============================================================================

set -uo pipefail

# Text formatting & Colors
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ------------------------------------------------------------------------------
# Helper Log Functions
# ------------------------------------------------------------------------------
log_info() {
    echo -e "${C_CYAN}[INFO]${C_RESET} $1"
}

log_success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"
}

log_warn() {
    echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"
}

log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1"
}

log_abort() {
    echo -e "${C_RED}[ABORT]${C_RESET} $1"
}

# ------------------------------------------------------------------------------
# Check Root Privileges
# ------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges for Docker operations."
        echo "Please re-run with: sudo $0"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Read-Only Port 80 & 443 Conflict Check
# ------------------------------------------------------------------------------
check_ports() {
    log_info "Performing read-only check for port 80 and 443 availability..."
    local ports_busy=0

    for port in 80 443; do
        local busy_info=""
        if command -v ss >/dev/null 2>&1; then
            busy_info=$(ss -tlpn "sport = :$port" 2>/dev/null | grep -v "State" || true)
        elif command -v netstat >/dev/null 2>&1; then
            busy_info=$(netstat -tlpn 2>/dev/null | grep ":$port " || true)
        elif command -v lsof >/dev/null 2>&1; then
            busy_info=$(lsof -i :"$port" -sTCP:LISTEN 2>/dev/null || true)
        fi

        if [[ -n "$busy_info" ]]; then
            # Check if port is held by our own wp_nginx container
            local is_ours=""
            if command -v docker >/dev/null 2>&1; then
                is_ours=$(docker ps --filter "name=wp_nginx" --filter "publish=$port" --format "{{.Names}}" 2>/dev/null || true)
            fi

            if [[ -n "$is_ours" ]]; then
                continue
            fi

            log_error "Port ${port} is currently in use by an existing host process:"
            echo -e "${C_YELLOW}${busy_info}${C_RESET}"
            ports_busy=1
        fi
    done

    if [[ "$ports_busy" -eq 1 ]]; then
        log_abort "Ports 80 and/or 443 are already occupied by another service on this VPS."
        echo -e "${C_YELLOW}To guarantee safety and prevent interference with existing server applications,${C_RESET}"
        echo -e "${C_YELLOW}this script will NEVER terminate or modify host services.${C_RESET}"
        echo -e "Please free up ports 80 and 443 manually, then re-run the deployment."
        return 1
    fi

    log_success "Ports 80 and 443 are available."
    return 0
}

# ------------------------------------------------------------------------------
# Check / Install Docker & Docker Compose
# ------------------------------------------------------------------------------
check_docker() {
    log_info "Verifying Docker engine and Compose plugin..."
    local need_docker=0

    if ! command -v docker >/dev/null 2>&1; then
        need_docker=1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        need_docker=1
    fi

    if [[ "$need_docker" -eq 1 ]]; then
        log_warn "Docker or Docker Compose plugin is missing."
        read -r -p "Do you want to automatically install official Docker CE? [y/N]: " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            log_info "Installing official Docker from get.docker.com..."
            curl -fsSL https://get.docker.com | sh
            systemctl enable --now docker
            log_success "Docker installed and started successfully."
        else
            log_abort "Docker is mandatory. Aborting setup."
            return 1
        fi
    else
        log_success "Docker and Docker Compose are installed and operational."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# DNS Pre-Flight Verification
# ------------------------------------------------------------------------------
verify_dns() {
    local domain="$1"
    log_info "Checking DNS resolution for domain: ${domain}..."

    local server_ip=""
    server_ip=$(curl -s4 --max-time 5 https://ifconfig.me || curl -s4 --max-time 5 https://api.ipify.org || true)

    if [[ -z "$server_ip" ]]; then
        log_warn "Could not determine server public IPv4 address. Skipping strict IP match."
        return 0
    fi

    local resolved_ip=""
    if command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short A "${domain}" | tail -n1 || true)
    elif command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent ahostsv4 "${domain}" | awk '{print $1}' | head -n1 || true)
    elif command -v host >/dev/null 2>&1; then
        resolved_ip=$(host -t A "${domain}" | awk '/has address/ {print $NF}' | head -n1 || true)
    fi

    if [[ -z "$resolved_ip" ]]; then
        log_warn "Domain ${domain} does not currently resolve to any IP address."
        read -r -p "Requesting an SSL certificate will likely fail. Proceed anyway? [y/N]: " proceed_dns
        if [[ ! "$proceed_dns" =~ ^[Yy]$ ]]; then
            return 1
        fi
        return 0
    fi

    if [[ "$resolved_ip" != "$server_ip" ]]; then
        log_warn "DNS Mismatch Detected!"
        echo -e " Server Public IP: ${C_GREEN}${server_ip}${C_RESET}"
        echo -e " Domain Resolves To: ${C_RED}${resolved_ip}${C_RESET}"
        echo -e "Let's Encrypt requires the domain to point directly to this server."
        read -r -p "Do you still want to proceed? [y/N]: " proceed_dns
        if [[ ! "$proceed_dns" =~ ^[Yy]$ ]]; then
            return 1
        fi
    else
        log_success "DNS verified! ${domain} correctly points to ${server_ip}."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Core Deployment (Mode 1: Fresh WordPress / Mode 2: Duplicator/Backupino Ready)
# ------------------------------------------------------------------------------
deploy_stack() {
    local mode="$1" # "fresh" or "migration"

    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    if [[ "$mode" == "fresh" ]]; then
        echo -e "  ${C_CYAN}DEPLOY FRESH WORDPRESS (Nginx + PHP + Isolated DB + SSL)${C_RESET}"
    else
        echo -e "  ${C_CYAN}DEPLOY STACK FOR MIGRATION (Duplicator / Backupino Ready)${C_RESET}"
    fi
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    # Step 1: Pre-checks
    check_ports || return 1
    check_docker || return 1

    # Step 2: Select DB Engine
    echo ""
    echo "Select Isolated Database Engine:"
    echo "  1) MariaDB 10.11 LTS (Recommended - Fast & Resource Efficient)"
    echo "  2) MySQL 8.0"
    read -r -p "Enter choice [1-2, default: 1]: " db_choice
    local db_image="mariadb:10.11"
    if [[ "$db_choice" == "2" ]]; then
        db_image="mysql:8.0"
    fi
    log_info "Selected database engine: ${db_image}"

    # Step 3: Domain Name
    echo ""
    read -r -p "Enter Domain Name (e.g. site.example.com): " domain_input
    domain_input=$(echo "${domain_input}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    while [[ -z "$domain_input" || ! "$domain_input" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
        log_warn "Invalid domain name. Please enter a valid FQDN."
        read -r -p "Enter Domain Name: " domain_input
        domain_input=$(echo "${domain_input}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    done

    # Step 4: Admin Email for SSL
    read -r -p "Enter Admin Email (for SSL renewal alerts): " email_input
    email_input=$(echo "${email_input}" | tr -d ' ')
    while [[ -z "$email_input" || ! "$email_input" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
        log_warn "Invalid email format."
        read -r -p "Enter Admin Email: " email_input
        email_input=$(echo "${email_input}" | tr -d ' ')
    done

    # Step 5: DNS Check
    verify_dns "${domain_input}" || return 1

    # Step 6: Database Name
    read -r -p "Enter Database Name [default: wordpress]: " db_name_input
    db_name_input=${db_name_input:-wordpress}
    while [[ ! "$db_name_input" =~ ^[a-zA-Z0-9_]+$ ]]; do
        log_warn "Database name must contain only alphanumeric characters and underscores."
        read -r -p "Enter Database Name [default: wordpress]: " db_name_input
        db_name_input=${db_name_input:-wordpress}
    done

    # Step 7: Database User
    read -r -p "Enter Database User [default: wp_user]: " db_user_input
    db_user_input=${db_user_input:-wp_user}
    while [[ ! "$db_user_input" =~ ^[a-zA-Z0-9_]+$ ]]; do
        log_warn "Database user must contain only alphanumeric characters and underscores."
        read -r -p "Enter Database User [default: wp_user]: " db_user_input
        db_user_input=${db_user_input:-wp_user}
    done

    # Step 8: Database Password
    read -r -s -p "Enter Database Password (leave blank to auto-generate): " db_pass_input
    echo ""
    if [[ -z "$db_pass_input" ]]; then
        db_pass_input=$(tr -dc 'A-Za-z0-9!#%*+,-./:=?@_' </dev/urandom | head -c 24 || true)
        log_info "Auto-generated secure database user password."
    fi

    # Root Password for DB (Auto-generated)
    local db_root_pass
    db_root_pass=$(tr -dc 'A-Za-z0-9!#%*+,-./:=?@_' </dev/urandom | head -c 32 || true)

    # Step 9: Save .env securely
    log_info "Writing environment configuration (.env)..."
    cat <<EOF > .env
# Auto-generated by setup.sh on $(date -u)
DOMAIN_NAME=${domain_input}
CERTBOT_EMAIL=${email_input}
DB_IMAGE=${db_image}
DB_NAME=${db_name_input}
DB_USER=${db_user_input}
DB_PASSWORD=${db_pass_input}
DB_ROOT_PASSWORD=${db_root_pass}
WP_TABLE_PREFIX=wp_
EOF
    chmod 600 .env

    # Step 10: Request SSL
    chmod +x scripts/*.sh
    log_info "Starting two-stage SSL bootstrap..."
    if ! bash scripts/ssl-init.sh; then
        log_error "SSL initialization failed. Please check Certbot logs above."
        return 1
    fi

    # Step 11: Launch Full Stack
    log_info "Starting full WordPress & isolated database stack..."
    docker compose up -d

    echo ""
    log_info "Waiting for database and WordPress services to stabilize..."
    sleep 5

    # Step 12: Output Result
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "  ${C_GREEN}DEPLOYMENT COMPLETED SUCCESSFULLY!${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e " Website URL:         ${C_CYAN}https://${domain_input}${C_RESET}"
    echo -e " SSL Status:          ${C_GREEN}Active (Let's Encrypt with Auto-Renewal)${C_RESET}"
    echo -e " Database Host:       ${C_BOLD}db${C_RESET} (Internal Docker network only)"
    echo -e " Internal Port:       3306"
    echo -e " Database Name:       ${db_name_input}"
    echo -e " Database User:       ${db_user_input}"
    echo -e " Database Password:   ${db_pass_input}"
    echo -e " Database Root Pass:  ${db_root_pass}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ "$mode" == "fresh" ]]; then
        echo -e " To complete WordPress installation:"
        echo -e " 1. Open your browser and navigate to: ${C_CYAN}https://${domain_input}${C_RESET}"
        echo -e " 2. Follow the 5-minute WordPress setup wizard."
    else
        echo -e " ${C_YELLOW}MIGRATION / RESTORATION INSTRUCTIONS (Duplicator / Backupino):${C_RESET}"
        echo -e " 1. Upload your 'installer.php' and backup archive file to the WordPress web root volume:"
        echo -e "    Container Path: /var/www/html"
        echo -e "    Or copy files using docker:"
        echo -e "    ${C_BOLD}docker cp installer.php wp_app:/var/www/html/${C_RESET}"
        echo -e "    ${C_BOLD}docker cp archive.zip wp_app:/var/www/html/${C_RESET}"
        echo -e "    ${C_BOLD}docker exec -it wp_app chown -R www-data:www-data /var/www/html${C_RESET}"
        echo -e " 2. In your browser, open: ${C_CYAN}https://${domain_input}/installer.php${C_RESET}"
        echo -e " 3. Enter the Database credentials shown above (Host: 'db')."
    fi
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# Update Stack Dependencies & Images
# ------------------------------------------------------------------------------
update_dependencies() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "         ${C_CYAN}UPDATE STACK DEPENDENCIES & CONTAINER IMAGES${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    log_info "Pulling newest container images for this stack..."
    docker compose pull

    log_info "Recreating containers with updated images..."
    docker compose up -d

    log_success "WordPress stack containers have been updated successfully."
}

# ------------------------------------------------------------------------------
# Service Status & Health Check
# ------------------------------------------------------------------------------
check_status() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                 ${C_CYAN}STACK SERVICE STATUS & HEALTH${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_warn "Stack is not deployed (.env is missing)."
        return 0
    fi

    echo -e "${C_BOLD}[Container Status]${C_RESET}"
    docker compose ps

    echo ""
    echo -e "${C_BOLD}[Resource Usage (Memory & CPU)]${C_RESET}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" \
      $(docker compose ps -q 2>/dev/null) 2>/dev/null || echo "Containers are not running."

    echo ""
    if [[ -f .env ]]; then
        # shellcheck disable=SC1091
        local dom
        dom=$(grep '^DOMAIN_NAME=' .env | cut -d '=' -f2)
        if [[ -n "$dom" ]]; then
            echo -e "${C_BOLD}[HTTP/HTTPS Endpoint Check]${C_RESET}"
            curl -Is "https://${dom}" 2>/dev/null | head -n 5 || echo "Could not reach https://${dom}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# View Service Logs
# ------------------------------------------------------------------------------
view_logs() {
    while true; do
        echo ""
        echo -e "${C_BOLD}====================================================================${C_RESET}"
        echo -e "                       ${C_CYAN}VIEW SERVICE LOGS${C_RESET}"
        echo -e "${C_BOLD}====================================================================${C_RESET}"
        echo " [1] Nginx Web Server Logs"
        echo " [2] WordPress (PHP-FPM) Logs"
        echo " [3] Isolated Database Logs"
        echo " [4] Certbot SSL Renewal Logs"
        echo " [5] View All Logs (Real-time stream, Ctrl+C to exit)"
        echo " [0] Back to Main Menu"
        echo -e "${C_BOLD}====================================================================${C_RESET}"
        read -r -p "Enter choice [0-5]: " log_choice

        case "$log_choice" in
            1) docker compose logs --tail=100 nginx ;;
            2) docker compose logs --tail=100 wordpress ;;
            3) docker compose logs --tail=100 db ;;
            4) docker compose logs --tail=100 certbot ;;
            5) docker compose logs -f --tail=50 ;;
            0) break ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Self-Update Script from GitHub
# ------------------------------------------------------------------------------
self_update() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                   ${C_CYAN}SELF-UPDATE FROM GITHUB${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_error "This installation directory is not a Git repository."
        echo "Please ensure the script was cloned via git clone."
        return 1
    fi

    log_info "Fetching latest commits from remote repository..."
    git fetch origin

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    log_info "Pulling latest updates for branch: ${current_branch}..."
    if git pull origin "${current_branch}"; then
        chmod +x setup.sh scripts/*.sh 2>/dev/null || true
        log_success "Script successfully updated to latest version."
        echo "Reloading script..."
        sleep 1
        exec bash "$0" "$@"
    else
        log_error "Failed to pull updates from Git. Check your internet connection or git status."
    fi
}

# ------------------------------------------------------------------------------
# Complete Uninstall (Strictly Isolated to This Stack)
# ------------------------------------------------------------------------------
uninstall_stack() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "     ${C_RED}DANGER ZONE: COMPLETE UNINSTALL OF THIS WORDPRESS STACK${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "${C_YELLOW}This operation will strictly target ONLY this WordPress deployment:${C_RESET}"
    echo " - Stop & remove containers (wp_nginx, wp_app, wp_db, wp_certbot)"
    echo " - Delete the dedicated volumes (wp_data, wp_db_data)"
    echo " - Remove the dedicated Docker network (wp_network)"
    echo ""
    echo -e "${C_GREEN}SAFETY GUARANTEE:${C_RESET}"
    echo " - Any other database, Docker container, or panel on this VPS will NOT be affected."
    echo " - Host packages, firewall, and other services will remain untouched."
    echo ""
    read -r -p "Type 'yes' in all lowercase to confirm uninstallation: " confirm_uninstall

    if [[ "$confirm_uninstall" != "yes" ]]; then
        log_info "Uninstall aborted. Nothing was changed."
        return 0
    fi

    log_info "Stopping and removing stack containers and volumes..."
    docker compose down -v --rmi local 2>/dev/null || docker compose down -v 2>/dev/null || true

    log_info "Cleaning configuration and SSL cache..."
    rm -f .env nginx/conf.d/default.conf
    rm -rf certbot/conf/* certbot/www/*

    log_success "WordPress stack has been completely and safely removed."
}

# ------------------------------------------------------------------------------
# Interactive Main Menu
# ------------------------------------------------------------------------------
main_menu() {
    check_root

    while true; do
        echo ""
        echo -e "${C_CYAN}${C_BOLD}"
        echo "===================================================================="
        echo "           WordPress & Docker Stack Manager (Isolated)"
        echo "===================================================================="
        echo -e "${C_RESET}"
        echo -e " [${C_BOLD}1${C_RESET}] Deploy Fresh WordPress (Nginx, PHP, WP Core, Isolated DB & SSL)"
        echo -e " [${C_BOLD}2${C_RESET}] Deploy Stack for Migration / Restore (Duplicator & Backupino Ready)"
        echo -e " [${C_BOLD}3${C_RESET}] Create New Database & User (Inside Existing DB Container)"
        echo -e " [${C_BOLD}4${C_RESET}] Update Dependencies & Container Images"
        echo -e " [${C_BOLD}5${C_RESET}] Service Status & Health Check"
        echo -e " [${C_BOLD}6${C_RESET}] View Service Logs (Nginx, PHP, Database, Certbot)"
        echo -e " [${C_BOLD}7${C_RESET}] Self-Update Script (Pull latest from GitHub)"
        echo -e " [${C_BOLD}8${C_RESET}] Complete Uninstall (Safe Purge of this Stack Only)"
        echo -e " [${C_BOLD}0${C_RESET}] Exit"
        echo -e "${C_CYAN}====================================================================${C_RESET}"
        read -r -p "Enter choice [0-8] and press Enter: " user_choice

        case "$user_choice" in
            1) deploy_stack "fresh" ;;
            2) deploy_stack "migration" ;;
            3) bash scripts/db-create.sh ;;
            4) update_dependencies ;;
            5) check_status ;;
            6) view_logs ;;
            7) self_update ;;
            8) uninstall_stack ;;
            0)
                echo "Exiting. Goodbye!"
                exit 0
                ;;
            *)
                log_warn "Invalid selection. Please choose a number between 0 and 8."
                ;;
        esac
    done
}

main_menu "$@"
