#!/bin/bash

# Project: n8n Auto-Installer (PostgreSQL Edition)
# License: GPLv3
# Author: Your Name/Organization

set -e

# Colors for terminal
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
INSTALL_DIR="/opt/n8n"
DATA_DIR="/var/lib/n8n"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
NGINX_SITE="/etc/nginx/sites-available/n8n"
SCRIPT_PATH="$(readlink -f "$0")"

# Variables
DOMAIN=""
EMAIL=""

# Function to make the script globally accessible
make_global() {
    if [[ "$SCRIPT_PATH" != "/usr/local/bin/n8n" ]]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/n8n
        chmod +x /usr/local/bin/n8n
        echo -e "${GREEN}Info: You can now run this script anytime by typing 'n8n' in terminal.${NC}"
    fi
}

pause() {
    echo
    read -rp "Press Enter to continue..."
}

install_dependencies() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    apt update && apt upgrade -y
    apt install -y curl nginx certbot python3-certbot-nginx ca-certificates openssl

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${BLUE}Installing Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
    systemctl enable --now nginx
}

create_configs() {
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR/postgres"
    mkdir -p "$DATA_DIR/data"
    
    # n8n permissions
    chown -R 1000:1000 "$DATA_DIR/data"
    chmod -R 755 "$DATA_DIR/data"
    
    # postgres permissions
    chown -R 999:999 "$DATA_DIR/postgres"
    chmod -R 700 "$DATA_DIR/postgres"

    # Generate Secure DB Password if not exists
    if [ ! -f "$ENV_FILE" ]; then
        DB_PASSWORD=$(openssl rand -hex 16)
        cat > "$ENV_FILE" <<EOF
POSTGRES_USER=n8n_admin
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_DB=n8n_db
EOF
    fi

    # Create Docker Compose with PostgreSQL
    cat > "$COMPOSE_FILE" <<EOF
services:
  db:
    image: postgres:16-alpine
    container_name: n8n-db
    restart: always
    environment:
      - POSTGRES_USER=n8n_admin
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n_db
    volumes:
      - $DATA_DIR/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n_admin -d n8n_db"]
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
      - DB_POSTGRESDB_USER=n8n_admin
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
    echo -e "${BLUE}Requesting SSL certificate...${NC}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
}

install_n8n() {
    read -rp "Enter Domain (e.g., n8n.example.com): " DOMAIN
    read -rp "Enter Email for SSL: " EMAIL

    install_dependencies
    create_configs
    create_nginx_config
    issue_ssl
    
    cd "$INSTALL_DIR"
    docker compose up -d
    
    make_global
    echo -e "${GREEN}Installation completed! Access: https://${DOMAIN}${NC}"
    pause
}

show_status() {
    echo -e "${BLUE}--- System Status ---${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$INSTALL_DIR"
        docker compose logs --tail 20 n8n
    fi
}

update_n8n() {
    if [ ! -f "$COMPOSE_FILE" ]; then echo -e "${RED}Not installed.${NC}"; pause; return; fi
    cd "$INSTALL_DIR"
    docker compose pull && docker compose up -d
    echo -e "${GREEN}Successfully updated.${NC}"
    pause
}

remove_n8n() {
    read -rp "Seriously? This will delete EVERYTHING including Database! (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cd "$INSTALL_DIR" && docker compose down -v || true
        rm -rf "$INSTALL_DIR" "$DATA_DIR" "$NGINX_SITE" /etc/nginx/sites-enabled/n8n
        rm -f /usr/local/bin/n8n
        systemctl reload nginx
        echo -e "${GREEN}n8n has been completely removed.${NC}"
    fi
    pause
}

# Main Menu
menu() {
    make_global
    while true; do
        clear
        echo -e "${BLUE}=========================================="
        echo -e "      n8n Manager (PostgreSQL v5)"
        echo -e "      License: GPLv3"
        echo -e "==========================================${NC}"
        echo "1) Install n8n (Postgres Edition)"
        echo "2) Status & Quick Logs"
        echo "3) Update Service"
        echo "4) Remove Everything"
        echo "5) Live Logs (F)"
        echo "0) Exit"
        read -rp "Choice: " choice
        case "$choice" in
            1) install_n8n ;;
            2) show_status; pause ;;
            3) update_n8n ;;
            4) remove_n8n ;;
            5) cd "$INSTALL_DIR" && docker compose logs -f ;;
            0) exit 0 ;;
            *) echo "Invalid."; sleep 1 ;;
        esac
    done
}

menu
