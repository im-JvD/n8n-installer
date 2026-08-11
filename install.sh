#!/usr/bin/env bash
# ============================================================================
#  n8n Installer - v6.1 (Production Ready)
#  Docker + PostgreSQL + Nginx + SSL (Let's Encrypt)
#  Author  : im-JvD
#  License : GPLv3
# ============================================================================
#  Features:
#   ✔ Secure random DB credentials
#   ✔ Docker + PostgreSQL
#   ✔ Auto SSL with Let's Encrypt
#   ✔ Domain/Subdomain support
#   ✔ Persistent global `n8n` command
#   ✔ Live logs
#   ✔ Backup / Restore
#   ✔ Idempotent
#   ✔ Production-ready structure
# ============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RED='\033[0;31m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
INSTALL_DIR="/opt/n8n"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
BACKUP_DIR="$INSTALL_DIR/backups"

APP_CONTAINER="n8n-app"
DB_CONTAINER="n8n-db"

SVC_APP="n8n"
SVC_DB="db"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pause() {
    echo
    read -r -p "Press Enter to continue..." _
    clear
}

banner() {
    clear
    echo -e "${PURPLE}"
    echo "===================================================="
    echo -e "        ${BOLD}n8n Installer v6.1${NC}${PURPLE}"
    echo "         Production Ready Edition"
    echo "===================================================="
    echo -e "${NC}"
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}Please run with sudo/root.${NC}"
        exit 1
    fi
}

rand_word() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c "$1"
}

check_dependencies() {

    apt-get update -y

    local packages=(
        docker.io
        docker-compose-plugin
        curl
        unzip
        zip
        openssl
        nginx
        certbot
        python3-certbot-nginx
    )

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo -e "${CYAN}Installing ${pkg}...${NC}"
            apt-get install -y "$pkg"
        fi
    done

    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Prompt domain
# ---------------------------------------------------------------------------
prompt_domain() {

    if [[ -f "$ENV_FILE" ]]; then
        return
    fi

    echo
    read -r -p "Domain/Subdomain for n8n (example: n8n.example.com): " DOMAIN_NAME

    while [[ -z "${DOMAIN_NAME:-}" ]]; do
        echo -e "${RED}Domain cannot be empty.${NC}"
        read -r -p "Domain/Subdomain: " DOMAIN_NAME
    done

    read -r -p "Email for Let's Encrypt SSL: " ADMIN_EMAIL

    while [[ -z "${ADMIN_EMAIL:-}" ]]; do
        echo -e "${RED}Email cannot be empty.${NC}"
        read -r -p "Email: " ADMIN_EMAIL
    done
}

# ---------------------------------------------------------------------------
# ENV
# ---------------------------------------------------------------------------
ensure_env() {

    mkdir -p "$INSTALL_DIR"

    if [[ -f "$ENV_FILE" ]]; then
        echo -e "${BLUE}Using existing .env${NC}"
        return
    fi

    local DB_USER="n8n_$(rand_word 8)"
    local DB_PASSWORD
    DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"

    local DB_NAME="n8n_$(rand_word 6)"
    local ENC_KEY
    ENC_KEY="$(openssl rand -hex 32)"

    cat > "$ENV_FILE" <<EOF
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASSWORD
POSTGRES_DB=$DB_NAME

N8N_DB_HOST=$DB_CONTAINER
N8N_DB_PORT=5432
N8N_DB_NAME=$DB_NAME
N8N_DB_USER=$DB_USER
N8N_DB_PASSWORD=$DB_PASSWORD

N8N_ENCRYPTION_KEY=$ENC_KEY

N8N_HOST=$DOMAIN_NAME
N8N_PROTOCOL=https
WEBHOOK_URL=https://$DOMAIN_NAME/

N8N_PORT=5678

GENERIC_TIMEZONE=Asia/Tehran
TZ=Asia/Tehran

N8N_RUNNERS_ENABLED=true
EOF

    chmod 600 "$ENV_FILE"

    echo -e "${GREEN}✔ Secure .env generated.${NC}"
}

# ---------------------------------------------------------------------------
# Docker Compose
# ---------------------------------------------------------------------------
ensure_compose() {

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
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

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
      - "5678:5678"

    volumes:
      - n8n_data:/home/node/.n8n
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  n8n_data:
  n8n_db_data:
EOF

    echo -e "${GREEN}✔ docker-compose.yml generated.${NC}"
}

# ---------------------------------------------------------------------------
# Nginx + SSL
# ---------------------------------------------------------------------------
setup_nginx_ssl() {

    source "$ENV_FILE"

    cat > /etc/nginx/sites-available/n8n <<EOF
server {
    server_name $N8N_HOST;

    location / {

        proxy_pass http://127.0.0.1:5678;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n

    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl restart nginx

    certbot --nginx \
        -d "$N8N_HOST" \
        --non-interactive \
        --agree-tos \
        -m "$ADMIN_EMAIL" \
        --redirect

    echo -e "${GREEN}✔ SSL installed successfully.${NC}"
}

# ---------------------------------------------------------------------------
# Global launcher
# ---------------------------------------------------------------------------
install_global_launcher() {

    cat > /usr/local/bin/n8nmenu <<EOF
#!/usr/bin/env bash
bash "$INSTALL_DIR/install_v6.sh"
EOF

    chmod +x /usr/local/bin/n8nmenu

    ln -sf /usr/local/bin/n8nmenu /usr/local/bin/n8n

    echo -e "${GREEN}✔ Global command installed: n8n${NC}"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
do_install() {

    banner

    require_root
    check_dependencies
    prompt_domain
    ensure_env
    ensure_compose

    echo -e "${CYAN}Pulling Docker images...${NC}"

    cd "$INSTALL_DIR"

    docker compose pull

    echo -e "${CYAN}Starting containers...${NC}"

    docker compose up -d

    echo -e "${CYAN}Waiting for services...${NC}"

    sleep 10

    setup_nginx_ssl

    install_global_launcher

    cp "$0" "$INSTALL_DIR/install_v6.sh"

    source "$ENV_FILE"

    echo
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}✔ n8n Installed Successfully${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo
    echo -e "URL : ${BOLD}https://$N8N_HOST${NC}"
    echo
    pause
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
show_logs() {

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}Not installed.${NC}"
        pause
        return
    fi

    cd "$INSTALL_DIR"

    echo -e "${YELLOW}Press CTRL+C to exit logs.${NC}"
    echo

    docker compose logs -f --tail=50 "$SVC_APP" "$SVC_DB"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {

    echo
    docker ps --filter "name=n8n" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    pause
}

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------
do_stop() {

    cd "$INSTALL_DIR"

    docker compose down

    echo -e "${GREEN}✔ Stopped.${NC}"

    pause
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
do_start() {

    cd "$INSTALL_DIR"

    docker compose up -d

    echo -e "${GREEN}✔ Started.${NC}"

    pause
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
do_backup() {

    mkdir -p "$BACKUP_DIR"

    local ts
    ts="$(date +%Y%m%d_%H%M%S)"

    local dump="$BACKUP_DIR/db_$ts.sql"

    source "$ENV_FILE"

    echo -e "${CYAN}Creating DB dump...${NC}"

    docker exec "$DB_CONTAINER" \
        pg_dump \
        -U "$POSTGRES_USER" \
        "$POSTGRES_DB" > "$dump"

    zip -j "$dump.zip" "$dump" >/dev/null

    rm -f "$dump"

    echo -e "${GREEN}✔ Backup created:${NC}"
    echo "$dump.zip"

    pause
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
do_restore() {

    source "$ENV_FILE"

    if ! ls "$BACKUP_DIR"/*.zip >/dev/null 2>&1; then
        echo -e "${RED}No backups found.${NC}"
        pause
        return
    fi

    echo
    echo -e "${CYAN}Available backups:${NC}"

    select file in "$BACKUP_DIR"/*.zip; do

        [[ -n "$file" ]] || continue

        read -r -p "Overwrite current database? [y/N] " ans

        [[ "${ans,,}" == "y" ]] || return

        local tmp="/tmp/n8n_restore_$RANDOM"

        mkdir -p "$tmp"

        unzip -q "$file" -d "$tmp"

        local sql
        sql="$(find "$tmp" -name '*.sql' | head -1)"

        docker exec -i "$DB_CONTAINER" \
            psql \
            -U "$POSTGRES_USER" \
            -d "$POSTGRES_DB" < "$sql"

        rm -rf "$tmp"

        echo -e "${GREEN}✔ Restore completed.${NC}"

        pause
        return
    done
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
show_credentials() {

    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}Not installed.${NC}"
        pause
        return
    fi

    read -r -p "Show credentials? [y/N] " ans

    [[ "${ans,,}" == "y" ]] || return

    echo
    cat "$ENV_FILE"
    echo

    pause
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
do_remove() {

    read -r -p "Delete EVERYTHING? [y/N] " ans

    [[ "${ans,,}" == "y" ]] || return

    cd "$INSTALL_DIR"

    docker compose down -v --remove-orphans || true

    rm -rf "$INSTALL_DIR"

    rm -f /usr/local/bin/n8n
    rm -f /usr/local/bin/n8nmenu

    rm -f /etc/nginx/sites-enabled/n8n
    rm -f /etc/nginx/sites-available/n8n

    systemctl restart nginx || true

    echo -e "${GREEN}✔ Completely removed.${NC}"

    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {

    while true; do

        banner

        echo -e "${CYAN}[1]${NC} Install n8n"
        echo -e "${CYAN}[2]${NC} Status"
        echo -e "${CYAN}[3]${NC} Live Logs"
        echo -e "${CYAN}[4]${NC} Start"
        echo -e "${CYAN}[5]${NC} Stop"
        echo -e "${CYAN}[6]${NC} Backup"
        echo -e "${CYAN}[7]${NC} Restore"
        echo -e "${CYAN}[8]${NC} Credentials"
        echo -e "${CYAN}[9]${NC} Uninstall"
        echo -e "${RED}[0]${NC} Exit"

        echo

        read -r -p "Choose: " choice

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
            0) exit 0 ;;

            *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;

        esac
    done
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
require_root
main_menu
