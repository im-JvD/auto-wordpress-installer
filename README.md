# Automated & Isolated WordPress Stack Deployer (Docker)

A production-ready, secure, and fully isolated Bash automation script for deploying and managing WordPress on Linux VPS environments using Docker, Nginx, PHP-FPM, and Certbot (Let's Encrypt SSL).

Designed with **strict isolation principles**:
- **Zero Port Conflict on Databases:** The database runs inside an isolated internal Docker bridge network. Port `3306` is **never exposed** to the host. Any existing database on your VPS is completely safe and unaffected.
- **Read-Only Conflict Detection:** Ports `80` and `443` are scanned before deployment. If another service occupies them, the script safely halts with an informative error rather than killing or altering host processes.
- **Safe & Scoped Management:** All update, log, and uninstall operations strictly target only the containers, volumes, and networks created by this stack. Other Docker containers and host services are untouched.
- **Duplicator & Backupino Ready:** Includes a dedicated deployment mode specifically tailored for restoring existing WordPress backups without needing to initialize raw WordPress first.

---

## Architecture Overview

```
                      [ Host Ports 80 & 443 ]
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │   Nginx Reverse Proxy │ (HTTP/2, SSL, Security Headers)
                     └───────────┬───────────┘
                                 │
                 ┌───────────────┴───────────────┐
                 │                               │
                 ▼                               ▼
       ┌───────────────────┐           ┌───────────────────┐
       │   Certbot (ACME)  │           │ WordPress PHP-FPM │
       │ (Auto-renew loop) │           │ (wordpress:fpm)   │
       └───────────────────┘           └─────────┬─────────┘
                                                 │
                                                 │ Internal Bridge Network
                                                 ▼ (Port 3306 - Not Bound to Host)
                                       ┌───────────────────┐
                                       │ MariaDB / MySQL   │
                                       │ (wp_db container) │
                                       └───────────────────┘
```

---

## Quick Start (One-Liner Installation)

Run the following command on your Linux server (Ubuntu/Debian/CentOS/Rocky) to clone and launch the interactive manager:

```bash
git clone https://github.com/<YOUR_USERNAME>/<YOUR_REPO>.git /opt/wp-docker && cd /opt/wp-docker && chmod +x setup.sh scripts/*.sh && sudo ./setup.sh
```

---

## Interactive Menu Options

When you run `sudo ./setup.sh`, an English numbered menu is presented:

```text
====================================================================
           WordPress & Docker Stack Manager (Isolated)
====================================================================
 [1] Deploy Fresh WordPress (Nginx, PHP, WP Core, Isolated DB & SSL)
 [2] Deploy Stack for Migration / Restore (Duplicator & Backupino Ready)
 [3] Create New Database & User (Inside Existing DB Container)
 [4] Update Dependencies & Container Images
 [5] Service Status & Health Check
 [6] View Service Logs (Nginx, PHP, Database, Certbot)
 [7] Self-Update Script (Pull latest from GitHub)
 [8] Complete Uninstall (Safe Purge of this Stack Only)
 [0] Exit
====================================================================
```

### [1] Deploy Fresh WordPress
* Performs read-only port checks (80/443).
* Verifies Docker and Compose plugin (auto-installs from official repo if missing).
* Prompts for Database Engine choice (MariaDB 10.11 LTS or MySQL 8.0).
* Prompts for Domain Name, Admin Email, DB Name, User, and Password.
* Runs DNS pre-flight verification to confirm your domain points to the server IP.
* Executes two-stage SSL acquisition with Certbot.
* Launches WordPress and outputs website access URL (`https://yourdomain.com`).

### [2] Deploy Stack for Migration / Restore (Duplicator & Backupino)
* Configures Nginx, PHP-FPM, SSL, and an empty database ready for site restoration.
* Pre-configures PHP upload limits (`upload_max_filesize = 1024M`, `post_max_size = 1024M`, `memory_limit = 512M`, `max_execution_time = 600`) to prevent timeout on large archives.
* Outputs the exact database credentials and instructions to copy `installer.php` and your archive into the container.

### [3] Create New Database & User
* Connects directly to the running database container.
* Allows creating additional databases and dedicated users with isolated privileges without touching existing tables.

### [4] Update Dependencies & Container Images
* Safely pulls updated Docker images for Nginx, WordPress, and the Database.
* Recreates containers using `docker compose up -d` without data loss.

### [5] Service Status & Health Check
* Shows container uptime, healthcheck states, port mappings, and memory/CPU usage.
* Tests the live HTTP/HTTPS status code.

### [6] View Service Logs
* Inspect real-time logs for individual services (Nginx, WordPress, Database, Certbot) or stream all combined logs.

### [7] Self-Update Script
* Fetches and pulls the latest commits from the GitHub repository (`git fetch && git pull`).
* Updates execution permissions and automatically reloads the script.

### [8] Complete Uninstall
* Safe, scoped uninstaller requiring explicit `yes` confirmation.
* Removes **only** the `wp_nginx`, `wp_app`, `wp_db`, and `wp_certbot` containers, volumes (`wp_data`, `wp_db_data`), and network (`wp_network`).
* Leaves all other host databases, Docker containers, and packages completely intact.

---

## Restoring with Duplicator or Backupino

1. Choose option `[2]` from the menu.
2. Note down the Database credentials output on screen:
   * **Database Host:** `db`
   * **Database Name:** *(your chosen name)*
   * **Database User:** *(your chosen user)*
   * **Database Password:** *(your chosen password)*
3. Copy your `installer.php` and backup archive to the container web root:
   ```bash
   docker cp installer.php wp_app:/var/www/html/
   docker cp your_archive.zip wp_app:/var/www/html/
   docker exec -it wp_app chown -R www-data:www-data /var/www/html
   ```
4. In your browser, open:
   ```
   https://yourdomain.com/installer.php
   ```
5. Follow the Duplicator / Backupino installer steps using `db` as the host.

---

## Directory Structure

```text
/opt/wp-docker/
├── setup.sh                 # Master interactive management script
├── docker-compose.yml       # Production Docker Compose orchestration
├── .env.example             # Configuration variables blueprint
├── php/
│   └── custom.ini           # Optimized PHP settings for WordPress & Duplicator
├── nginx/
│   ├── nginx.conf           # Base Nginx security & performance configuration
│   └── conf.d/
│       ├── http.conf.template # Temporary configuration for ACME HTTP-01 challenge
│       └── ssl.conf.template  # Production HTTPS configuration with HTTP/2
├── scripts/
│   ├── ssl-init.sh          # Two-stage Let's Encrypt SSL certificate bootstrap
│   └── db-create.sh         # Helper to create isolated databases and users
└── certbot/                 # Persistent storage for Let's Encrypt certificates
```

---

## Security Highlights

* **No DB Exposure:** Port `3306` is kept inside Docker's internal network.
* **Modern SSL & HTTP/2:** TLSv1.2 and TLSv1.3 with secure cipher suites and HSTS enabled.
* **Auto-Renewing SSL:** Dedicated Certbot container continuously monitors and renews certificates before expiration.
* **File Upload Hardening:** Denies direct execution of PHP scripts in `/wp-content/uploads/`.
* **Hidden Files Protected:** Blocks access to `.env`, `.git`, `.htaccess`, and other dotfiles.
* **Non-Destructive Operations:** Never runs global `docker prune` or modifies existing host firewall rules.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
