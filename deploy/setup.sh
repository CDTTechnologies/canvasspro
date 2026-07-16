#!/usr/bin/env bash
# =============================================================================
# CanvassPro — Ubuntu Server Deployment Script
# =============================================================================
# This script automates the full setup of a Next.js 16 application on a
# fresh Ubuntu 22.04/24.04 LTS server.
#
# What it installs & configures:
#   1. System updates & baseline packages
#   2. PostgreSQL with a dedicated database & user
#   3. Nginx (reverse proxy + static file serving + optional SSL)
#   4. Bun runtime (fast Node/JS alternative used by the project)
#   5. The Next.js application (build + production systemd service)
#   6. Upload directory with correct permissions
#   7. UFW firewall rules (SSH, HTTP, HTTPS)
#
# USAGE:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# OPTIONS (environment variables):
#   APP_DOMAIN        — Your domain name (enables Let's Encrypt SSL). Default: ""
#   APP_PORT          — Port the Next.js app listens on. Default: 3000
#   DB_NAME           — PostgreSQL database name. Default: "canvasspro"
#   DB_USER           — PostgreSQL user. Default: "canvasspro"
#   DB_PASSWORD       — PostgreSQL password. Default: auto-generated 32-char
#   DB_HOST           — PostgreSQL host. Default: "localhost"
#   DB_PORT           — PostgreSQL port. Default: 5432
#   APP_DIR           — Where to deploy the app. Default: "/opt/canvasspro"
#   DEPLOY_USER       — System user that runs the app. Default: "canvasspro"
#   SKIP_SSL          — Set to "true" to skip Certbot setup. Default: ""
#   SSH_PORT          — Custom SSH port for firewall. Default: 22
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Configuration (overridable via environment variables)
# ---------------------------------------------------------------------------
APP_DOMAIN="${APP_DOMAIN:-}"
APP_PORT="${APP_PORT:-3000}"
DB_NAME="${DB_NAME:-canvasspro}"
DB_USER="${DB_USER:-canvasspro}"
# Generate a strong random password if none provided
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
APP_DIR="${APP_DIR:-/opt/canvasspro}"
DEPLOY_USER="${DEPLOY_USER:-canvasspro}"
SKIP_SSL="${SKIP_SSL:-}"
SSH_PORT="${SSH_PORT:-22}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "Running pre-flight checks..."

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root (use sudo)."
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  error "Cannot determine OS. This script targets Ubuntu 22.04/24.04 LTS."
  exit 1
fi

UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
if [[ "$UBUNTU_CODENAME" != "jammy" && "$UBUNTU_CODENAME" != "focal" && "$UBUNTU_CODENAME" != "noble" ]]; then
  warn "Detected Ubuntu codename '$UBUNTU_CODENAME'. Tested on jammy (22.04) and noble (24.04)."
fi

info "Ubuntu $UBUNTU_CODENAME detected. Continuing..."

# ===========================================================================
# 1. SYSTEM UPDATES & BASELINE PACKAGES
# ===========================================================================
info "===== STEP 1: System Updates & Baseline Packages ====="

apt-get update -y
apt-get upgrade -y

# Core utilities
apt-get install -y \
  curl \
  wget \
  git \
  unzip \
  build-essential \
  ca-certificates \
  gnupg \
  lsb-release \
  software-properties-common \
  apt-transport-https \
  logrotate

success "System packages updated and baseline tools installed."

# ===========================================================================
# 2. POSTGRESQL
# ===========================================================================
info "===== STEP 2: PostgreSQL Setup ====="

# --- Determine whether to install PostgreSQL or use an existing one ----------
PG_ALREADY_INSTALLED=false
if command -v psql &>/dev/null; then
  PG_VERSION="$(psql --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)"
  warn "PostgreSQL is already installed (version ~$PG_VERSION). Skipping installation."
  PG_ALREADY_INSTALLED=true
fi

if [[ "$PG_ALREADY_INSTALLED" == false ]]; then
  # Add the official PostgreSQL APT repository for the latest stable version
  sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - 2>/dev/null \
    || wget --quiet -O /etc/apt/trusted.gpg.d/pgdg.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc

  apt-get update -y
  apt-get install -y postgresql postgresql-contrib
  success "PostgreSQL installed."
fi

# Ensure the service is running
systemctl enable postgresql
systemctl start postgresql

# --- Create database and user ------------------------------------------------
# Check if the user already exists
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  warn "Database user '$DB_USER' already exists. Skipping creation."
else
  sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
  success "PostgreSQL user '$DB_USER' created."
fi

# Check if the database already exists
if sudo -u postgres psql -lqt | cut -d\| -f1 | grep -qw "$DB_NAME"; then
  warn "Database '$DB_NAME' already exists. Skipping creation."
else
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
  success "PostgreSQL database '$DB_NAME' created."
fi

# Grant privileges (idempotent)
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

# Verify connection
if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" &>/dev/null; then
  success "PostgreSQL connection verified (user=$DB_USER, db=$DB_NAME, host=$DB_HOST:$DB_PORT)."
else
  # Connection failed — fix pg_hba.conf.
  # When connecting with -h localhost, PostgreSQL uses TCP (host lines),
  # NOT Unix sockets (local lines). Modern PG defaults to scram-sha-256
  # which requires libpq >= 10. We switch the host lines to md5.
  PG_HBA="$(sudo -u postgres psql -tAc "SHOW hba_file;" 2>/dev/null | tr -d ' ')"
  if [[ -n "$PG_HBA" && -f "$PG_HBA" ]]; then
    warn "Adjusting pg_hba.conf for password authentication..."

    # Backup original
    cp "$PG_HBA" "${PG_HBA}.bak.$(date +%s)"

    # 1. Change IPv4 host line (127.0.0.1/32) — this is the critical one
    sed -i 's/^host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+scram-sha-256/host    all             all             127.0.0.1\/32            md5/' "$PG_HBA"
    sed -i 's/^host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+peer/host    all             all             127.0.0.1\/32            md5/' "$PG_HBA"

    # 2. Change IPv6 host line (::1/128)
    sed -i 's/^host\s\+all\s\+all\s\+::1\/128\s\+scram-sha-256/host    all             all             ::1\/128                 md5/' "$PG_HBA"
    sed -i 's/^host\s\+all\s\+all\s\+::1\/128\s\+peer/host    all             all             ::1\/128                 md5/' "$PG_HBA"

    # 3. Also fix local lines (Unix socket) for good measure
    sed -i 's/^local\s\+all\s\+all\s\+peer/local   all             all                                     md5/' "$PG_HBA"
    sed -i 's/^local\s\+all\s\+all\s\+scram-sha-256/local   all             all                                     md5/' "$PG_HBA"

    # 4. Remove any duplicate/empty host entries that sed may leave behind
    #    (happens when multiple sed patterns match the same line)
    awk '!seen[$0]++' "$PG_HBA" > "${PG_HBA}.tmp" && mv "${PG_HBA}.tmp" "$PG_HBA"

    systemctl restart postgresql
    sleep 3
  fi

  # Retry the connection
  if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" &>/dev/null; then
    success "PostgreSQL connection verified after pg_hba.conf adjustment."
  else
    # Last resort: add a specific host entry for this user
    warn "Standard pg_hba.conf fix didn't work. Adding explicit entry..."
    echo "host    $DB_NAME    $DB_USER    127.0.0.1/32    md5" >> "$PG_HBA"
    echo "host    $DB_NAME    $DB_USER    ::1/128         md5" >> "$PG_HBA"
    systemctl restart postgresql
    sleep 3

    if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" &>/dev/null; then
      success "PostgreSQL connection verified with explicit pg_hba.conf entry."
    else
      echo ""
      error "============================================"
      error "Could not connect to PostgreSQL after multiple attempts."
      error "============================================"
      error "pg_hba.conf location: $PG_HBA"
      error ""
      error "Debug steps:"
      error "  1. Check the file:  cat $PG_HBA"
      error "  2. Check PG logs:  sudo journalctl -u postgresql -n 20"
      error "  3. Test manually:  PGPASSWORD='...' psql -h $DB_HOST -U $DB_USER -d $DB_NAME"
      error "  4. Common fix:     Change 'scram-sha-256' to 'md5' for the 127.0.0.1 host line"
      error ""
      exit 1
    fi
  fi
fi

# Save DB credentials for reference
echo "DB_PASSWORD=$DB_PASSWORD" >> "$SCRIPT_DIR/.deploy-env"

success "PostgreSQL setup complete."

# ===========================================================================
# 3. BUN RUNTIME
# ===========================================================================
info "===== STEP 3: Bun Runtime ====="

# Resolve the full bun path early (used everywhere below)
BUN_BIN=""
for _candidate in /usr/local/bin/bun /root/.bun/bin/bun /home/*/.bun/bin/bun; do
  if [[ -x "$_candidate" ]]; then
    BUN_BIN="$_candidate"
    break
  fi
done

if [[ -n "$BUN_BIN" ]]; then
  # Ensure symlink exists even if bun was installed before this fix
  [[ -x /usr/local/bin/bun ]] || ln -sf "$BUN_BIN" /usr/local/bin/bun 2>/dev/null || true
  BUN_VER="$($BUN_BIN --version)"
  warn "Bun is already installed (version $BUN_VER) at $BUN_BIN. Skipping installation."
else
  curl -fsSL https://bun.sh/install | bash

  # Determine the exact install path
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"

  # Create a system-wide profile script using the ABSOLUTE path (not $HOME,
  # because $HOME differs per user and non-interactive shells don't source it)
  BUN_BIN="$HOME/.bun/bin/bun"
  cat > /etc/profile.d/bun.sh << 'BUNPROFILE'
export PATH="/root/.bun/bin:$PATH"
BUNPROFILE
  chmod +x /etc/profile.d/bun.sh

  # Also create a symlink in /usr/local/bin so ALL users (including systemd
  # and sudo -u shells) can find 'bun' without any PATH tweaks
  ln -sf "$BUN_BIN" /usr/local/bin/bun

  # Re-source for current shell
  # shellcheck disable=SC1091
  source /etc/profile.d/bun.sh 2>/dev/null || true
  hash -r

  BUN_BIN="/usr/local/bin/bun"
  success "Bun installed: $($BUN_BIN --version)"
fi

# ===========================================================================
# 4. DEPLOY USER & APP DIRECTORY
# ===========================================================================
info "===== STEP 4: Deploy User & App Directory ====="

# Create a dedicated non-root user for the application
if id "$DEPLOY_USER" &>/dev/null; then
  warn "User '$DEPLOY_USER' already exists. Skipping creation."
else
  useradd -m -s /bin/bash "$DEPLOY_USER"
  success "System user '$DEPLOY_USER' created."
fi

# Create application directory
mkdir -p "$APP_DIR"
mkdir -p "$APP_DIR/upload"

# Copy project files to the app directory
PROJECT_SOURCE="$SCRIPT_DIR/.."
if [[ -f "$PROJECT_SOURCE/package.json" ]]; then
  info "Copying project files from $PROJECT_SOURCE to $APP_DIR ..."
  # Use rsync if available, otherwise cp
  if command -v rsync &>/dev/null; then
    rsync -a --exclude='node_modules' \
             --exclude='.next' \
             --exclude='db/*.db' \
             --exclude='*.log' \
             --exclude='.git' \
             --exclude='tool-results' \
             --exclude='download' \
             "$PROJECT_SOURCE/" "$APP_DIR/"
  else
    # Fallback: copy essential files and directories
    for item in src prisma public upload package.json bun.lock next.config.ts \
                tsconfig.json postcss.config.mjs tailwind.config.ts \
                eslint.config.mjs components.json; do
      if [[ -e "$PROJECT_SOURCE/$item" ]]; then
        cp -r "$PROJECT_SOURCE/$item" "$APP_DIR/"
      fi
    done
  fi
  success "Project files copied to $APP_DIR."
else
  warn "No package.json found in $PROJECT_SOURCE."
  warn "If deploying via Git, clone your repo into $APP_DIR manually, then re-run this script."
fi

# Set ownership
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"
chmod -R 755 "$APP_DIR"

success "Application directory ready at $APP_DIR."

# ===========================================================================
# 5. PRISMA SCHEMA MIGRATION (SQLite → PostgreSQL)
# ===========================================================================
info "===== STEP 5: Prisma Schema & Environment Configuration ====="

# Update Prisma schema to use PostgreSQL if it currently says sqlite
SCHEMA_FILE="$APP_DIR/prisma/schema.prisma"
if [[ -f "$SCHEMA_FILE" ]]; then
  if grep -q 'provider = "sqlite"' "$SCHEMA_FILE"; then
    info "Migrating Prisma schema from SQLite to PostgreSQL..."
    sed -i 's/provider = "sqlite"/provider = "postgresql"/' "$SCHEMA_FILE"
    success "Prisma schema updated to PostgreSQL."
  else
    info "Prisma schema already configured for PostgreSQL."
  fi
fi

# Write the production .env file
cat > "$APP_DIR/.env" << ENVFILE
# =============================================================================
# Production Environment Variables
# =============================================================================

# Database (PostgreSQL)
DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?schema=public"

# Next.js
NODE_ENV="production"
NEXT_PUBLIC_APP_URL="${APP_DOMAIN:+https://$APP_DOMAIN}"

# NextAuth (uncomment and configure when ready)
# NEXTAUTH_URL="${APP_DOMAIN:+https://$APP_DOMAIN}"
# NEXTAUTH_SECRET="$(openssl rand -base64 32)"

# Application
APP_PORT=${APP_PORT}
UPLOAD_DIR="${APP_DIR}/upload"
ENVFILE

chown "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

success "Environment file written to $APP_DIR/.env"

# ===========================================================================
# 6. INSTALL DEPENDENCIES & BUILD
# ===========================================================================
info "===== STEP 6: Install Dependencies & Build ====="

cd "$APP_DIR"

# Install dependencies as the deploy user
info "Running 'bun install' (this may take a minute)..."
sudo -u "$DEPLOY_USER" bash -lc "cd $APP_DIR && $BUN_BIN install --production=false"
success "Dependencies installed."

# Generate Prisma client
info "Generating Prisma client..."
sudo -u "$DEPLOY_USER" bash -lc "cd $APP_DIR && $BUN_BIN x prisma generate"
success "Prisma client generated."

# Push schema to PostgreSQL (creates tables)
info "Pushing Prisma schema to PostgreSQL..."
sudo -u "$DEPLOY_USER" bash -lc "cd $APP_DIR && $BUN_BIN x prisma db push --skip-generate"
success "Database schema pushed."

# Build the Next.js application
info "Building Next.js application (standalone output)..."
sudo -u "$DEPLOY_USER" bash -lc "cd $APP_DIR && $BUN_BIN run build"
success "Next.js build complete."

# Verify the standalone output exists
if [[ ! -f "$APP_DIR/.next/standalone/server.js" ]]; then
  error "Build output not found at $APP_DIR/.next/standalone/server.js"
  error "The 'build' script should produce standalone output. Check next.config.ts."
  exit 1
fi
success "Standalone build verified at $APP_DIR/.next/standalone/server.js"

# ===========================================================================
# 7. NGINX CONFIGURATION
# ===========================================================================
info "===== STEP 7: Nginx Setup ====="

# Install Nginx
if command -v nginx &>/dev/null; then
  warn "Nginx is already installed. Skipping installation."
else
  apt-get install -y nginx
  systemctl enable nginx
  success "Nginx installed and enabled."
fi

# Remove default site if it exists
if [[ -f /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
  info "Removed default Nginx site."
fi

# Get server IP for display
SERVER_IP="$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"

if [[ -n "$APP_DOMAIN" ]]; then
  # ---- Domain-based configuration with SSL ----
  cat > /etc/nginx/sites-available/canvasspro << 'NGINX_EOF'
# =============================================================================
# Nginx Configuration — CanvassPro (HTTP → HTTPS redirect)
# =============================================================================

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name __APP_DOMAIN__;

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __APP_DOMAIN__;

    # --- SSL (managed by Certbot — paths updated automatically) ---
    ssl_certificate     /etc/letsencrypt/live/__APP_DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__APP_DOMAIN__/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # --- Security Headers ---
    add_header X-Frame-Options        "SAMEORIGIN"   always;
    add_header X-Content-Type-Options "nosniff"       always;
    add_header X-XSS-Protection       "1; mode=block" always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;

    # --- Gzip Compression ---
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/xml application/xml+rss text/javascript image/svg+xml;

    # --- Upload Size ---
    client_max_body_size 50M;

    # --- Next.js App Proxy ---
    location / {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket support (for Socket.IO / dev hot reload)
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    # --- Uploaded Files (served statically for performance) ---
    location /upload/ {
        alias __APP_DIR__/upload/;
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header X-Content-Type-Options "nosniff" always;
    }

    # --- Next.js Static Assets (long cache) ---
    location /_next/static/ {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location /favicon.ico {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        access_log off;
        log_not_found off;
    }
}
NGINX_EOF

  # Replace placeholders
  sed -i "s|__APP_DOMAIN__|${APP_DOMAIN}|g" /etc/nginx/sites-available/canvasspro
  sed -i "s|__APP_PORT__|${APP_PORT}|g"   /etc/nginx/sites-available/canvasspro
  sed -i "s|__APP_DIR__|${APP_DIR}|g"      /etc/nginx/sites-available/canvasspro

  success "Nginx config written (HTTPS with domain: $APP_DOMAIN)."

else
  # ---- IP-based configuration (no SSL) ----
  cat > /etc/nginx/sites-available/canvasspro << 'NGINX_EOF'
# =============================================================================
# Nginx Configuration — CanvassPro (HTTP only — no domain configured)
# =============================================================================

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # --- Security Headers ---
    add_header X-Frame-Options        "SAMEORIGIN"   always;
    add_header X-Content-Type-Options "nosniff"       always;
    add_header X-XSS-Protection       "1; mode=block" always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;

    # --- Gzip Compression ---
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/xml application/xml+rss text/javascript image/svg+xml;

    # --- Upload Size ---
    client_max_body_size 50M;

    # --- Next.js App Proxy ---
    location / {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket support
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    # --- Uploaded Files (served statically for performance) ---
    location /upload/ {
        alias __APP_DIR__/upload/;
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header X-Content-Type-Options "nosniff" always;
    }

    # --- Next.js Static Assets (long cache) ---
    location /_next/static/ {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location /favicon.ico {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        access_log off;
        log_not_found off;
    }
}
NGINX_EOF

  # Replace placeholders
  sed -i "s|__APP_PORT__|${APP_PORT}|g" /etc/nginx/sites-available/canvasspro
  sed -i "s|__APP_DIR__|${APP_DIR}|g"  /etc/nginx/sites-available/canvasspro

  success "Nginx config written (HTTP only — set APP_DOMAIN for SSL)."
fi

# Enable the site
ln -sf /etc/nginx/sites-available/canvasspro /etc/nginx/sites-enabled/canvasspro

# Test configuration
if ! nginx -t 2>&1; then
  error "Nginx configuration test failed. Review /etc/nginx/sites-available/canvasspro"
  exit 1
fi
success "Nginx configuration validated."

# ===========================================================================
# 8. SYSTEMD SERVICE
# ===========================================================================
info "===== STEP 8: Systemd Service ====="

# Detect the actual Bun path
BUN_PATH="$(which bun 2>/dev/null || echo '')"
if [[ -z "$BUN_PATH" || ! -x "$BUN_PATH" ]]; then
  for candidate in /root/.bun/bin/bun /home/*/.bun/bin/bun /usr/local/bin/bun; do
    if [[ -x "$candidate" ]]; then
      BUN_PATH="$candidate"
      break
    fi
  done
fi

if [[ -z "$BUN_PATH" ]]; then
  error "Cannot find Bun binary. Install it first or set BUN_PATH manually."
  exit 1
fi

cat > /etc/systemd/system/canvasspro.service << SYSTEMD_EOF
[Unit]
Description=CanvassPro — Next.js Application
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=__DEPLOY_USER__
Group=__DEPLOY_USER__
WorkingDirectory=__APP_DIR__

# Environment
EnvironmentFile=__APP_DIR__/.env
Environment=NODE_ENV=production
Environment=PORT=__APP_PORT__

# Run the standalone Next.js server via Bun
ExecStart=__BUN_PATH__ __APP_DIR__/.next/standalone/server.js

# Restart policy
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=canvasspro

# Security hardening
NoNewPrivileges=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# Replace placeholders
sed -i "s|__DEPLOY_USER__|${DEPLOY_USER}|g" /etc/systemd/system/canvasspro.service
sed -i "s|__APP_DIR__|${APP_DIR}|g"         /etc/systemd/system/canvasspro.service
sed -i "s|__APP_PORT__|${APP_PORT}|g"       /etc/systemd/system/canvasspro.service
sed -i "s|__BUN_PATH__|${BUN_PATH}|g"       /etc/systemd/system/canvasspro.service

systemctl daemon-reload
systemctl enable canvasspro

success "Systemd service 'canvasspro' created and enabled (bun: $BUN_PATH)."

# ===========================================================================
# 9. LOGROTATE
# ===========================================================================
info "===== STEP 9: Log Rotation ====="

cat > /etc/logrotate.d/canvasspro << LOGROTATE_EOF
/var/log/canvasspro/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 __DEPLOY_USER__ adm
    sharedscripts
    postrotate
        systemctl reload canvasspro > /dev/null 2>&1 || true
    endscript
}
LOGROTATE_EOF

sed -i "s|__DEPLOY_USER__|${DEPLOY_USER}|g" /etc/logrotate.d/canvasspro

# Create log directory
mkdir -p /var/log/canvasspro
chown "$DEPLOY_USER:adm" /var/log/canvasspro

success "Log rotation configured."

# ===========================================================================
# 10. SSL (LET'S ENCRYPT) — optional
# ===========================================================================
if [[ -n "$APP_DOMAIN" && "$SKIP_SSL" != "true" ]]; then
  info "===== STEP 10: SSL Certificate (Let's Encrypt) ====="

  if ! command -v certbot &>/dev/null; then
    apt-get install -y certbot python3-certbot-nginx
    success "Certbot installed."
  fi

  mkdir -p /var/www/certbot

  # Obtain certificate (non-interactive)
  if certbot --nginx -d "$APP_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
    success "SSL certificate obtained for $APP_DOMAIN."
    # Set up auto-renewal timer
    systemctl enable certbot.timer
    systemctl start certbot.timer
    success "Certificate auto-renewal enabled (certbot.timer)."
  else
    warn "Certbot failed to obtain a certificate."
    warn "Make sure DNS for '$APP_DOMAIN' points to this server's IP ($SERVER_IP)."
    warn "You can retry manually: certbot --nginx -d $APP_DOMAIN"
  fi
elif [[ -n "$APP_DOMAIN" ]]; then
  info "===== STEP 10: SSL Skipped (SKIP_SSL=$SKIP_SSL) ====="
else
  info "===== STEP 10: SSL Skipped (no APP_DOMAIN set) ====="
fi

# ===========================================================================
# 11. FIREWALL (UFW)
# ===========================================================================
info "===== STEP 11: Firewall Configuration ====="

if command -v ufw &>/dev/null; then
  ufw allow "$SSH_PORT"/tcp comment "SSH"
  ufw allow 80/tcp              comment "HTTP"
  ufw allow 443/tcp             comment "HTTPS"

  if ufw status | grep -q "inactive"; then
    echo "y" | ufw enable
    success "UFW firewall enabled."
  else
    success "UFW firewall already active. Rules added."
  fi
else
  warn "UFW not installed. Install with: apt-get install -y ufw"
fi

# ===========================================================================
# 12. START SERVICES
# ===========================================================================
info "===== STEP 12: Starting Services ====="

# Restart Nginx to pick up the new config
systemctl restart nginx
success "Nginx started."

# Start the application
systemctl start canvasspro
sleep 3

# Verify it's running
if systemctl is-active --quiet canvasspro; then
  success "CanvassPro application is RUNNING."
else
  error "CanvassPro application failed to start. Check logs:"
  error "  journalctl -u canvasspro -n 50 --no-pager"
fi

# ===========================================================================
# DEPLOYMENT SUMMARY
# ===========================================================================
echo ""
echo -e "${GREEN}=====================================================================${NC}"
echo -e "${GREEN}                    DEPLOYMENT COMPLETE                              ${NC}"
echo -e "${GREEN}=====================================================================${NC}"
echo ""
echo -e "  ${CYAN}Application:${NC}    CanvassPro (Next.js 16 + Bun)"
echo -e "  ${CYAN}App Directory:${NC}  $APP_DIR"
echo -e "  ${CYAN}App Port:${NC}      $APP_PORT"
echo -e "  ${CYAN}Deploy User:${NC}    $DEPLOY_USER"
echo ""
echo -e "  ${CYAN}Database:${NC}       PostgreSQL ${DB_HOST}:${DB_PORT}"
echo -e "  ${CYAN}DB Name:${NC}       $DB_NAME"
echo -e "  ${CYAN}DB User:${NC}       $DB_USER"
echo -e "  ${CYAN}DB Password:${NC}   ${RED}${DB_PASSWORD}${NC}  ${YELLOW}<-- SAVE THIS!${NC}"
echo ""
echo -e "  ${CYAN}Web Server:${NC}    Nginx"
if [[ -n "$APP_DOMAIN" ]]; then
echo -e "  ${CYAN}URL:${NC}           https://$APP_DOMAIN"
else
echo -e "  ${CYAN}URL:${NC}           http://${SERVER_IP}"
echo -e "  ${YELLOW}Tip:${NC}            Set APP_DOMAIN=yourdomain.com for HTTPS."
fi
echo ""
echo -e "  ${CYAN}Upload Dir:${NC}    $APP_DIR/upload/"
echo -e "  ${CYAN}Env File:${NC}      $APP_DIR/.env"
echo ""
echo -e "  ${GREEN}Useful Commands:${NC}"
echo "  ─────────────────────────────────────────────────────────"
echo "  View app logs:      journalctl -u canvasspro -f"
echo "  Restart app:        sudo systemctl restart canvasspro"
echo "  Stop app:           sudo systemctl stop canvasspro"
echo "  App status:         sudo systemctl status canvasspro"
echo ""
echo "  Update & rebuild:"
echo "    cd $APP_DIR"
echo "    git pull && bun install && bunx prisma generate"
echo "    bunx prisma db push && bun run build"
echo "    sudo systemctl restart canvasspro"
echo ""
echo "  Database access:    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME"
echo "  Nginx config:       /etc/nginx/sites-available/canvasspro"
echo "  Nginx reload:       sudo nginx -t && sudo systemctl reload nginx"
echo "  SSL renewal:        sudo certbot renew"
echo ""
echo -e "  ${RED}IMPORTANT:${NC}       Save the DB password above! Also in $SCRIPT_DIR/.deploy-env"
echo ""
echo -e "${GREEN}=====================================================================${NC}"