#!/bin/bash

# Project: n8n Auto-Installer (PostgreSQL Edition)
# License: GPLv3
# Author: Your Name/Organization

set -e

# Professional Terminal Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
LIGHT_PURPLE='\033[1;35m'
PINK='\033[38;5;206m'
RED='\033[0;31m'
NC='\033[0m'

# Paths
INSTALL_DIR="/opt/n8n"
DATA_DIR="/var/lib/n8n"
BACKUP_DIR="$INSTALL_DIR/backup"
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

fix_permissions() {
    echo -e "${LIGHT_PURPLE}Applying directory permissions...${NC}"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR/postgres"
    mkdir -p "$DATA_DIR/data"
    mkdir -p "$BACKUP_DIR"

    # n8n ownership (uid/gid 1000)
    chown -R 1000:1000 "$DATA_DIR/data"
    chmod -R 755 "$DATA_DIR/data"

    # postgres ownership (uid/gid 999)
    chown -R 999:999 "$DATA_DIR/postgres"
    chmod -R 700 "$DATA_DIR/postgres"
    
    # Backups ownership
    chown -R root:root "$BACKUP_DIR"
    chmod -R 700 "$BACKUP_DIR"
}

install_dependencies() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    apt update && apt upgrade -y
    apt install -y curl nginx certbot python3-certbot-nginx ca-certificates openssl zip unzip

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${BLUE}Installing Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
    systemctl enable --now nginx
}

create_configs() {
    fix_permissions

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

show_live_status_logs() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}n8n is not installed yet.${NC}"
        pause
        return
    fi

    clear
    echo -e "${PINK}=========================================="
    echo -e "         n8n Status & Live Logs"
    echo -e "==========================================${NC}"
    echo -e "${BLUE}--- Container Status ---${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo
    echo -e "${YELLOW}Showing live logs. Press CTRL+C to return to main menu.${NC}"
    echo -e "${PINK}------------------------------------------------------${NC}"
    sleep 1

    # Intercept Ctrl+C to return smoothly to menu
    trap 'echo; echo -e "${GREEN}Returning to main menu...${NC}"; sleep 1; return' INT

    cd "$INSTALL_DIR"
    docker compose logs -f --tail 50 n8n-app n8n-db
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
    echo -e "${GREEN}Installation completed! Starting live logs monitor...${NC}"
    sleep 2
    show_live_status_logs
}

update_n8n() {
    if [ ! -f "$COMPOSE_FILE" ]; then echo -e "${RED}Not installed.${NC}"; pause; return; fi
    fix_permissions
    cd "$INSTALL_DIR"
    docker compose pull && docker compose up -d
    echo -e "${GREEN}Successfully updated.${NC}"
    pause
}

backup_database() {
    echo -e "${BLUE}Starting Database Backup...${NC}"
    mkdir -p "$BACKUP_DIR"
    
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="$BACKUP_DIR/n8n_db_backup_$TIMESTAMP.sql"
    ZIP_FILE="$BACKUP_DIR/n8n_db_backup_$TIMESTAMP.zip"

    # Export Postgres Database using pg_dump inside docker
    if docker exec n8n-db pg_dump -U n8n_admin -d n8n_db > "$BACKUP_FILE"; then
        zip -j "$ZIP_FILE" "$BACKUP_FILE"
        rm -f "$BACKUP_FILE"
        echo -e "${GREEN}Backup created successfully:${NC} $ZIP_FILE"
    else
        echo -e "${RED}Database backup failed! Make sure containers are running.${NC}"
    fi
    pause
}

restore_database() {
    echo -e "${BLUE}Starting Database Restore...${NC}"
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.zip 2>/dev/null)" ]; then
        echo -e "${RED}No zip backup files found in $BACKUP_DIR${NC}"
        pause
        return
    fi

    echo -e "${YELLOW}Available Backups:${NC}"
    select FILE in "$BACKUP_DIR"/*.zip; do
        if [ -n "$FILE" ]; then
            echo -e "${LIGHT_PURPLE}Selected backup:${NC} $FILE"
            read -rp "Are you sure you want to restore? This will overwrite the current database! (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # Temporary unzip
                unzip -o "$FILE" -d "/tmp"
                SQL_FILE=$(find /tmp -name "*.sql" | head -n 1)

                if [ -f "$SQL_FILE" ]; then
                    echo -e "${YELLOW}Stopping n8n application to prevent write conflicts...${NC}"
                    cd "$INSTALL_DIR" && docker compose stop n8n

                    echo -e "${BLUE}Restoring database...${NC}"
                    # Recreate clean DB
                    docker exec -i n8n-db dropdb -U n8n_admin --if-exists n8n_db
                    docker exec -i n8n-db createdb -U n8n_admin n8n_db
                    # Import database
                    docker exec -i n8n-db psql -U n8n_admin -d n8n_db < "$SQL_FILE"
                    
                    rm -f "$SQL_FILE"
                    
                    echo -e "${YELLOW}Starting n8n application...${NC}"
                    docker compose start n8n
                    echo -e "${GREEN}Database successfully restored!${NC}"
                else
                    echo -e "${RED}Failed to extract SQL file from ZIP archive.${NC}"
                fi
            else
                echo -e "${YELLOW}Restore canceled.${NC}"
            fi
            break
        else
            echo -e "${RED}Invalid selection.${NC}"
        fi
    done
    pause
}

backup_restore_menu() {
    while true; do
        clear
        echo -e "${LIGHT_PURPLE}=========================================="
        echo -e "       Database Backup & Restore"
        echo -e "==========================================${NC}"
        echo -e "1) ${GREEN}Create New Database Backup (ZIP)${NC}"
        echo -e "2) ${YELLOW}Restore Database from Backup (ZIP)${NC}"
        echo -e "0) Return to Main Menu"
        echo -e "${LIGHT_PURPLE}==========================================${NC}"
        read -rp "Choice: " subchoice
        case "$subchoice" in
            1) backup_database ;;
            2) restore_database ;;
            0) break ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

remove_n8n() {
    read -rp "Seriously? This will delete EVERYTHING including Database & Volumes! (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cd "$INSTALL_DIR" && docker compose down -v || true
        rm -rf "$INSTALL_DIR" "$DATA_DIR" "$NGINX_SITE" /etc/nginx/sites-enabled/n8n
        rm -f /usr/local/bin/n8n
        systemctl reload nginx
        echo -e "${GREEN}n8n has been completely removed from system.${NC}"
    fi
    pause
}

# Main Menu
menu() {
    make_global
    while true; do
        # Clear any active traps to ensure smooth menu navigation
        trap - INT
        clear
        echo -e "${PINK}=========================================="
        echo -e "      n8n Manager (PostgreSQL v5)"
        echo -e "      License: GPLv3"
        echo -e "==========================================${NC}"
        echo -e "1) ${GREEN}Install & Configure n8n Service${NC}"
        echo -e "2) ${BLUE}System Status & Live Logs${NC}"
        echo -e "3) ${YELLOW}Update n8n Service${NC}"
        echo -e "4) ${LIGHT_PURPLE}Backup & Restore Manager${NC}"
        echo -e "5) ${RED}Remove Everything Completely${NC}"
        echo -e "0) Exit"
        echo -e "${PINK}==========================================${NC}"
        read -rp "Choice [0-5]: " choice
        case "$choice" in
            1) install_n8n ;;
            2) show_live_status_logs ;;
            3) update_n8n ;;
            4) backup_restore_menu ;;
            5) remove_n8n ;;
            0) exit 0 ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

menu
