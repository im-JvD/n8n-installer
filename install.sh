#!/usr/bin/env bash

# ============================================================================
# n8n Installer v6.2
# Docker + PostgreSQL + Nginx + Let's Encrypt SSL
# ============================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RED='\033[0;31m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ----------------------------------------------------------------------------
# Paths and names
# ----------------------------------------------------------------------------
INSTALL_DIR="/opt/n8n"
SCRIPT_PATH="$INSTALL_DIR/install_v6.sh"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
BACKUP_DIR="$INSTALL_DIR/backups"

NGINX_SITE_NAME="n8n"
NGINX_AVAILABLE="/etc/nginx/sites-available/$NGINX_SITE_NAME"
NGINX_ENABLED="/etc/nginx/sites-enabled/$NGINX_SITE_NAME"

APP_CONTAINER="n8n-app"
DB_CONTAINER="n8n-db"

APP_SERVICE="n8n"
DB_SERVICE="db"

# ----------------------------------------------------------------------------
# Error handling
# ----------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    echo
    echo -e "${RED}✖ An unexpected error occurred.${NC}"
    echo -e "${YELLOW}Line: ${BASH_LINENO[0]:-unknown}${NC}"
    echo -e "${YELLOW}Command: ${BASH_COMMAND:-unknown}${NC}"
    echo -e "${YELLOW}Exit code: $exit_code${NC}"
    exit "$exit_code"
}

trap on_error ERR

# ----------------------------------------------------------------------------
# Basic helpers
# ----------------------------------------------------------------------------
pause() {
    echo
    read -r -p "Press Enter to continue..." _
}

banner() {
    clear || true

    echo -e "${PURPLE}"
    echo "======================================================"
    echo -e "          ${BOLD}n8n Installer v6.2${NC}${PURPLE}"
    echo "       Docker + PostgreSQL + SSL Edition"
    echo "======================================================"
    echo -e "${NC}"
}

info() {
    echo -e "${BLUE}ℹ $*${NC}"
}

success() {
    echo -e "${GREEN}✔ $*${NC}"
}

warning() {
    echo -e "${YELLOW}⚠ $*${NC}"
}

error_msg() {
    echo -e "${RED}✖ $*${NC}"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error_msg "Run this script as root or with sudo."
        echo
        echo "Example:"
        echo "sudo bash install_v6.sh"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Generates a secure lowercase alphanumeric value without pipefail/SIGPIPE issues
random_value() {
    local length="$1"
    local value=""

    while [[ "${#value}" -lt "$length" ]]; do
        value+="$(openssl rand -hex "$length" 2>/dev/null | tr -cd 'a-z0-9')"
    done

    printf '%s' "${value:0:length}"
}

get_env_value() {
    local key="$1"

    if [[ ! -f "$ENV_FILE" ]]; then
        return 0
    fi

    sed -n "s/^${key}=//p" "$ENV_FILE" | head -n 1
}

set_env_value() {
    local key="$1"
    local value="$2"
    local escaped_value

    escaped_value="$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')"

    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

# ----------------------------------------------------------------------------
# Dependency installation
# ----------------------------------------------------------------------------
install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive

    info "Updating package lists..."
    apt-get update -y

    local packages=(
        ca-certificates
        curl
        openssl
        zip
        unzip
        nginx
        certbot
        python3-certbot-nginx
        docker.io
    )

    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            info "Installing $package..."
            apt-get install -y "$package"
        fi
    done

    if ! docker compose version >/dev/null 2>&1; then
        info "Installing Docker Compose plugin..."

        apt-get install -y docker-compose-plugin || {
            error_msg "Docker Compose plugin could not be installed."
            echo "Try manually:"
            echo "apt-get install -y docker-compose-plugin"
            exit 1
        }
    fi

    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx >/dev/null 2>&1 || true

    success "Required dependencies are ready."
}

check_dependencies() {
    local missing=0
    local binaries=(
        docker
        curl
        openssl
        zip
        unzip
        nginx
        certbot
    )

    for binary in "${binaries[@]}"; do
        if ! command_exists "$binary"; then
            error_msg "Missing command: $binary"
            missing=1
        fi
    done

    if ! docker compose version >/dev/null 2>&1; then
        error_msg "Docker Compose plugin is not available."
        missing=1
    fi

    if [[ "$missing" -eq 1 ]]; then
        echo
        warning "Run the installation option again to install dependencies."
        return 1
    fi

    return 0
}

# ----------------------------------------------------------------------------
# Domain and SSL configuration
# ----------------------------------------------------------------------------
valid_domain() {
    local domain="$1"

    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

prompt_domain_configuration() {
    mkdir -p "$INSTALL_DIR"

    local existing_domain
    local existing_email

    existing_domain="$(get_env_value "N8N_HOST")"
    existing_email="$(get_env_value "SSL_EMAIL")"

    if [[ -n "$existing_domain" && -n "$existing_email" ]]; then
        DOMAIN_NAME="$existing_domain"
        SSL_EMAIL="$existing_email"

        info "Existing domain found: $DOMAIN_NAME"
        return
    fi

    echo
    echo -e "${CYAN}Domain configuration${NC}"
    echo "The domain must already point to this server's public IP."
    echo

    while true; do
        read -r -p "Enter n8n domain, e.g. n8n.example.com: " DOMAIN_NAME

        if valid_domain "$DOMAIN_NAME"; then
            break
        fi

        error_msg "Invalid domain format."
    done

    while true; do
        read -r -p "Email for Let's Encrypt certificate: " SSL_EMAIL

        if [[ "$SSL_EMAIL" == *"@"*"."* ]]; then
            break
        fi

        error_msg "Invalid email address."
    done

    if [[ ! -f "$ENV_FILE" ]]; then
        touch "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi

    set_env_value "N8N_HOST" "$DOMAIN_NAME"
    set_env_value "SSL_EMAIL" "$SSL_EMAIL"
    set_env_value "N8N_PROTOCOL" "https"
    set_env_value "WEBHOOK_URL" "https://${DOMAIN_NAME}/"

    success "Domain configuration saved."
}

check_domain_dns() {
    local domain="$1"
    local server_ip=""
    local domain_ip=""

    server_ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    domain_ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}' || true)"

    if [[ -z "$domain_ip" ]]; then
        error_msg "Domain does not resolve to an IPv4 address."
        echo "Domain: $domain"
        echo
        echo "Check your DNS A record before continuing."
        return 1
    fi

    info "Domain resolves to: $domain_ip"

    if [[ -n "$server_ip" && "$domain_ip" != "$server_ip" ]]; then
        warning "Domain IP ($domain_ip) differs from server IP ($server_ip)."
        warning "Let's Encrypt may fail if DNS is not fully propagated."

        read -r -p "Continue anyway? [y/N] " answer

        if [[ "${answer,,}" != "y" ]]; then
            return 1
        fi
    fi

    return 0
}

configure_nginx() {
    local domain="$1"

    cat > "$NGINX_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${domain};

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:5678;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 300;
        proxy_send_timeout 300;

        proxy_buffering off;
    }
}
EOF

    ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"

    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl reload nginx

    success "Nginx reverse proxy configured."
}

configure_ssl() {
    local domain="$1"
    local email="$2"

    if [[ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
        info "Requesting Let's Encrypt certificate..."

        certbot --nginx \
            --non-interactive \
            --agree-tos \
            --no-eff-email \
            --redirect \
            -m "$email" \
            -d "$domain"
    else
        info "SSL certificate already exists for $domain."
    fi

    systemctl enable certbot.timer >/dev/null 2>&1 || true
    systemctl start certbot.timer >/dev/null 2>&1 || true

    success "SSL configuration completed."
}

setup_nginx_and_ssl() {
    source "$ENV_FILE"

    local domain="${N8N_HOST:-}"
    local email="${SSL_EMAIL:-}"

    if [[ -z "$domain" || -z "$email" ]]; then
        error_msg "Domain or SSL email is missing from .env."
        return 1
    fi

    if ! check_domain_dns "$domain"; then
        warning "SSL setup was skipped."
        warning "You can fix DNS and run the installation again."
        return 0
    fi

    configure_nginx "$domain"
    configure_ssl "$domain" "$email"
}

# ----------------------------------------------------------------------------
# Environment
# ----------------------------------------------------------------------------
ensure_env() {
    mkdir -p "$INSTALL_DIR"

    if [[ ! -f "$ENV_FILE" ]]; then
        local db_user
        local db_password
        local db_name
        local encryption_key

        db_user="n8n_$(random_value 8)"
        db_password="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"
        db_name="n8n_$(random_value 8)"
        encryption_key="$(openssl rand -hex 32)"

        umask 077

        cat > "$ENV_FILE" <<EOF
# n8n configuration
# Keep this file safe. It contains database credentials and encryption key.

POSTGRES_USER=${db_user}
POSTGRES_PASSWORD=${db_password}
POSTGRES_DB=${db_name}

N8N_DB_HOST=${DB_CONTAINER}
N8N_DB_PORT=5432
N8N_DB_NAME=${db_name}
N8N_DB_USER=${db_user}
N8N_DB_PASSWORD=${db_password}

N8N_ENCRYPTION_KEY=${encryption_key}

N8N_PORT=5678
N8N_PROTOCOL=https
N8N_HOST=
WEBHOOK_URL=

SSL_EMAIL=

GENERIC_TIMEZONE=Asia/Tehran
TZ=Asia/Tehran
N8N_RUNNERS_ENABLED=true
EOF

        chmod 600 "$ENV_FILE"
        success "Secure .env file created."
    else
        chmod 600 "$ENV_FILE"
        info "Existing .env preserved."
    fi
}

# ----------------------------------------------------------------------------
# Docker Compose
# ----------------------------------------------------------------------------
write_compose_file() {
    cat > "$COMPOSE_FILE" <<'EOF'
services:
  db:
    image: postgres:16-alpine
    container_name: n8n-db
    restart: unless-stopped

    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}

    volumes:
      - n8n_db_data:/var/lib/postgresql/data

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"
        ]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n-app
    restart: unless-stopped

    depends_on:
      db:
        condition: service_healthy

    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: ${N8N_DB_HOST}
      DB_POSTGRESDB_PORT: ${N8N_DB_PORT}
      DB_POSTGRESDB_DATABASE: ${N8N_DB_NAME}
      DB_POSTGRESDB_USER: ${N8N_DB_USER}
      DB_POSTGRESDB_PASSWORD: ${N8N_DB_PASSWORD}

      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}

      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: ${N8N_PROTOCOL}
      WEBHOOK_URL: ${WEBHOOK_URL}

      N8N_PORT: ${N8N_PORT}

      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      TZ: ${TZ}

      N8N_RUNNERS_ENABLED: ${N8N_RUNNERS_ENABLED}

    ports:
      - "127.0.0.1:5678:5678"

    volumes:
      - n8n_data:/home/node/.n8n
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  n8n_data:
  n8n_db_data:
EOF

    success "docker-compose.yml written."
}

# ----------------------------------------------------------------------------
# Persistent command: n8n
# ----------------------------------------------------------------------------
install_global_command() {
    cat > /usr/local/bin/n8nmenu <<EOF
#!/usr/bin/env bash
exec bash "$SCRIPT_PATH"
EOF

    chmod 755 /usr/local/bin/n8nmenu

    ln -sfn /usr/local/bin/n8nmenu /usr/local/bin/n8n

    cat > /etc/profile.d/n8n.sh <<'EOF'
# n8n global menu
export PATH="/usr/local/bin:$PATH"
EOF

    chmod 644 /etc/profile.d/n8n.sh

    success "The permanent command 'n8n' was installed."
}

copy_script_to_install_dir() {
    local current_script="${BASH_SOURCE[0]}"

    if [[ -f "$current_script" && "$current_script" != "$SCRIPT_PATH" ]]; then
        cp -f "$current_script" "$SCRIPT_PATH"
        chmod 755 "$SCRIPT_PATH"
    fi

    if [[ ! -f "$SCRIPT_PATH" ]]; then
        warning "Could not copy the installer to $SCRIPT_PATH."
        warning "The global n8n command may not work after reboot."
    fi
}

# ----------------------------------------------------------------------------
# Docker operations
# ----------------------------------------------------------------------------
wait_for_containers() {
    local retries=30
    local i

    for ((i = 1; i <= retries; i++)); do
        if docker inspect -f '{{.State.Running}}' "$APP_CONTAINER" 2>/dev/null | grep -q true &&
           docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
            success "Containers are running."
            return 0
        fi

        sleep 2
    done

    error_msg "Containers did not become ready in time."
    cd "$INSTALL_DIR"
    docker compose ps || true
    docker compose logs --tail=100 "$APP_SERVICE" "$DB_SERVICE" || true

    return 1
}

do_install() {
    banner
    require_root

    install_dependencies
    check_dependencies

    mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"

    ensure_env
    prompt_domain_configuration

    # Re-read values after domain configuration
    source "$ENV_FILE"

    write_compose_file
    copy_script_to_install_dir
    install_global_command

    cd "$INSTALL_DIR"

    echo -e "${CYAN}Pulling Docker images...${NC}"
    docker compose pull

    echo -e "${CYAN}Starting n8n and PostgreSQL...${NC}"
    docker compose up -d

    wait_for_containers

    setup_nginx_and_ssl

    source "$ENV_FILE"

    echo
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}✔ n8n installation completed${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo
    echo -e "URL: ${BOLD}https://${N8N_HOST}${NC}"
    echo
    echo -e "${YELLOW}From now on, you can open the menu with:${NC}"
    echo -e "${BOLD}n8n${NC}"
    echo

    pause
}

do_start() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error_msg "n8n is not installed."
        pause
        return
    fi

    cd "$INSTALL_DIR"
    docker compose up -d

    success "n8n started."
    pause
}

do_stop() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error_msg "n8n is not installed."
        pause
        return
    fi

    cd "$INSTALL_DIR"
    docker compose stop

    success "n8n stopped."
    pause
}

show_status() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error_msg "n8n is not installed."
        pause
        return
    fi

    cd "$INSTALL_DIR"

    echo
    docker compose ps
    echo

    docker ps \
        --filter "name=$APP_CONTAINER" \
        --filter "name=$DB_CONTAINER" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    pause
}

show_logs() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error_msg "n8n is not installed."
        pause
        return
    fi

    cd "$INSTALL_DIR"

    echo -e "${YELLOW}Live logs started. Press CTRL+C to return to the menu.${NC}"
    sleep 1

    # Prevent Ctrl+C from closing the whole menu
    set +e
    docker compose logs -f --tail=100 "$APP_SERVICE" "$DB_SERVICE"
    set -e

    echo
    success "Returned to menu."
    sleep 1
}

# ----------------------------------------------------------------------------
# Backup
# ----------------------------------------------------------------------------
do_backup() {
    if [[ ! -f "$ENV_FILE" ]]; then
        error_msg "n8n is not installed."
        pause
        return
    fi

    if ! docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
        error_msg "Database container is not running."
        pause
        return
    fi

    source "$ENV_FILE"

    mkdir -p "$BACKUP_DIR"

    local timestamp
    local dump_file
    local zip_file

    timestamp="$(date +%Y%m%d_%H%M%S)"
    dump_file="$BACKUP_DIR/n8n_db_${timestamp}.sql"
    zip_file="$BACKUP_DIR/n8n_db_${timestamp}.zip"

    echo -e "${CYAN}Creating PostgreSQL backup...${NC}"

    docker exec "$DB_CONTAINER" \
        pg_dump \
        --no-owner \
        --no-privileges \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" > "$dump_file"

    zip -j -q "$zip_file" "$dump_file"
    rm -f "$dump_file"

    success "Backup created:"
    echo "$zip_file"

    pause
}

# ----------------------------------------------------------------------------
# Restore
# ----------------------------------------------------------------------------
do_restore() {
    if [[ ! -f "$ENV_FILE" ]]; then
        error_msg "n8n is not installed."
        pause
        return
    fi

    if ! docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
        error_msg "Database container is not running."
        pause
        return
    fi

    local backups=()
    shopt -s nullglob
    backups=("$BACKUP_DIR"/*.zip)
    shopt -u nullglob

    if [[ "${#backups[@]}" -eq 0 ]]; then
        error_msg "No .zip backup found in $BACKUP_DIR."
        pause
        return
    fi

    echo
    echo -e "${CYAN}Available backups:${NC}"

    local selected=""
    select selected in "${backups[@]}"; do
        if [[ -n "$selected" ]]; then
            break
        fi

        warning "Invalid selection."
    done

    echo
    warning "This operation overwrites the current n8n database."

    read -r -p "Continue? [y/N] " answer

    if [[ "${answer,,}" != "y" ]]; then
        warning "Restore cancelled."
        pause
        return
    fi

    source "$ENV_FILE"

    local temp_dir
    local sql_file

    temp_dir="$(mktemp -d /tmp/n8n_restore_XXXXXX)"

    unzip -q "$selected" -d "$temp_dir"

    sql_file="$(find "$temp_dir" -type f -name '*.sql' | head -n 1 || true)"

    if [[ -z "$sql_file" || ! -f "$sql_file" ]]; then
        rm -rf "$temp_dir"
        error_msg "Invalid backup file."
        pause
        return
    fi

    echo -e "${CYAN}Restoring database...${NC}"

    docker exec -i "$DB_CONTAINER" \
        psql \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        < "$sql_file"

    rm -rf "$temp_dir"

    success "Database restored successfully."
    pause
}

# ----------------------------------------------------------------------------
# Credentials
# ----------------------------------------------------------------------------
show_credentials() {
    if [[ ! -f "$ENV_FILE" ]]; then
        error_msg "n8n is not installed."
        pause
        return
    fi

    echo
    warning "This file contains sensitive credentials."

    read -r -p "Show credentials? [y/N] " answer

    if [[ "${answer,,}" != "y" ]]; then
        return
    fi

    echo
    sed -E \
        -e 's/^(POSTGRES_PASSWORD=).*/\1********/' \
        -e 's/^(N8N_DB_PASSWORD=).*/\1********/' \
        -e 's/^(N8N_ENCRYPTION_KEY=).*/\1********/' \
        "$ENV_FILE"

    echo
    read -r -p "Show passwords and encryption key too? [y/N] " answer2

    if [[ "${answer2,,}" == "y" ]]; then
        echo
        cat "$ENV_FILE"
    fi

    pause
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
do_remove() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        warning "Installation directory does not exist."
        pause
        return
    fi

    warning "This deletes containers, volumes, credentials, backups and SSL proxy config."

    read -r -p "Type DELETE to continue: " confirmation

    if [[ "$confirmation" != "DELETE" ]]; then
        warning "Uninstall cancelled."
        pause
        return
    fi

    if [[ -f "$COMPOSE_FILE" ]]; then
        cd "$INSTALL_DIR"
        docker compose down -v --remove-orphans || true
    fi

    rm -rf "$INSTALL_DIR"

    rm -f /usr/local/bin/n8n
    rm -f /usr/local/bin/n8nmenu

    rm -f "$NGINX_ENABLED"
    rm -f "$NGINX_AVAILABLE"

    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true

    success "n8n was completely removed."
    pause
}

# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------
main_menu() {
    while true; do
        banner

        echo -e "${GREEN}[1]${NC} Install / Update n8n"
        echo -e "${BLUE}[2]${NC} Show status"
        echo -e "${CYAN}[3]${NC} Show live logs"
        echo -e "${GREEN}[4]${NC} Start n8n"
        echo -e "${YELLOW}[5]${NC} Stop n8n"
        echo -e "${PURPLE}[6]${NC} Create backup"
        echo -e "${PURPLE}[7]${NC} Restore backup"
        echo -e "${WHITE}[8]${NC} Show credentials"
        echo -e "${RED}[9]${NC} Uninstall completely"
        echo -e "${RED}[0]${NC} Exit"

        echo
        read -r -p "Choose an option [0-9]: " choice

        case "$choice" in
            1) do_install ;;
            2) show_status ;;
            3) show_logs ;;
            4) do_start ;;
            5) do_stop ;;
            6) do_backup ;;
            7) do_restore ;;
            8) show_credentials ;;
            9) do_remove ;;
            0)
                echo -e "${GREEN}Goodbye.${NC}"
                exit 0
                ;;
            *)
                error_msg "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
require_root
main_menu
