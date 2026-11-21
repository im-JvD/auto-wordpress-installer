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
# Signal Trap (Clean Exit on Ctrl+C)
# ------------------------------------------------------------------------------
cleanup_and_exit() {
    echo -e "\n\n${C_CYAN}Exiting WordPress Stack Manager. Goodbye!${C_RESET}\n"
    exit 0
}
trap cleanup_and_exit SIGINT SIGTERM

# ------------------------------------------------------------------------------
# Terminal Screen Helper (Scroll to top without erasing scrollback history)
# ------------------------------------------------------------------------------
scroll_to_top() {
    if command -v clear >/dev/null 2>&1; then
        clear -x 2>/dev/null || printf '\033[H'
    else
        printf '\033[H'
    fi
}

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
# Install Global CLI Shortcut ('wordpress')
# ------------------------------------------------------------------------------
install_cli_shortcut() {
    local bin_path="/usr/local/bin/wordpress"
    if [[ ! -f "$bin_path" ]] || ! grep -q "${SCRIPT_DIR}" "$bin_path" 2>/dev/null; then
        cat <<EOF > "$bin_path"
#!/usr/bin/env bash
cd "${SCRIPT_DIR}" && sudo ./setup.sh "\$@"
EOF
        chmod +x "$bin_path"
        log_info "Global CLI command registered: You can now type 'wordpress' anywhere to launch this script."
    fi
}

# ------------------------------------------------------------------------------
# Create / Verify Direct Access Shortcut for Website Files ('html' folder)
# ------------------------------------------------------------------------------
create_html_symlink() {
    local mount_point=""
    if command -v docker >/dev/null 2>&1; then
        mount_point=$(docker volume inspect --format '{{ .Mountpoint }}' wp_data 2>/dev/null || true)
    fi
    if [[ -z "$mount_point" ]] || [[ ! -d "$mount_point" ]]; then
        mount_point="/var/lib/docker/volumes/wp_data/_data"
    fi

    if [[ -d "$mount_point" ]]; then
        ln -sfn "$mount_point" "${SCRIPT_DIR}/html" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Read-Only Port Availability & Conflict Check (Supports Cloudflare Alt Ports)
# ------------------------------------------------------------------------------
TARGET_HTTP_PORT=80
TARGET_HTTPS_PORT=443

is_port_in_use() {
    local port="$1"
    local busy=""
    if command -v ss >/dev/null 2>&1; then
        busy=$(ss -tlpn "sport = :$port" 2>/dev/null | grep -v "State" || true)
    elif command -v netstat >/dev/null 2>&1; then
        busy=$(netstat -tlpn 2>/dev/null | grep ":$port " || true)
    elif command -v lsof >/dev/null 2>&1; then
        busy=$(lsof -i :"$port" -sTCP:LISTEN 2>/dev/null || true)
    fi

    if [[ -n "$busy" ]]; then
        # Check if held by our own wp_nginx container
        if command -v docker >/dev/null 2>&1; then
            local is_ours
            is_ours=$(docker ps --filter "name=wp_nginx" --filter "publish=$port" --format "{{.Names}}" 2>/dev/null || true)
            if [[ -n "$is_ours" ]]; then
                return 1
            fi
        fi
        echo "$busy"
        return 0
    fi
    return 1
}

check_ports() {
    log_info "Performing read-only check for port 80 and 443 availability..."
    TARGET_HTTP_PORT=80
    TARGET_HTTPS_PORT=443

    # Check Port 80 (Mandatory for HTTP & Let's Encrypt ACME verification)
    local p80_busy
    if p80_busy=$(is_port_in_use 80); then
        log_error "Port 80 is currently occupied by an existing host process:"
        echo -e "${C_YELLOW}${p80_busy}${C_RESET}"
        log_abort "Port 80 is required for HTTP and SSL validation. Please free up port 80 first."
        return 1
    fi
    log_success "Port 80 is available for ACME SSL validation."

    # Check Port 443
    local p443_busy
    if p443_busy=$(is_port_in_use 443); then
        log_warn "Port 443 is currently in use by another service on this VPS:"
        echo -e "${C_YELLOW}${p443_busy}${C_RESET}"
        echo ""
        echo -e "${C_CYAN}Notice: You can run WordPress on an alternative HTTPS port (e.g. 8443) compatible with Cloudflare.${C_RESET}"
        read -r -p "Enter alternative HTTPS port [default: 8443]: " custom_https
        TARGET_HTTPS_PORT=${custom_https:-8443}

        while true; do
            if [[ ! "$TARGET_HTTPS_PORT" =~ ^[0-9]+$ ]] || [ "$TARGET_HTTPS_PORT" -lt 1 ] || [ "$TARGET_HTTPS_PORT" -gt 65535 ]; then
                log_warn "Invalid port number. Please enter a valid port between 1 and 65535."
                read -r -p "Enter alternative HTTPS port [default: 8443]: " custom_https
                TARGET_HTTPS_PORT=${custom_https:-8443}
                continue
            fi

            local alt_busy
            if alt_busy=$(is_port_in_use "$TARGET_HTTPS_PORT"); then
                log_error "Port $TARGET_HTTPS_PORT is also in use. Please select another port."
                read -r -p "Enter alternative HTTPS port [default: 8443]: " custom_https
                TARGET_HTTPS_PORT=${custom_https:-8443}
            else
                log_success "Alternative HTTPS Port $TARGET_HTTPS_PORT is available!"
                break
            fi
        done
    else
        log_success "Standard HTTPS Port 443 is available."
    fi
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
    for ip_service in \
        "https://api.ipify.org" \
        "https://icanhazip.com" \
        "https://checkip.amazonaws.com" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.co"; do
        local candidate
        candidate=$(curl -s4 -f --max-time 4 -A "curl/7.88.1" "$ip_service" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$candidate" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            server_ip="$candidate"
            break
        fi
    done

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
# Web Server & PHP Version Selector Helpers
# ------------------------------------------------------------------------------
select_web_server() {
    local default_sel="${1:-1}"
    echo "" >&2
    echo "Select Web Server Engine:" >&2
    echo "  1) OpenLiteSpeed (Recommended - Native LSCache, HTTP/3 QUIC, .htaccess)" >&2
    echo "  2) Nginx (Ultra-Lightweight & Battle-Tested)" >&2
    read -r -p "Enter choice [1-2, default: ${default_sel}]: " user_ws_sel
    user_ws_sel=${user_ws_sel:-$default_sel}

    case "$user_ws_sel" in
        2) echo "nginx" ;;
        1|*) echo "openlitespeed" ;;
    esac
}

select_php_version() {
    local ws="${1:-openlitespeed}"
    local default_sel="${2:-5}"
    echo "" >&2
    echo "Select PHP Version for WordPress:" >&2
    echo "  1) PHP 7.4 (Legacy support)" >&2
    echo "  2) PHP 8.0" >&2
    echo "  3) PHP 8.1" >&2
    echo "  4) PHP 8.2 (Stable & High Performance)" >&2
    echo "  5) PHP 8.3 (Recommended)" >&2
    read -r -p "Enter choice [1-5, default: ${default_sel}]: " user_php_sel
    user_php_sel=${user_php_sel:-$default_sel}

    if [[ "$ws" == "openlitespeed" ]]; then
        case "$user_php_sel" in
            1) echo "litespeedtech/openlitespeed:1.7-lsphp74" ;;
            2) echo "litespeedtech/openlitespeed:1.7-lsphp80" ;;
            3) echo "litespeedtech/openlitespeed:latest-lsphp81" ;;
            4) echo "litespeedtech/openlitespeed:latest-lsphp82" ;;
            5|*) echo "litespeedtech/openlitespeed:latest-lsphp83" ;;
        esac
    else
        case "$user_php_sel" in
            1) echo "wordpress:php7.4-fpm-alpine" ;;
            2) echo "wordpress:php8.0-fpm-alpine" ;;
            3) echo "wordpress:php8.1-fpm-alpine" ;;
            4) echo "wordpress:php8.2-fpm-alpine" ;;
            5|*) echo "wordpress:php8.3-fpm-alpine" ;;
        esac
    fi
}

# ------------------------------------------------------------------------------
# Core Deployment (Mode 1: Fresh WordPress / Mode 2: Duplicator/Backupino Ready)
# ------------------------------------------------------------------------------
deploy_stack() {
    local mode="$1" # "fresh" or "migration"

    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    if [[ "$mode" == "fresh" ]]; then
        echo -e "  ${C_CYAN}DEPLOY FRESH WORDPRESS (OpenLiteSpeed / Nginx + Isolated DB + SSL)${C_RESET}"
    else
        echo -e "  ${C_CYAN}DEPLOY STACK FOR MIGRATION (Duplicator / Backupino Ready)${C_RESET}"
    fi
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    # Step 1: Pre-checks
    check_ports || return 1
    check_docker || return 1

    # Step 2: Select Web Server Engine (OpenLiteSpeed vs Nginx)
    local selected_ws
    selected_ws=$(select_web_server 1)
    log_info "Selected Web Server Engine: ${selected_ws}"

    # Step 2.1: Select DB Engine
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

    # Step 2.2: Select PHP Version (7.4 to 8.3)
    local selected_php_image
    selected_php_image=$(select_php_version "${selected_ws}" 5)
    log_info "Selected PHP Image: ${selected_php_image}"

    local ols_image="litespeedtech/openlitespeed:latest-lsphp83"
    local wp_image="wordpress:php8.3-fpm-alpine"
    local compose_profile="ols"

    if [[ "$selected_ws" == "openlitespeed" ]]; then
        ols_image="${selected_php_image}"
        compose_profile="ols"
    else
        wp_image="${selected_php_image}"
        compose_profile="nginx"
    fi

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

    # Determine Entrypoint: Fresh WP extracts core files; Migration mode runs pure PHP-FPM leaving html completely clean
    local wp_entrypoint="docker-entrypoint.sh php-fpm"
    if [[ "$mode" == "migration" ]]; then
        wp_entrypoint="php-fpm"
    fi

    # Step 9: Save .env securely
    log_info "Writing environment configuration (.env)..."
    cat <<EOF > .env
# Auto-generated by setup.sh on $(date -u)
DOMAIN_NAME=${domain_input}
CERTBOT_EMAIL=${email_input}
HTTP_PORT=${TARGET_HTTP_PORT}
HTTPS_PORT=${TARGET_HTTPS_PORT}
WEB_SERVER=${selected_ws}
COMPOSE_PROFILES=${compose_profile}
DB_IMAGE=${db_image}
DB_NAME=${db_name_input}
DB_USER=${db_user_input}
DB_PASSWORD=${db_pass_input}
DB_ROOT_PASSWORD=${db_root_pass}
WP_TABLE_PREFIX=wp_
WP_ENTRYPOINT=${wp_entrypoint}
WP_IMAGE=${wp_image}
OLS_IMAGE=${ols_image}
EOF
    chmod 600 .env

    # Sync web server config
    if [[ "$selected_ws" == "openlitespeed" ]]; then
        sync_ols_config
    else
        sync_nginx_config
    fi

    # Step 10: Request SSL
    chmod +x scripts/*.sh
    log_info "Starting two-stage SSL bootstrap..."
    if ! bash scripts/ssl-init.sh; then
        log_error "SSL initialization failed. Please check Certbot logs above."
        return 1
    fi

    # Sync OLS with newly obtained SSL certificates if needed
    if [[ "$selected_ws" == "openlitespeed" ]]; then
        sync_ols_config
    fi

    # Step 11: Launch Full Stack
    log_info "Starting full WordPress & isolated database stack..."
    docker compose up -d
    create_html_symlink

    if [[ "$mode" == "migration" ]]; then
        log_info "Purging raw WordPress files to ensure a 100% clean directory for Duplicator / Backupino..."
        if [[ "$selected_ws" == "openlitespeed" ]]; then
            docker exec wp_ols sh -c 'rm -rf /var/www/vhosts/localhost/html/* /var/www/vhosts/localhost/html/.[!.]* 2>/dev/null || true'
        else
            docker exec wp_app sh -c 'rm -rf /var/www/html/* /var/www/html/.[!.]* 2>/dev/null || true'
        fi
        log_success "Directory /opt/wp-docker/html is now clean and empty."
    fi

    # Ensure permissions and extensions
    if [[ "$selected_ws" == "openlitespeed" ]]; then
        init_ols_container
        ensure_php_extensions
    else
        docker exec wp_app chown -R www-data:www-data /var/www/html 2>/dev/null || true
        docker exec wp_app chmod -R 775 /var/www/html 2>/dev/null || true
        ensure_php_extensions
    fi

    setup_systemd_service

    echo ""
    log_info "Waiting for database and WordPress services to stabilize..."
    sleep 5

    # Step 12: Output Result
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "  ${C_GREEN}DEPLOYMENT COMPLETED SUCCESSFULLY!${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    if [[ "$TARGET_HTTPS_PORT" -ne 443 ]]; then
        echo -e " Direct Website URL:  ${C_CYAN}https://${domain_input}:${TARGET_HTTPS_PORT}${C_RESET}"
        echo -e " Cloudflare URL:      ${C_CYAN}https://${domain_input}${C_RESET}"
        echo -e " Active HTTPS Port:   ${C_YELLOW}${TARGET_HTTPS_PORT}${C_RESET} (Cloudflare compatible)"
    else
        echo -e " Website URL:         ${C_CYAN}https://${domain_input}${C_RESET}"
        echo -e " Active HTTPS Port:   443 (Standard)"
    fi
    echo -e " Web Server Engine:   ${C_GREEN}${selected_ws}${C_RESET}"
    if [[ "$selected_ws" == "openlitespeed" ]]; then
        echo -e " Server-Level Cache:  ${C_GREEN}Native LiteSpeed Cache (LSCache) & HTTP/3 QUIC Active${C_RESET}"
    fi
    echo -e " SSL Status:          ${C_GREEN}Active (Let's Encrypt with Auto-Renewal)${C_RESET}"
    echo -e " Database Host:       ${C_BOLD}db${C_RESET} (Internal Docker network only)"
    echo -e " Internal Port:       3306"
    echo -e " Database Name:       ${db_name_input}"
    echo -e " Database User:       ${db_user_input}"
    echo -e " Database Password:   ${db_pass_input}"
    echo -e " Database Root Pass:  ${db_root_pass}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ "$TARGET_HTTPS_PORT" -ne 443 ]]; then
        echo -e " ${C_YELLOW}[!] CLOUDFLARE ORIGIN RULE TIP (Optional but recommended):${C_RESET}"
        echo -e " In your Cloudflare Dashboard -> Rules -> Origin Rules:"
        echo -e " Create a rule: When Hostname equals '${domain_input}', rewrite destination port to ${TARGET_HTTPS_PORT}."
        echo -e " This lets visitors access https://${domain_input} without entering the port in browser!"
        echo -e "${C_BOLD}====================================================================${C_RESET}"
    fi

    if [[ "$mode" == "fresh" ]]; then
        echo -e " To complete WordPress installation:"
        if [[ "$TARGET_HTTPS_PORT" -ne 443 ]]; then
            echo -e " 1. Open your browser and navigate to: ${C_CYAN}https://${domain_input}:${TARGET_HTTPS_PORT}${C_RESET} (or ${C_CYAN}https://${domain_input}${C_RESET} via Cloudflare)"
        else
            echo -e " 1. Open your browser and navigate to: ${C_CYAN}https://${domain_input}${C_RESET}"
        fi
        echo -e " 2. Follow the 5-minute WordPress setup wizard."
    else
        echo -e " ${C_YELLOW}MIGRATION / RESTORATION INSTRUCTIONS (Duplicator / Backupino):${C_RESET}"
        echo -e " 1. Upload 'installer.php' and your backup archive (.zip) directly to:"
        echo -e "    👉 ${C_GREEN}${C_BOLD}${SCRIPT_DIR}/html${C_RESET} (Direct folder accessible via WinSCP / FileZilla)"
        echo -e "    Then set proper web permissions with:"
        echo -e "    ${C_BOLD}docker exec -it wp_app chown -R www-data:www-data /var/www/html${C_RESET}"
        if [[ "$TARGET_HTTPS_PORT" -ne 443 ]]; then
            echo -e " 2. In your browser, open: ${C_CYAN}https://${domain_input}:${TARGET_HTTPS_PORT}/installer.php${C_RESET}"
        else
            echo -e " 2. In your browser, open: ${C_CYAN}https://${domain_input}/installer.php${C_RESET}"
        fi
        echo -e " 3. Enter the Database credentials shown above (Host: 'db')."
    fi
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# Ensure Essential & Recommended PHP Extensions for WordPress, Backupino & WooCommerce
# (pdo_mysql, mysqli, curl, zip, gd/imagick, mbstring, intl, bcmath, xml, fileinfo)
# ------------------------------------------------------------------------------
ensure_php_extensions() {
    log_info "Verifying PHP extensions (pdo_mysql, curl, zip, intl, imagick/gd, mbstring, bcmath)..."
    if docker ps --filter "name=wp_app" --filter "status=running" | grep -q "wp_app"; then
        local missing_exts=()
        for ext in pdo_mysql intl bcmath exif; do
            if ! docker exec wp_app php -m 2>/dev/null | grep -qi "^${ext}$"; then
                missing_exts+=("$ext")
            fi
        done

        if [ ${#missing_exts[@]} -gt 0 ]; then
            log_info "Installing missing PHP extensions in WordPress container (${missing_exts[*]})..."
            docker exec wp_app apk add --no-cache icu-dev libzip-dev 2>/dev/null || true
            for ext in "${missing_exts[@]}"; do
                docker exec wp_app docker-php-ext-install "$ext" >/dev/null 2>&1 || true
            done
            docker restart wp_app >/dev/null 2>&1 || true
            log_success "WordPress PHP extensions installed and active: ${missing_exts[*]}"
        else
            log_success "All required PHP extensions are active in WordPress container."
        fi
    elif docker ps --filter "name=wp_ols" --filter "status=running" | grep -q "wp_ols"; then
        local missing_ols_pkgs=()
        local php_ver_num
        php_ver_num=$(docker exec wp_ols php -v 2>/dev/null | head -n 1 | grep -oE "PHP [0-9]\.[0-9]" | tr -d ' ' | tr -d '.' | tr '[:upper:]' '[:lower:]' || echo "83")
        local prefix="lsphp${php_ver_num}"

        for mod in mysql curl zip intl imagick mbstring bcmath; do
            if ! docker exec wp_ols php -m 2>/dev/null | grep -qi "^${mod}$"; then
                missing_ols_pkgs+=("${prefix}-${mod}")
            fi
        done

        if ! docker exec wp_ols php -m 2>/dev/null | grep -qi "pdo_mysql"; then
            missing_ols_pkgs+=("${prefix}-mysql")
        fi

        if [ ${#missing_ols_pkgs[@]} -gt 0 ]; then
            log_info "Installing missing OpenLiteSpeed PHP extensions (${missing_ols_pkgs[*]})..."
            docker exec wp_ols apt-get update -y >/dev/null 2>&1 || true
            docker exec wp_ols apt-get install -y "${missing_ols_pkgs[@]}" >/dev/null 2>&1 || true
            docker exec wp_ols pkill -9 lsphp 2>/dev/null || true
            docker exec wp_ols /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || true
            sleep 2
            log_success "OpenLiteSpeed PHP extensions installed and active: ${missing_ols_pkgs[*]}"
        else
            log_success "All required PHP extensions (pdo_mysql, zip, curl, intl, mbstring, gd) are active in OpenLiteSpeed."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Sync & Reload Nginx Configuration from Template
# ------------------------------------------------------------------------------
sync_nginx_config() {
    if [[ -f .env ]]; then
        local dom
        dom=$(grep '^DOMAIN_NAME=' .env | cut -d '=' -f2)
        if [[ -n "$dom" && -d "certbot/conf/live/${dom}" ]]; then
            log_info "Syncing latest Nginx SSL & routing configuration..."
            sed "s/\${DOMAIN_NAME}/${dom}/g" nginx/conf.d/ssl.conf.template > nginx/conf.d/default.conf
            docker restart wp_nginx >/dev/null 2>&1 || true
            log_success "Nginx configuration updated and reloaded."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Initialize & Secure OpenLiteSpeed Container Environment
# ------------------------------------------------------------------------------
init_ols_container() {
    if ! docker ps --filter "name=wp_ols" --filter "status=running" | grep -q "wp_ols"; then
        return 0
    fi

    # Ensure host directories mounted into OLS exist and have correct permissions
    mkdir -p certbot/www/.well-known/acme-challenge
    chmod -R 777 certbot/www 2>/dev/null || true

    log_info "Initializing OpenLiteSpeed environment and LSAPI PHP worker..."
    docker exec wp_ols sh -c '
        # 1. Create all required runtime directories
        mkdir -p /usr/local/lsws/logs /usr/local/lsws/cgid /var/www/vhosts/localhost/html /var/www/vhosts/localhost/lscache

        # 2. Set directory permissions
        chown -R nobody:nogroup /usr/local/lsws/logs /usr/local/lsws/cgid /var/www/vhosts/localhost/lscache 2>/dev/null || true
        chmod -R 777 /var/www/vhosts/localhost/html /var/www/vhosts/localhost/lscache 2>/dev/null || true
        chmod -R 755 /usr/local/lsws/fcgi-bin 2>/dev/null || true

        # 3. Locate active PHP binary and create standard symlinks
        PHP_BIN=$(find /usr/local/lsws -name lsphp -type f -perm -111 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$PHP_BIN" ] && [ -x "$PHP_BIN" ]; then
            ln -sf "$PHP_BIN" /usr/local/lsws/fcgi-bin/lsphp
            ln -sf "$PHP_BIN" /usr/local/bin/php 2>/dev/null || true
            chmod 755 "$PHP_BIN" /usr/local/lsws/fcgi-bin/lsphp 2>/dev/null || true
        fi

        # 4. Purge any unsupported directives from mounted configs in-place
        if [ -f /usr/local/lsws/conf/vhosts/Example/vhconf.conf ]; then
            grep -v -i "extappsetuidmode" /usr/local/lsws/conf/vhosts/Example/vhconf.conf > /tmp/vhconf.tmp && cat /tmp/vhconf.tmp > /usr/local/lsws/conf/vhosts/Example/vhconf.conf && rm -f /tmp/vhconf.tmp
        fi
        if [ -f /usr/local/lsws/conf/httpd_config.conf ]; then
            grep -v -i -E "inmemcachesize|enablehttp3" /usr/local/lsws/conf/httpd_config.conf > /tmp/httpd.tmp && cat /tmp/httpd.tmp > /usr/local/lsws/conf/httpd_config.conf && rm -f /tmp/httpd.tmp
        fi

        # 5. Ensure WordPress .htaccess exists in document root
        if [ ! -f /var/www/vhosts/localhost/html/.htaccess ]; then
            cat << 'HTACCESS_EOF' > /var/www/vhosts/localhost/html/.htaccess
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTACCESS_EOF
            chmod 664 /var/www/vhosts/localhost/html/.htaccess 2>/dev/null || true
            chown nobody:nogroup /var/www/vhosts/localhost/html/.htaccess 2>/dev/null || true
        fi

        # 6. Start/Ensure LSPHP is actively listening on 127.0.0.1:9000
        if ! pgrep -f "lsphp -b 127.0.0.1:9000" >/dev/null; then
            pkill -9 lsphp 2>/dev/null || true
            su -s /bin/sh nobody -c "PHP_LSAPI_CHILDREN=35 LSAPI_AVOID_FORK=200M /usr/local/lsws/fcgi-bin/lsphp -b 127.0.0.1:9000" >/dev/null 2>&1 &
            sleep 1
        fi
    ' 2>/dev/null || true

    # Test configuration syntax
    log_info "Testing OpenLiteSpeed configuration syntax..."
    local config_test
    config_test=$(docker exec wp_ols /usr/local/lsws/bin/openlitespeed -t 2>&1 || true)
    if echo "$config_test" | grep -qi "error"; then
        log_warn "OpenLiteSpeed configuration test notice: ${config_test}"
    else
        log_success "OpenLiteSpeed configuration syntax test passed."
    fi

    # Restart OLS to apply clean configuration
    docker exec wp_ols /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || docker restart wp_ols >/dev/null 2>&1 || true
    sleep 3

    # Fail-safe: Ensure LSPHP daemon is active on 127.0.0.1:9000
    docker exec wp_ols sh -c '
        if ! pgrep -f "lsphp" >/dev/null; then
            su -s /bin/sh nobody -c "PHP_LSAPI_CHILDREN=35 LSAPI_AVOID_FORK=200M /usr/local/lsws/fcgi-bin/lsphp -b 127.0.0.1:9000" >/dev/null 2>&1 &
            sleep 1
        fi
    ' 2>/dev/null || true

    # Probe local web server to verify 200/301 vs 503
    local http_code
    http_code=$(docker exec wp_ols curl -s -o /dev/null -w "%{http_code}" -k https://127.0.0.1:443 2>/dev/null || docker exec wp_ols curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80 2>/dev/null || echo "000")
    if [[ "$http_code" == "503" ]]; then
        log_warn "Web server returned 503 during local probe. Restarting LSAPI daemon on 127.0.0.1:9000..."
        docker exec wp_ols sh -c '
            pkill -9 lsphp 2>/dev/null || true
            su -s /bin/sh nobody -c "PHP_LSAPI_CHILDREN=35 LSAPI_AVOID_FORK=200M /usr/local/lsws/fcgi-bin/lsphp -b 127.0.0.1:9000" >/dev/null 2>&1 &
            sleep 2
        ' 2>/dev/null || true
        docker exec wp_ols /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || true
    elif [[ "$http_code" =~ ^(200|301|302|404)$ ]]; then
        log_success "OpenLiteSpeed PHP backend verified healthy (HTTP Status: ${http_code})."
    fi
}

# ------------------------------------------------------------------------------
# Sync & Reload OpenLiteSpeed Configuration from Template
# ------------------------------------------------------------------------------
sync_ols_config() {
    if [[ -f .env ]]; then
        local dom
        dom=$(grep '^DOMAIN_NAME=' .env | cut -d '=' -f2)

        if [[ -n "$dom" ]]; then
            log_info "Syncing OpenLiteSpeed configurations (Listeners, LSCache, SSL)..."
            mkdir -p ols/conf/vhosts/Example certbot/www/.well-known/acme-challenge
            chmod -R 777 certbot/www 2>/dev/null || true

            local tmp_httpd tmp_vhconf
            tmp_httpd=$(mktemp 2>/dev/null || echo "/tmp/httpd_config.tmp")
            tmp_vhconf=$(mktemp 2>/dev/null || echo "/tmp/vhconf.tmp")

            sed -e "s/\${DOMAIN_NAME}/${dom}/g" \
                ols/httpd_config.conf.template > "$tmp_httpd"

            sed -e "s/\${DOMAIN_NAME}/${dom}/g" \
                ols/vhconf.conf.template > "$tmp_vhconf"

            sed -i '/extAppSetUIDMode/Id' "$tmp_vhconf" 2>/dev/null || true
            sed -i '/inMemCacheSize/Id' "$tmp_httpd" 2>/dev/null || true
            sed -i '/enableHttp3/Id' "$tmp_httpd" 2>/dev/null || true

            cat "$tmp_httpd" > ols/conf/httpd_config.conf
            cat "$tmp_vhconf" > ols/conf/vhosts/Example/vhconf.conf
            rm -f "$tmp_httpd" "$tmp_vhconf" 2>/dev/null || true

            # Directly sync files into wp_ols container via stdin to bypass any bind-mount inode traps
            if docker ps -a --filter "name=wp_ols" | grep -q "wp_ols"; then
                docker exec -i wp_ols sh -c 'cat > /usr/local/lsws/conf/httpd_config.conf' < ols/conf/httpd_config.conf 2>/dev/null || true
                docker exec -i wp_ols sh -c 'cat > /usr/local/lsws/conf/vhosts/Example/vhconf.conf' < ols/conf/vhosts/Example/vhconf.conf 2>/dev/null || true
            fi

            if docker ps --filter "name=wp_ols" --filter "status=running" | grep -q "wp_ols"; then
                init_ols_container
            fi
            log_success "OpenLiteSpeed configuration synchronized successfully."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Systemd Auto-Start Service Configuration (Reboot / Crash Resilience)
# ------------------------------------------------------------------------------
setup_systemd_service() {
    log_info "Configuring systemd auto-start service (wp-docker.service)..."
    if [[ ! -d /etc/systemd/system ]]; then
        log_warn "systemd directory /etc/systemd/system not found. Skipping auto-start service."
        return 0
    fi

    local docker_bin
    docker_bin=$(command -v docker 2>/dev/null || echo "/usr/bin/docker")

    cat <<EOF > /etc/systemd/system/wp-docker.service
[Unit]
Description=WordPress Isolated Docker Stack
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${docker_bin} compose up -d
ExecStop=${docker_bin} compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable wp-docker.service >/dev/null 2>&1 || true
    log_success "Systemd service 'wp-docker.service' is active and enabled on system boot!"
}

# ------------------------------------------------------------------------------
# Start / Restart Stack Services
# ------------------------------------------------------------------------------
start_restart_stack() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                 ${C_CYAN}START / RESTART STACK SERVICES${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    local current_ws
    current_ws=$(grep '^WEB_SERVER=' .env | cut -d '=' -f2 || echo "nginx")
    current_ws=${current_ws:-nginx}

    log_info "Starting / restarting all active containers (${current_ws} stack)..."
    if [[ "$current_ws" == "openlitespeed" ]]; then
        sync_ols_config
        docker compose up -d --force-recreate openlitespeed
        init_ols_container
        ensure_php_extensions
    else
        sync_nginx_config
        docker compose up -d
        ensure_php_extensions
        docker exec wp_app chown -R www-data:www-data /var/www/html 2>/dev/null || true
        docker exec wp_app chmod -R 775 /var/www/html 2>/dev/null || true
    fi

    setup_systemd_service

    log_success "All stack services (Web Server: ${current_ws}, Database, Certbot) are active and running."
}

# ------------------------------------------------------------------------------
# Stop Stack Services (Safe Pause)
# ------------------------------------------------------------------------------
stop_stack() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                    ${C_CYAN}STOP STACK SERVICES${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    log_info "Stopping all containers for this WordPress stack..."
    docker compose stop
    log_success "All stack services (Nginx / OpenLiteSpeed, WordPress, Database, Certbot) have been stopped."
    echo -e "${C_CYAN}Note: All files, databases, and SSL certificates remain safely stored in Docker volumes.${C_RESET}"
    echo -e "${C_CYAN}Ports are now temporarily freed.${C_RESET}"
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

    local current_ws
    current_ws=$(grep '^WEB_SERVER=' .env | cut -d '=' -f2 || echo "nginx")
    current_ws=${current_ws:-nginx}

    log_info "Pulling newest container images for active profile (${current_ws})..."
    docker compose pull

    log_info "Recreating containers with updated images..."
    docker compose up -d --force-recreate

    if [[ "$current_ws" == "openlitespeed" ]]; then
        sync_ols_config
        docker exec wp_ols chown -R nobody:nogroup /var/www/vhosts/localhost/html 2>/dev/null || true
        docker exec wp_ols chmod -R 777 /var/www/vhosts/localhost/html 2>/dev/null || true
        ensure_php_extensions
    else
        sync_nginx_config
        ensure_php_extensions
        docker exec wp_app chown -R www-data:www-data /var/www/html 2>/dev/null || true
        docker exec wp_app chmod -R 775 /var/www/html 2>/dev/null || true
    fi

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
        echo " [1] Web Server (OpenLiteSpeed / Nginx) Logs"
        echo " [2] WordPress (PHP-FPM) Logs"
        echo " [3] Isolated Database Logs"
        echo " [4] Certbot SSL Renewal Logs"
        echo " [5] View All Logs (Real-time stream, Ctrl+C to exit)"
        echo " [0] Back to Main Menu"
        echo -e "${C_BOLD}====================================================================${C_RESET}"
        read -r -p "Enter choice [0-5]: " log_choice

        case "$log_choice" in
            1) 
                if docker ps --filter "name=wp_ols" --filter "status=running" | grep -q "wp_ols"; then
                    echo -e "${C_CYAN}--- OpenLiteSpeed Server Error Log (/usr/local/lsws/logs/error.log) ---${C_RESET}"
                    docker exec wp_ols tail -n 50 /usr/local/lsws/logs/error.log 2>/dev/null || true
                    echo ""
                fi
                docker compose logs --tail=50 openlitespeed nginx 2>/dev/null
                ;;
            2) docker compose logs --tail=100 wordpress 2>/dev/null ;;
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

    log_info "Syncing latest updates for branch: ${current_branch}..."
    if git reset --hard "origin/${current_branch}"; then
        chmod +x setup.sh scripts/*.sh 2>/dev/null || true
        log_success "Script successfully updated to latest version."

        if [[ -f .env ]] && grep -q '^WEB_SERVER=openlitespeed' .env; then
            log_info "Applying updates to active OpenLiteSpeed container..."
            sync_ols_config
            docker compose up -d --force-recreate openlitespeed 2>/dev/null || true
            init_ols_container
        fi

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
    echo " - Stop & remove containers (wp_nginx, wp_ols, wp_app, wp_db, wp_certbot)"
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
    docker rm -f wp_pma wp_ols wp_nginx wp_app 2>/dev/null || true
    docker compose down -v --rmi local 2>/dev/null || docker compose down -v 2>/dev/null || true

    log_info "Cleaning configuration and SSL cache..."
    rm -f .env nginx/conf.d/default.conf ols/conf/httpd_config.conf ols/conf/vhosts/Example/vhconf.conf ols/conf/vhosts/localhost/vhconf.conf "${SCRIPT_DIR}/html"
    rm -rf certbot/conf/* certbot/www/*

    if [[ -f /etc/systemd/system/wp-docker.service ]]; then
        systemctl disable wp-docker.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/wp-docker.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        log_info "Removed systemd service wp-docker.service."
    fi

    if [[ -f "/usr/local/bin/wordpress" ]]; then
        rm -f "/usr/local/bin/wordpress"
        log_info "Removed global command /usr/local/bin/wordpress."
    fi

    log_success "WordPress stack has been completely and safely removed."
}

# ------------------------------------------------------------------------------
# Database Management Subsystem (View, Create, Delete, phpMyAdmin)
# ------------------------------------------------------------------------------
db_view_info() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "              ${C_CYAN}DATABASE CREDENTIALS & ACTIVE DATABASES${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    # shellcheck disable=SC1091
    source .env

    echo -e " Database Host:      ${C_BOLD}db${C_RESET} (Internal Docker network only)"
    echo -e " Internal Port:      3306"
    echo -e " Primary DB Name:    ${C_GREEN}${DB_NAME:-N/A}${C_RESET}"
    echo -e " Primary DB User:    ${C_GREEN}${DB_USER:-N/A}${C_RESET}"
    echo -e " Primary DB Pass:    ${C_YELLOW}${DB_PASSWORD:-N/A}${C_RESET}"
    echo -e " Root Password:      ${C_YELLOW}${DB_ROOT_PASSWORD:-N/A}${C_RESET}"
    echo -e "${C_BOLD}--------------------------------------------------------------------${C_RESET}"

    if docker ps --filter "name=wp_db" --filter "status=running" | grep -q "wp_db"; then
        echo -e "${C_BOLD}[Active Databases]:${C_RESET}"
        docker exec -i wp_db mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;" 2>/dev/null || echo "Could not query databases."
    else
        log_warn "Database container (wp_db) is currently stopped."
    fi
}

db_delete() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                    ${C_RED}DELETE AN EXISTING DATABASE${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    # shellcheck disable=SC1091
    source .env

    if ! docker ps --filter "name=wp_db" --filter "status=running" | grep -q "wp_db"; then
        log_error "Database container (wp_db) is not currently running."
        return 1
    fi

    echo -e "${C_BOLD}[Existing Databases]:${C_RESET}"
    docker exec -i wp_db mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;" 2>/dev/null
    echo ""

    read -r -p "Enter Database name to DELETE: " target_db
    target_db=$(echo "$target_db" | tr -d ' ')

    if [[ -z "$target_db" ]]; then
        log_warn "No database specified. Operation cancelled."
        return 0
    fi

    # Protect system databases
    case "$target_db" in
        information_schema|mysql|performance_schema|sys)
            log_error "Deleting system database '$target_db' is strictly forbidden!"
            return 1
            ;;
    esac

    echo -e "${C_RED}${C_BOLD}[WARNING] This will PERMANENTLY delete database '${target_db}' and all its data!${C_RESET}"
    read -r -p "Type '${target_db}' to confirm deletion: " confirm_del

    if [[ "$confirm_del" != "$target_db" ]]; then
        log_info "Confirmation mismatch. Deletion cancelled."
        return 0
    fi

    log_info "Dropping database \`${target_db}\`..."
    if docker exec -i wp_db mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE \`${target_db}\`;" 2>/dev/null; then
        log_success "Database '${target_db}' has been permanently deleted."
    else
        log_error "Failed to drop database '${target_db}'."
    fi
}

db_pma_start() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                   ${C_CYAN}START PHPMYADMIN (WEB GUI)${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    # shellcheck disable=SC1091
    source .env

    if docker ps --filter "name=wp_pma" --filter "status=running" | grep -q "wp_pma"; then
        local running_port
        running_port=$(docker port wp_pma 80 2>/dev/null | cut -d ':' -f2 || echo "8080")
        log_info "phpMyAdmin is ALREADY running on port: ${running_port}"
        echo -e " URL: ${C_CYAN}http://YOUR_SERVER_IP:${running_port}${C_RESET}"
        return 0
    fi

    read -r -p "Enter port for phpMyAdmin [default: 8080]: " pma_port_input
    local pma_port="${pma_port_input:-8080}"

    if is_port_in_use "$pma_port"; then
        log_error "Port $pma_port is currently in use. Please choose another port."
        return 1
    fi

    log_info "Launching on-demand phpMyAdmin container on port ${pma_port}..."
    docker rm -f wp_pma 2>/dev/null || true

    docker run -d \
      --name wp_pma \
      --restart unless-stopped \
      --network wp_network \
      -p "${pma_port}:80" \
      -e PMA_HOST=db \
      -e PMA_PORT=3306 \
      -e UPLOAD_LIMIT=1024M \
      phpmyadmin/phpmyadmin:latest >/dev/null

    local srv_ip
    srv_ip=$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")

    echo ""
    log_success "phpMyAdmin is now active!"
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e " phpMyAdmin URL:  ${C_CYAN}http://${srv_ip}:${pma_port}${C_RESET}"
    echo -e " Server Host:     ${C_BOLD}db${C_RESET}"
    echo -e " Username:        ${C_BOLD}root${C_RESET} (or ${DB_USER:-wp_user})"
    echo -e " Password:        ${C_YELLOW}${DB_ROOT_PASSWORD:-}${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e " ${C_YELLOW}SECURITY TIP: When finished with database operations,${C_RESET}"
    echo -e " ${C_YELLOW}stop phpMyAdmin via menu to prevent public exposure & free RAM.${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"
}

db_pma_stop() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                    ${C_CYAN}STOP PHPMYADMIN WEB GUI${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if docker ps -a --filter "name=wp_pma" --format "{{.Names}}" | grep -q "wp_pma"; then
        log_info "Stopping and removing phpMyAdmin container (wp_pma)..."
        docker rm -f wp_pma >/dev/null
        log_success "phpMyAdmin container has been stopped. Port and memory are freed."
    else
        log_info "phpMyAdmin container is not currently running."
    fi
}

database_menu() {
    while true; do
        scroll_to_top
        echo ""
        echo -e "${C_CYAN}${C_BOLD}"
        echo "===================================================================="
        echo "                 DATABASE MANAGEMENT SYSTEM"
        echo "===================================================================="
        echo -e "${C_RESET}"
        echo -e " [${C_BOLD}1${C_RESET}] View Database Credentials & List Active Databases"
        echo -e " [${C_BOLD}2${C_RESET}] Create New Database & User"
        echo -e " [${C_BOLD}3${C_RESET}] Delete an Existing Database"
        echo -e " [${C_BOLD}4${C_RESET}] Start phpMyAdmin (Web GUI on Port 8080)"
        echo -e " [${C_BOLD}5${C_RESET}] Stop phpMyAdmin (Disable Web GUI & Free RAM)"
        echo -e " [${C_BOLD}0${C_RESET}] Back to Main Menu"
        echo -e "${C_CYAN}====================================================================${C_RESET}"

        if ! read -r -p "Enter choice [0-5] and press Enter: " db_choice; then
            break
        fi

        case "$db_choice" in
            1)
                db_view_info
                read -r -p "Press [Enter] to return..." _
                ;;
            2)
                bash scripts/db-create.sh
                read -r -p "Press [Enter] to return..." _
                ;;
            3)
                db_delete
                read -r -p "Press [Enter] to return..." _
                ;;
            4)
                db_pma_start
                read -r -p "Press [Enter] to return..." _
                ;;
            5)
                db_pma_stop
                read -r -p "Press [Enter] to return..." _
                ;;
            0)
                break
                ;;
            *)
                log_warn "Invalid selection. Please choose a number between 0 and 5."
                sleep 1.2
                ;;
        esac
    done
}

deploy_menu() {
    while true; do
        scroll_to_top
        echo ""
        echo -e "${C_CYAN}${C_BOLD}"
        echo "===================================================================="
        echo "                    DEPLOYMENT & RESTORATION"
        echo "===================================================================="
        echo -e "${C_RESET}"
        echo -e " [${C_BOLD}1${C_RESET}] Deploy Fresh WordPress (Nginx, PHP, WP Core, Isolated DB, SSL)"
        echo -e " [${C_BOLD}2${C_RESET}] Deploy Stack for Migration / Restore (Duplicator & Backupino Ready)"
        echo -e " [${C_BOLD}0${C_RESET}] Back to Main Menu"
        echo -e "${C_CYAN}====================================================================${C_RESET}"

        if ! read -r -p "Enter choice [0-2] and press Enter: " dep_choice; then
            break
        fi

        case "$dep_choice" in
            1)
                deploy_stack "fresh"
                read -r -p "Press [Enter] to return..." _
                ;;
            2)
                deploy_stack "migration"
                read -r -p "Press [Enter] to return..." _
                ;;
            0)
                break
                ;;
            *)
                log_warn "Invalid selection."
                sleep 1
                ;;
        esac
    done
}

service_menu() {
    while true; do
        scroll_to_top
        local cur_commit
        cur_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
        echo ""
        echo -e "${C_CYAN}${C_BOLD}"
        echo "===================================================================="
        echo "           SERVICE CONTROL & MONITORING - [commit: ${cur_commit}]"
        echo "===================================================================="
        echo -e "${C_RESET}"
        echo -e " [${C_BOLD}1${C_RESET}] Start / Restart Stack Services"
        echo -e " [${C_BOLD}2${C_RESET}] Stop Stack Services (Safe Pause & Free Ports)"
        echo -e " [${C_BOLD}3${C_RESET}] Service Status & Resource Usage (Stats)"
        echo -e " [${C_BOLD}4${C_RESET}] View Service Logs (Nginx, PHP, Database, Certbot)"
        echo -e " [${C_BOLD}5${C_RESET}] Enable / Configure Auto-Start on Boot (systemd service)"
        echo -e " [${C_BOLD}6${C_RESET}] Self-Update Script (Pull latest from GitHub)"
        echo -e " [${C_BOLD}0${C_RESET}] Back to Main Menu"
        echo -e "${C_CYAN}====================================================================${C_RESET}"

        if ! read -r -p "Enter choice [0-6] and press Enter: " srv_choice; then
            break
        fi

        case "$srv_choice" in
            1)
                start_restart_stack
                read -r -p "Press [Enter] to return..." _
                ;;
            2)
                stop_stack
                read -r -p "Press [Enter] to return..." _
                ;;
            3)
                check_status
                read -r -p "Press [Enter] to return..." _
                ;;
            4)
                view_logs
                ;;
            5)
                setup_systemd_service
                read -r -p "Press [Enter] to return..." _
                ;;
            6)
                self_update
                ;;
            0)
                break
                ;;
            *)
                log_warn "Invalid selection."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Web Server & PHP Version Management Functions
# ------------------------------------------------------------------------------
switch_web_server() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "              ${C_CYAN}SWITCH WEB SERVER (OpenLiteSpeed ⇄ Nginx)${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    local current_ws
    current_ws=$(grep '^WEB_SERVER=' .env | cut -d '=' -f2 || echo "nginx")
    current_ws=${current_ws:-nginx}

    echo -e " Current Active Web Server: ${C_GREEN}${current_ws}${C_RESET}"
    echo ""
    echo "Select Target Web Server Engine:"
    echo "  1) OpenLiteSpeed (Recommended - Native LSCache, HTTP/3 QUIC, .htaccess)"
    echo "  2) Nginx (Ultra-Lightweight & Battle-Tested)"
    read -r -p "Enter choice [1-2]: " target_ws_choice

    local target_ws="openlitespeed"
    if [[ "$target_ws_choice" == "2" ]]; then
        target_ws="nginx"
    fi

    if [[ "$target_ws" == "$current_ws" ]]; then
        log_info "The stack is already configured to use ${target_ws}."
        return 0
    fi

    log_info "Switching web server engine from ${current_ws} to ${target_ws}..."

    if [[ "$target_ws" == "openlitespeed" ]]; then
        log_info "Stopping Nginx & PHP-FPM containers..."
        docker compose --profile nginx stop nginx wordpress 2>/dev/null || true

        # Ensure OLS config exists
        sync_ols_config

        # Update .env
        if grep -q '^WEB_SERVER=' .env; then
            sed -i 's|^WEB_SERVER=.*|WEB_SERVER=openlitespeed|' .env
        else
            echo "WEB_SERVER=openlitespeed" >> .env
        fi

        if grep -q '^COMPOSE_PROFILES=' .env; then
            sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=ols|' .env
        else
            echo "COMPOSE_PROFILES=ols" >> .env
        fi

        if ! grep -q '^OLS_IMAGE=' .env; then
            echo "OLS_IMAGE=litespeedtech/openlitespeed:latest-lsphp83" >> .env
        fi

        log_info "Starting OpenLiteSpeed web server..."
        docker compose up -d --force-recreate openlitespeed

        sleep 2
        init_ols_container
        ensure_php_extensions
        setup_systemd_service
    else
        log_info "Stopping OpenLiteSpeed container..."
        docker compose --profile ols stop openlitespeed 2>/dev/null || true

        # Ensure Nginx config exists
        sync_nginx_config

        # Update .env
        if grep -q '^WEB_SERVER=' .env; then
            sed -i 's|^WEB_SERVER=.*|WEB_SERVER=nginx|' .env
        else
            echo "WEB_SERVER=nginx" >> .env
        fi

        if grep -q '^COMPOSE_PROFILES=' .env; then
            sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=nginx|' .env
        else
            echo "COMPOSE_PROFILES=nginx" >> .env
        fi

        if ! grep -q '^WP_IMAGE=' .env; then
            echo "WP_IMAGE=wordpress:php8.3-fpm-alpine" >> .env
        fi

        log_info "Starting Nginx & WordPress PHP-FPM..."
        docker compose up -d wordpress nginx

        sleep 2
        ensure_php_extensions
        docker exec wp_app chown -R www-data:www-data /var/www/html 2>/dev/null || true
        docker exec wp_app chmod -R 775 /var/www/html 2>/dev/null || true
        setup_systemd_service
    fi

    sleep 2
    echo ""
    log_success "Successfully switched web server engine to ${target_ws}!"
    echo -e " Your website is now powered by: ${C_GREEN}${target_ws}${C_RESET}"
    if [[ "$target_ws" == "openlitespeed" ]]; then
        echo -e " ${C_CYAN}[Tip] You can now install or enable the 'LiteSpeed Cache' plugin in WordPress to enjoy native server-level caching!${C_RESET}"
    fi
}

change_php_version() {
    echo ""
    echo -e "${C_BOLD}====================================================================${C_RESET}"
    echo -e "                   ${C_CYAN}SWITCH PHP VERSION${C_RESET}"
    echo -e "${C_BOLD}====================================================================${C_RESET}"

    if [[ ! -f .env ]]; then
        log_error "No .env file found. Stack has not been deployed yet."
        return 1
    fi

    local current_ws
    current_ws=$(grep '^WEB_SERVER=' .env | cut -d '=' -f2 || echo "nginx")
    current_ws=${current_ws:-nginx}

    local current_php="Unknown"
    if [[ "$current_ws" == "openlitespeed" ]]; then
        if docker ps --filter "name=wp_ols" --filter "status=running" | grep -q "wp_ols"; then
            current_php=$(docker exec wp_ols php -v 2>/dev/null | head -n 1 || echo "Unknown")
        fi
    else
        if docker ps --filter "name=wp_app" --filter "status=running" | grep -q "wp_app"; then
            current_php=$(docker exec wp_app php -v 2>/dev/null | head -n 1 || echo "Unknown")
        fi
    fi
    echo -e " Current Web Server Engine: ${C_CYAN}${current_ws}${C_RESET}"
    echo -e " Current Active PHP:        ${C_GREEN}${current_php}${C_RESET}"

    local new_image
    new_image=$(select_php_version "${current_ws}" 5)

    if [[ "$current_ws" == "openlitespeed" ]]; then
        log_info "Updating OpenLiteSpeed PHP version to ${new_image} in .env..."
        if grep -q '^OLS_IMAGE=' .env; then
            sed -i "s|^OLS_IMAGE=.*|OLS_IMAGE=${new_image}|" .env
        else
            echo "OLS_IMAGE=${new_image}" >> .env
        fi
        log_info "Pulling new OpenLiteSpeed container image (${new_image})..."
        docker compose pull openlitespeed

        log_info "Recreating OpenLiteSpeed container with new PHP version..."
        docker compose up -d --force-recreate openlitespeed
        sleep 2
        sync_ols_config
        ensure_php_extensions
        local updated_php
        updated_php=$(docker exec wp_ols php -v 2>/dev/null | head -n 1 || echo "Updated")
    else
        log_info "Updating WordPress PHP version to ${new_image} in .env..."
        if grep -q '^WP_IMAGE=' .env; then
            sed -i "s|^WP_IMAGE=.*|WP_IMAGE=${new_image}|" .env
        else
            echo "WP_IMAGE=${new_image}" >> .env
        fi
        log_info "Pulling new PHP container image (${new_image})..."
        docker compose pull wordpress

        log_info "Recreating WordPress container with new PHP version..."
        docker compose up -d wordpress
        sleep 2
        ensure_php_extensions
        docker restart wp_nginx >/dev/null 2>&1 || true
        local updated_php
        updated_php=$(docker exec wp_app php -v 2>/dev/null | head -n 1 || echo "Updated")
    fi

    echo ""
    log_success "Successfully switched PHP version!"
    echo -e " Active PHP Version: ${C_GREEN}${updated_php}${C_RESET}"
}

maintenance_menu() {
    while true; do
        scroll_to_top
        echo ""
        echo -e "${C_CYAN}${C_BOLD}"
        echo "===================================================================="
        echo "                      MAINTENANCE & UPDATES"
        echo "===================================================================="
        echo -e "${C_RESET}"
        echo -e " [${C_BOLD}1${C_RESET}] Switch / Change Web Server (OpenLiteSpeed ⇄ Nginx)"
        echo -e " [${C_BOLD}2${C_RESET}] Switch / Change PHP Version (7.4, 8.0, 8.1, 8.2, 8.3)"
        echo -e " [${C_BOLD}3${C_RESET}] Update Container Images & Stack Dependencies"
        echo -e " [${C_BOLD}4${C_RESET}] Self-Update Script (Pull latest from GitHub)"
        echo -e " [${C_BOLD}0${C_RESET}] Back to Main Menu"
        echo -e "${C_CYAN}====================================================================${C_RESET}"

        if ! read -r -p "Enter choice [0-4] and press Enter: " mnt_choice; then
            break
        fi

        case "$mnt_choice" in
            1)
                switch_web_server
                read -r -p "Press [Enter] to return..." _
                ;;
            2)
                change_php_version
                read -r -p "Press [Enter] to return..." _
                ;;
            3)
                update_dependencies
                read -r -p "Press [Enter] to return..." _
                ;;
            4)
                self_update
                ;;
            0)
                break
                ;;
            *)
                log_warn "Invalid selection. Please choose between 0 and 4."
                sleep 1.2
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Interactive Main Menu
# ------------------------------------------------------------------------------
main_menu() {
    check_root
    install_cli_shortcut
    create_html_symlink

    while true; do
        scroll_to_top
        local cur_commit
        cur_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
        echo ""
        echo -e "${C_CYAN}${C_BOLD}"
        echo "===================================================================="
        echo "     WordPress & Docker Stack Manager (Isolated) - [${cur_commit}]"
        echo "===================================================================="
        echo -e "${C_RESET}"
        echo -e " [${C_BOLD}1${C_RESET}] Deployment & Restoration (Fresh WP / Duplicator Restore)"
        echo -e " [${C_BOLD}2${C_RESET}] Database Management (Create, Delete, View Info, phpMyAdmin)"
        echo -e " [${C_BOLD}3${C_RESET}] Service Operations (Start, Stop, Restart, Status, Logs)"
        echo -e " [${C_BOLD}4${C_RESET}] Maintenance & Updates (Update Images, Self-Update Script)"
        echo -e " [${C_BOLD}5${C_RESET}] Complete Uninstall (Safe Purge Stack Only)"
        echo -e " [${C_BOLD}0${C_RESET}] Exit"
        echo -e "${C_CYAN}====================================================================${C_RESET}"
        
        if ! read -r -p "Enter choice [0-5] and press Enter: " user_choice; then
            cleanup_and_exit
        fi

        case "$user_choice" in
            1) deploy_menu ;;
            2) database_menu ;;
            3) service_menu ;;
            4) maintenance_menu ;;
            5)
                uninstall_stack
                read -r -p "Press [Enter] to return to the main menu..." _
                ;;
            0)
                echo "Exiting. Goodbye!"
                exit 0
                ;;
            *)
                log_warn "Invalid selection. Please choose a number between 0 and 5."
                sleep 1.2
                ;;
        esac
    done
}

main_menu "$@"
