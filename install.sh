#!/bin/bash

# Project: n8n Auto-Installer (PostgreSQL Edition) - Optimized v6
# License: GPLv3
# User: im-JvD

set -e

# --- Colors (Bright Nerd Palette) ---
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
PINK='\033[1;38;5;206m'
NC='\033[0m' # No Color

# --- Paths ---
INSTALL_DIR="/opt/n8n"
DATA_DIR="/var/lib/n8n"
BACKUP_DIR="/opt/n8n/backup"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
NGINX_SITE="/etc/nginx/sites-available/n8n"
SCRIPT_PATH="$(readlink -f "$0")"

# --- Variables ---
DOMAIN=""
EMAIL=""

# Function to make the script globally accessible
make_global() {
    if [[ "$SCRIPT_PATH" != "/usr/local/bin/n8n" ]]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/n8n
        chmod +x /usr/local/bin/n8n
    fi
}

pause() {
    echo
    echo -e "${PINK}───────────────────────────────────────────────────${NC}"
    read -rp " Press Enter to continue..."
}

install_dependencies() {
    echo -e "${BLUE}⚡ Installing dependencies...${NC}"
    apt update && apt upgrade -y
    apt install -y curl nginx certbot python3-certbot-nginx ca-certificates openssl zip unzip
    
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${BLUE}🐳 Installing Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
    systemctl enable --now nginx
}

create_configs() {
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR/postgres"
    mkdir -p "$DATA_DIR/data"
    mkdir -p "$BACKUP_DIR"
    
    # Permissions
    chown -R 1000:1000 "$DATA_DIR/data"
    chmod -R 755 "$DATA_DIR/data"
    chown -R 999:999 "$DATA_DIR/postgres"
    chmod -R 700 "$DATA_DIR/postgres"

    # Generate Secure Random DB User & Password
    if [ ! -f "$ENV_FILE" ]; then
        RANDOM_USER="n8n_$(openssl rand -hex 4)"
        DB_PASSWORD=$(openssl rand -hex 16)
        cat > "$ENV_FILE" <<EOF
POSTGRES_USER=${RANDOM_USER}
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_DB=n8n_db
EOF
    fi

    source "$ENV_FILE"

    # Create Docker Compose
    cat > "$COMPOSE_FILE" <<EOF
services:
  db:
    image: postgres:16-alpine
    container_name: n8n-db
    restart: always
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n_db
    volumes:
      - $DATA_DIR/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d n8n_db"]
      interval: 5s
      timeout: 5s
      retries: 5

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n-app
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n_db
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - N8N_EDITOR_BASE_URL=https://${DOMAIN}
      - N8N_WEBHOOK_URL=https://${DOMAIN}
      - WEBHOOK_URL=https://${DOMAIN}
      - GENERIC_TIMEZONE=Asia/Tehran
      - TZ=Asia/Tehran
      - N8N_SECURE_COOKIE=true
      - N8N_RUNNERS_ENABLED=true
      - N8N_UNVERIFIED_PACKAGES_ENABLED=true
    volumes:
      - $DATA_DIR/data:/home/node/.n8n
    depends_on:
      db:
        condition: service_healthy
EOF
}

create_nginx_config() {
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/n8n
    rm -f /etc/nginx/sites-enabled/default || true
    nginx -t && systemctl reload nginx
}

issue_ssl() {
    echo -e "${BLUE}🔐 Requesting SSL certificate...${NC}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
}

show_status_and_logs() {
    clear
    echo -e "${PURPLE}================ SYSTEM STATUS =================${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo -e "${PURPLE}================================================${NC}"
    echo
    echo -e "${YELLOW}↓↓↓ LIVE LOGS (Last 50 lines) ↓↓↓${NC}"
    echo -e "${PINK}Hint: Press CTRL+C to return to Manager Menu${NC}"
    echo
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$INSTALL_DIR"
        docker compose logs -f --tail 50
    else
        echo -e "${RED}Error: n8n is not installed yet.${NC}"
        pause
    fi
}

install_n8n() {
    echo -e "${PINK}Initial Setup Configuration${NC}"
    read -rp "Enter Domain (e.g., n8n.example.com): " DOMAIN
    read -rp "Enter Email for SSL: " EMAIL

    install_dependencies
    create_configs
    create_nginx_config
    issue_ssl
    
    cd "$INSTALL_DIR"
    docker compose up -d
    
    make_global
    echo -e "${GREEN}✅ Installation completed! Redirecting to Live Logs...${NC}"
    sleep 2
    show_status_and_logs
}

update_n8n() {
    if [ ! -f "$COMPOSE_FILE" ]; then echo -e "${RED}Not installed.${NC}"; pause; return; fi
    echo -e "${BLUE}🔄 Updating n8n Images...${NC}"
    cd "$INSTALL_DIR"
    docker compose pull && docker compose up -d
    echo -e "${GREEN}Successfully updated.${NC}"
    pause
}

backup_restore_menu() {
    clear
    echo -e "${PURPLE}=========================================="
    echo -e "      n8n Backup & Restore System"
    echo -e "==========================================${NC}"
    echo -e "1) ${GREEN}Create Backup${NC} (Database -> Zip)"
    echo -e "2) ${YELLOW}Restore Backup${NC} (Zip -> Database)"
    echo -e "0) Back to Main Menu"
    read -rp "Choice: " br_choice

    source "$ENV_FILE"

    case "$br_choice" in
        1)
            echo -e "${BLUE}Creating backup...${NC}"
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)
            BACKUP_NAME="n8n_backup_$TIMESTAMP"
            docker exec n8n-db pg_dump -U "$POSTGRES_USER" n8n_db > "$BACKUP_DIR/$BACKUP_NAME.sql"
            cd "$BACKUP_DIR" && zip -m "$BACKUP_NAME.zip" "$BACKUP_NAME.sql"
            echo -e "${GREEN}Backup created successfully: $BACKUP_DIR/$BACKUP_NAME.zip${NC}"
            pause
            ;;
        2)
            echo -e "${YELLOW}Available backups in $BACKUP_DIR:${NC}"
            ls "$BACKUP_DIR"/*.zip 2>/dev/null || echo "No backups found."
            read -rp "Enter full zip filename to restore: " ZIP_FILE
            if [ -f "$BACKUP_DIR/$ZIP_FILE" ]; then
                echo -e "${RED}Restoring... Current data will be overwritten!${NC}"
                unzip -p "$BACKUP_DIR/$ZIP_FILE" > "$BACKUP_DIR/restore_temp.sql"
                docker exec -i n8n-db psql -U "$POSTGRES_USER" n8n_db < "$BACKUP_DIR/restore_temp.sql"
                rm "$BACKUP_DIR/restore_temp.sql"
                echo -e "${GREEN}Database restoration complete.${NC}"
            else
                echo -e "${RED}File not found.${NC}"
            fi
            pause
            ;;
        *) return ;;
    esac
}

remove_n8n() {
    echo -e "${RED}⚠️  WARNING: This will delete EVERYTHING including Database!${NC}"
    read -rp "Type 'DELETE' to confirm: " confirm
    if [[ "$confirm" == "DELETE" ]]; then
        cd "$INSTALL_DIR" && docker compose down -v || true
        rm -rf "$INSTALL_DIR" "$DATA_DIR" "$NGINX_SITE" /etc/nginx/sites-enabled/n8n
        rm -f /usr/local/bin/n8n
        systemctl reload nginx
        echo -e "${GREEN}n8n has been completely removed.${NC}"
    else
        echo -e "${YELLOW}Removal cancelled.${NC}"
    fi
    pause
}

# --- Main Menu ---
menu() {
    make_global
    while true; do
        clear
        echo ""
        echo -e "${BLUE}==========================================${NC}"
        echo -e "${PINK}      n8n Manager ( PostgreSQL )${NC}"
        echo -e "${BLUE}==========================================${NC}"
        echo ""
        echo -e "${GREEN}1)${NC} Install n8n (Full Setup)"
        echo -e "${GREEN}2)${NC} Status & Live Logs (F)"
        echo -e "${BLUE}3)${NC} Update Service"
        echo -e "${PURPLE}4)${NC} Backup & Restore"
        echo -e "${RED}5)${NC} Remove Everything"
        echo ""
        echo -e "${NC}0) Exit"
        echo -e "${BLUE}──────────────────────────────────────────${NC}"
        echo ""
        read -rp "Choice: " choice
        case "$choice" in
            1) install_n8n ;;
            2) show_status_and_logs ;;
            3) update_n8n ;;
            4) backup_restore_menu ;;
            5) remove_n8n ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid selection.${NC}"; sleep 1 ;;
        esac
    done
}

menu
