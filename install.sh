#!/usr/bin/env bash
# ============================================================================
#  n8n Installer - v6.0 (Stable)
#  Full WordPress-style n8n deployment with Docker + PostgreSQL
#  License : GPLv3
#  Author  : im-JvD
#  ---------------------------------------------------------------------------
#  Features:
#    * Random & secure DB credentials (no "admin" user)
#    * Docker + PostgreSQL (persistent volume)
#    * Colorful interactive menu
#    * Live logs (correct compose service names)
#    * Full backup/restore (pg_dump -> .zip)
#    * Screen-based persistent running
#    * Idempotent: safe to re-run, no duplicate installs
# ============================================================================

# ---------------------------------------------------------------------------
# 0) Colors
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
PINK='\033[0;31m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# 1) Global paths & variables
# ---------------------------------------------------------------------------
INSTALL_DIR="/opt/n8n"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
BACKUP_DIR="$INSTALL_DIR/backup"
LOG_DIR="$INSTALL_DIR/logs"
SCREEN_SESSION="n8n"

# Service names INSIDE compose (used by `docker compose logs`)
SVC_APP="n8n"
SVC_DB="db"
# Container names (used by `docker exec`)
APP_CONTAINER="n8n-app"
DB_CONTAINER="n8n-db"

# ---------------------------------------------------------------------------
# 2) Helpers
# ---------------------------------------------------------------------------
pause() {
    echo
    read -r -p "Press [Enter] to return to menu..." _
    clear
}

banner() {
    echo -e "${PURPLE}==============================================="
    echo -e "       ${BOLD}n8n Installer  v6.0 ${NC}${PURPLE}"
    echo -e "              Stable Edition"
    echo -e "===============================================${NC}"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}Please run as root (sudo).${NC}"
        exit 1
    fi
}

check_bins() {
    local missing=0
    for bin in docker openssl curl zip unzip; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo -e "${RED}Missing required binary: ${BOLD}$bin${NC}"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        echo -e "${YELLOW}Install them first: sudo apt install -y docker.io openssl curl${NC}"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}Docker Compose plugin not found. Install:${NC}"
        echo -e "${YELLOW}sudo apt install -y docker-compose-plugin${NC}"
        exit 1
    fi
}

# Generate a random lowercase alphanumeric string (no ambiguous chars)
rand_word() {
    local n="$1"
    tr -dc 'abcdefghijklmnopqrstuvwxyz0123456789' < /dev/urandom | head -c "$n"
}

# ---------------------------------------------------------------------------
# 3) Write .env (only once, keeps existing credentials)
# ---------------------------------------------------------------------------
ensure_env() {
    [[ -d "$INSTALL_DIR" ]] || mkdir -p "$INSTALL_DIR"
    if [[ ! -f "$ENV_FILE" ]]; then
        # ---- Secure random credentials (NO "admin", NO "root") ----
        local DB_USER="n8n_$(rand_word 8)"
        local DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
        local DB_NAME="n8n_$(rand_word 6)"
        local DB_PORT="5432"
        local APP_PORT="5678"
        local ENC_KEY="$(openssl rand -hex 32)"
        local TIMEZONE="Asia/Tehran"

        umask 077
        cat > "$ENV_FILE" <<EOF
# n8n environment (generated once, do not lose this file!)
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASSWORD
POSTGRES_DB=$DB_NAME
N8N_DB_HOST=$DB_CONTAINER
N8N_DB_PORT=$DB_PORT
N8N_DB_NAME=$DB_NAME
N8N_DB_USER=$DB_USER
N8N_DB_PASSWORD=$DB_PASSWORD
N8N_ENCRYPTION_KEY=$ENC_KEY
N8N_PORT=$APP_PORT
GENERIC_TIMEZONE=$TIMEZONE
TZ=$TIMEZONE
EOF
        echo -e "${GREEN}✔ Environment created with secure random credentials.${NC}"
    else
        echo -e "${BLUE}ℹ .env already exists - keeping existing credentials.${NC}"
    fi
}

# ---------------------------------------------------------------------------
# 4) Write docker-compose.yml (production-grade)
# ---------------------------------------------------------------------------
ensure_compose() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        echo -e "${BLUE}ℹ docker-compose.yml already exists.${NC}"
        return
    fi
    cat > "$COMPOSE_FILE" <<'EOF'
version: "3.8"

services:
  db:
    image: postgres:16-alpine
    container_name: n8n-db
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - n8n_db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
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
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_PORT=${N8N_PORT}
      - N8N_HOST=${N8N_HOST:-localhost}
      - N8N_PROTOCOL=${N8N_PROTOCOL:-http}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - TZ=${TZ}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED:-true}
    ports:
      - "${N8N_PORT}:${N8N_PORT}"
    volumes:
      - n8n_data:/home/node/.n8n
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  n8n_data:
  n8n_db_data:
EOF
    echo -e "${GREEN}✔ docker-compose.yml written.${NC}"
}

# ---------------------------------------------------------------------------
# 5) Install n8n (pull + up -d)
# ---------------------------------------------------------------------------
do_install() {
    banner
    check_root
    check_bins
    ensure_env
    ensure_compose

    echo -e "${CYAN}→ Pulling images (n8n + postgres)...${NC}"
    cd "$INSTALL_DIR"
    docker compose pull || { echo -e "${RED}✖ Pull failed. Check internet/registry.${NC}"; pause; return; }

    echo -e "${CYAN}→ Starting containers...${NC}"
    docker compose up -d || { echo -e "${RED}✖ Containers failed to start.${NC}"; pause; return; }

    sleep 3
    echo
    echo -e "${GREEN}✔ n8n is up!${NC}"
    echo -e "   URL      : ${BOLD}http://<SERVER_IP>:${N8N_PORT:-5678}${NC}"
    echo -e "   Access   : ${BOLD}http://<SERVER_IP>:${N8N_PORT:-5678}${NC}"

    # Auto-enter live logs after install
    show_live_status_logs
}

# ---------------------------------------------------------------------------
# 6) Status / live logs (correct COMPOSE service names)
# ---------------------------------------------------------------------------
show_live_status_logs() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}✖ n8n is not installed yet.${NC}"
        pause
        return
    fi
    clear
    echo -e "${PINK}=========================================="
    echo -e "          n8n Status & Live Logs"
    echo -e "==========================================${NC}"
    echo -e "${BLUE}--- Container Status ---${NC}"
    docker ps --filter "name=$APP_CONTAINER" --filter "name=$DB_CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo
    echo -e "${YELLOW}Showing live logs. Press CTRL+C to return.${NC}"
    echo -e "${PINK}------------------------------------------------------${NC}"
    sleep 1

    # Safe return on Ctrl+C
    trap 'echo; echo -e "${GREEN}Returning to menu...${NC}"; sleep 1; return' INT
    cd "$INSTALL_DIR"
    # NOTE: use SERVICE names here, NOT container names
    docker compose logs -f --tail 50 "$SVC_APP" "$SVC_DB"
    trap - INT
}

# ---------------------------------------------------------------------------
# 7) Stop containers
# ---------------------------------------------------------------------------
do_stop() {
    [[ -d "$INSTALL_DIR" ]] || { echo -e "${RED}Not installed.${NC}"; pause; return; }
    cd "$INSTALL_DIR"
    echo -e "${YELLOW}Stopping n8n + db...${NC}"
    docker compose down
    echo -e "${GREEN}✔ Stopped.${NC}"
    pause
}

# ---------------------------------------------------------------------------
# 8) Remove everything (with confirmation)
# ---------------------------------------------------------------------------
do_remove() {
    [[ -d "$INSTALL_DIR" ]] || { echo -e "${RED}Nothing installed.${NC}"; pause; return; }
    read -r -p "Delete ALL data (volumes + config + backups)? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
        cd "$INSTALL_DIR"
        docker compose down -v --remove-orphans
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}✔ Removed everything.${NC}"
    else
        echo -e "${YELLOW}Aborted.${NC}"
    fi
    pause
}

# ---------------------------------------------------------------------------
# 9) Backup (pg_dump -> zip)
# ---------------------------------------------------------------------------
do_backup() {
    if ! docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
        echo -e "${RED}✖ Database container not running.${NC}"
        pause
        return
    fi
    mkdir -p "$BACKUP_DIR"
    local ts="$(date +%Y%m%d_%H%M%S)"
    local dump="$BACKUP_DIR/db_backup_$ts"
    local zip="$dump.zip"

    echo -e "${CYAN}→ Dumping database...${NC}"
    docker exec "$DB_CONTAINER" pg_dump -U "$(awk -F= '/^POSTGRES_USER=/{print $2; exit}' "$ENV_FILE")" "$(awk -F= '/^POSTGRES_DB=/{print $2; exit}' "$ENV_FILE")" > "$dump"
    cd "$BACKUP_DIR" || return
    zip -q "db_backup_$ts.zip" "$(basename "$dump")" && rm -f "$dump"
    echo -e "${GREEN}✔ Backup created: ${BOLD}$zip${NC}"
    echo
    echo -e "${BLUE}Available backups:${NC}"
    ls -lh "$BACKUP_DIR"/*.zip 2>/dev/null || echo " (none)"
    pause
}

# ---------------------------------------------------------------------------
# 10) Restore (choose .zip, extract & restore)
# ---------------------------------------------------------------------------
do_restore() {
    if ! docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
        echo -e "${RED}✖ Database container not running.${NC}"
        pause
        return
    fi
    if ! ls "$BACKUP_DIR"/*.zip &>/dev/null; then
        echo -e "${RED}✖ No backups found in $BACKUP_DIR.${NC}"
        pause
        return
    fi

    echo -e "${BLUE}Select a backup file:${NC}"
    select f in "$BACKUP_DIR"/*.zip; do
        [[ -n "$f" ]] && break
    done

    read -r -p "This will OVERWRITE current data. Continue? [y/N] " ans
    if [[ "${ans,,}" != "y" ]]; then
        echo -e "${YELLOW}Aborted.${NC}"
        pause
        return
    fi

    local tmp="$BACKUP_DIR/.restore_$RANDOM"
    mkdir -p "$tmp"
    unzip -q "$f" -d "$tmp"

    local dumpfile
    dumpfile="$(find "$tmp" -type f | head -1)"
    [[ -n "$dumpfile" ]] || { echo -e "${RED}✖ Invalid backup.${NC}"; rm -rf "$tmp"; pause; return; }

    docker exec -i "$DB_CONTAINER" psql -U "$(awk -F= '/^POSTGRES_USER=/{print $2; exit}' "$ENV_FILE")" -d "$(awk -F= '/^POSTGRES_DB=/{print $2; exit}' "$ENV_FILE")" < "$dumpfile"
    echo -e "${GREEN}✔ Database restored from ${BOLD}$(basename "$f")${NC}"
    rm -rf "$tmp"
    pause
}

# ---------------------------------------------------------------------------
# 11) Display stored credentials (hidden by default)
# ---------------------------------------------------------------------------
show_credentials() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}✖ Not installed yet.${NC}"
        pause
        return
    fi
    echo -e "${PINK}=============================================="
    echo -e "         Stored Credentials (.env)"
    echo -e "==============================================${NC}"
    echo -e "${RED}Note: DB_USER is random & secure - NOT admin.${NC}"
    read -r -p "Show stored credentials from .env? [y/N] " ans
    if [[ "${ans,,}" != "y" ]]; then
        echo -e "${YELLOW}Aborted.${NC}"
        pause
        return
    fi
    grep -E 'POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|N8N_ENCRYPTION_KEY|N8N_PORT' "$ENV_FILE"
    pause
}

# ---------------------------------------------------------------------------
# 12) Main menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        banner
        echo -e "${CYAN}Choose an option:${NC}"
        echo -e "  ${GREEN}[1]${NC} Install n8n"
        echo -e "  ${BLUE}[2]${NC} Status + Live Logs"
        echo -e "  ${YELLOW}[3]${NC} Stop n8n"
        echo -e "  ${PURPLE}[4]${NC} Manage Backups"
        echo -e "  ${PINK}[5]${NC} Show Credentials"
        echo -e "  ${RED}[6]${NC} Uninstall (Wipe all data)"
        echo -e "  ${WHITE}[0]${NC} Exit"
        echo -e "${PINK}-----------------------------------${NC}"
        read -r -p "Enter choice [0-6]: " choice
        case "$choice" in
            1) do_install ;;
            2) show_live_status_logs ;;
            3) do_stop ;;
            4)
                echo -e "  ${GREEN}[a]${NC} Backup now"
                echo -e "  ${YELLOW}[b]${NC} Restore backup"
                read -r -p "  Backup option: " bk
                case "$bk" in
                    a|A) do_backup ;;
                    b|B) do_restore ;;
                    *) echo -e "${RED}Invalid.${NC}" ;;
                esac
                ;;
            5) show_credentials ;;
            6) do_remove ;;
            0) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
clear
main_menu
