#!/bin/bash

# Project: n8n Auto-Installer (PostgreSQL) - v1.0.0
# License: GPLv3
# User: im-JvD

set -e

# --- Colors ---
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
RED='\033[1;31m'
PURPLE='\033[1;35m'
PINK='\033[1;38;5;206m'
NC='\033[0m'

# --- Paths ---
INSTALL_DIR="/opt/n8n"
DATA_DIR="/var/lib/n8n"
BACKUP_DIR="/opt/n8n/backup"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
NGINX_SITE="/etc/nginx/sites-available/n8n"
SYSTEMD_FILE="/etc/systemd/system/n8n-docker.service"
SCRIPT_PATH="$(readlink -f "$0")"

make_global() {
    if [[ "$SCRIPT_PATH" != "/usr/local/bin/n8n" ]]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/n8n
        chmod +x /usr/local/bin/n8n
    fi
}

pause() {
    echo
    read -rp " Press Enter to Continue..."
}

install_dependencies() {
    echo -e "${BLUE}	Installing dependencies...${NC}"
    sudo apt update && apt upgrade -y && apt autoremove -y
    apt install -y curl nginx certbot python3-certbot-nginx ca-certificates openssl zip unzip
    
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${BLUE}	Installing Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
    systemctl enable --now nginx
}

# New function for Systemd persistence
create_systemd_service() {
    echo -e "${BLUE}	Creating systemd service for persistence...${NC}"
    cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=n8n Docker Compose Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable n8n-docker
}

create_configs() {
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR/postgres"
    mkdir -p "$DATA_DIR/data"
    mkdir -p "$BACKUP_DIR"
    
    chown -R 1000:1000 "$DATA_DIR/data"
    chmod -R 755 "$DATA_DIR/data"
    chown -R 999:999 "$DATA_DIR/postgres"
    chmod -R 700 "$DATA_DIR/postgres"

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
    echo -e "${BLUE}	Requesting SSL certificate...${NC}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
}

show_status_and_logs() {
    clear
    echo -e "${PURPLE}================ SYSTEM STATUS =================${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo -e "${PURPLE}================================================${NC}"
    echo
    echo -e "${YELLOW}↓↓↓ LIVE LOGS (Last 50 lines) ↓↓↓${NC}"
    echo -e "${PINK}Press CTRL+C to return${NC}"
    echo
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$INSTALL_DIR"
        docker compose logs -f --tail 50
    else
        echo -e "${RED}Error: n8n not installed.${NC}"
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
    create_systemd_service # Enable at boot
    cd "$INSTALL_DIR"
    systemctl start n8n-docker
    make_global
    echo -e "${GREEN}	Installation completed!${NC}"
	docker compose logs -f --tail 10
}

update_n8n() {
    if [ ! -f "$COMPOSE_FILE" ]; then echo -e "${RED}Not installed.${NC}"; pause; return; fi
    echo -e "${BLUE}	Updating n8n...${NC}"
    cd "$INSTALL_DIR"
    docker compose pull && docker compose up -d
    echo -e "$	{GREEN}N8N Service has Updated.${NC}"
    echo ""
	docker compose logs -f --tail 10
    echo ""
}

backup_restore_menu() {
    while true; do
        clear
        echo ""
        echo -e "Github Page : ${PURPLE} https://github.com/im-JvD/n8n-installer${NC}"
        echo ""
        echo -e "   =========================================="
        echo -e "   ${BLUE}      N8N Manager ${NC}( ${GREEN}PostgreSQL${NC} )"
        echo -e "   ${NC}             Version ${GREEN}1.0.0${NC}"
        echo -e "   =========================================="
        echo ""
        echo -e "	${NC}1 - ${YELLOW}Create ${GREEN}Full Backup"
        echo -e "	${NC}2 - ${YELLOW}Restore ${GREEN}Full Backup"
        echo ""
        echo -e "      ${NC}0 - Back to Management Menu"
        echo ""
        read -rp "   Choice: " br_choice

        if [ ! -f "$ENV_FILE" ]; then
            echo -e "${RED}Error: .env file not found.${NC}"
            pause
            return
        fi

        case "$br_choice" in
            1)
                local timestamp backup_name stage_dir

                timestamp=$(date +%Y%m%d_%H%M%S)
                backup_name="n8n_full_backup_${timestamp}.zip"
                stage_dir=$(mktemp -d "/tmp/n8n_backup_${timestamp}_XXXXXX")

                echo -e "${BLUE}→ Exporting PostgreSQL database...${NC}"

                set -a
                source "$ENV_FILE"
                set +a

                if ! docker exec n8n-db pg_dump \
                    --no-owner \
                    --no-privileges \
                    -U "$POSTGRES_USER" \
                    "$POSTGRES_DB" > "$stage_dir/database.sql"; then
                    echo -e "${RED}Database backup failed. No backup was created.${NC}"
                    rm -rf "$stage_dir"
                    pause
                    return
                fi

                echo -e "${BLUE}→ Collecting n8n configuration and application data...${NC}"
                mkdir -p "$stage_dir/config" "$stage_dir/app_data"

                cp -a "$ENV_FILE" "$stage_dir/config/.env"
                cp -a "$COMPOSE_FILE" "$stage_dir/config/docker-compose.yml"

                if [ -f "$NGINX_SITE" ]; then
                    cp -a "$NGINX_SITE" "$stage_dir/config/nginx-n8n.conf"
                fi

                cp -a "$DATA_DIR/data/." "$stage_dir/app_data/"

                cat > "$stage_dir/backup-info.txt" <<EOF
n8n Full Backup
Created: $(date -Is)
Database: ${POSTGRES_DB}
Format: SQL dump + n8n application data + configuration
EOF

                echo -e "${BLUE}→ Compressing backup...${NC}"
                (
                    cd "$stage_dir"
                    zip -qr "$BACKUP_DIR/$backup_name" .
                )

                rm -rf "$stage_dir"

                echo -e "${GREEN}Backup created:${NC} $BACKUP_DIR/$backup_name"
                echo -e "${YELLOW}Note: PostgreSQL physical data is intentionally excluded.${NC}"
                pause
                ;;

            2)
                if [ ! -d "$BACKUP_DIR" ]; then
                    echo -e "${RED}Backup directory not found.${NC}"
                    pause
                    return
                fi

                mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.zip' | sort -r)

                if [ "${#backups[@]}" -eq 0 ]; then
                    echo -e "${YELLOW}No backup files found.${NC}"
                    pause
                    return
                fi

                echo ""
                echo -e "${YELLOW}Available Backups:${NC}"
                echo ""
                for i in "${!backups[@]}"; do
                    printf "%s) %s\n" "$((i+1))" "$(basename "${backups[$i]}")"
                done

                echo
                read -rp "Select backup number to restore: " backup_number

                if ! [[ "$backup_number" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Invalid selection.${NC}"
                    pause
                    return
                fi

                if [ "$backup_number" -lt 1 ] || [ "$backup_number" -gt "${#backups[@]}" ]; then
                    echo -e "${RED}Invalid selection.${NC}"
                    pause
                    return
                fi

                zip_file="$(basename "${backups[$((backup_number-1))]}")"

                echo
                echo -e "${RED}WARNING: This replaces n8n files and recreates PostgreSQL from the SQL dump.${NC}"
                read -rp "Type RESTORE to continue: " confirm_restore

                if [ "$confirm_restore" != "RESTORE" ]; then
                    echo -e "${YELLOW}Restore cancelled.${NC}"
                    pause
                    return
                fi

                local restore_dir dump_file restore_config restore_app_data
                restore_dir=$(mktemp -d "/tmp/n8n_restore_XXXXXX")

                echo -e "${BLUE}→ Validating and extracting backup...${NC}"

                if unzip -Z1 "$BACKUP_DIR/$zip_file" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
                    echo -e "${RED}Unsafe backup archive detected. Restore cancelled.${NC}"
                    rm -rf "$restore_dir"
                    pause
                    return
                fi

                unzip -q "$BACKUP_DIR/$zip_file" -d "$restore_dir"

                # New backup format.
                if [ -f "$restore_dir/database.sql" ]; then
                    dump_file="$restore_dir/database.sql"
                    restore_config="$restore_dir/config"
                    restore_app_data="$restore_dir/app_data"

                # Compatibility with the old v1.0.0 archive structure.
                elif [ -f "$restore_dir/tmp/db_dump.sql" ]; then
                    dump_file="$restore_dir/tmp/db_dump.sql"
                    restore_config="$restore_dir/opt/n8n"
                    restore_app_data="$restore_dir/var/lib/n8n/data"
                else
                    echo -e "${RED}No valid database.sql file was found in this archive.${NC}"
                    rm -rf "$restore_dir"
                    pause
                    return
                fi

                if [ ! -f "$restore_config/.env" ] || \
                   [ ! -f "$restore_config/docker-compose.yml" ] || \
                   [ ! -d "$restore_app_data" ]; then
                    echo -e "${RED}Backup is incomplete: config or n8n data is missing.${NC}"
                    rm -rf "$restore_dir"
                    pause
                    return
                fi

                echo -e "${BLUE}→ Stopping containers...${NC}"
                cd "$INSTALL_DIR"
                docker compose down || true

                echo -e "${BLUE}→ Restoring configuration and n8n application data...${NC}"
                mkdir -p "$INSTALL_DIR" "$DATA_DIR/data"

                cp -f "$restore_config/.env" "$ENV_FILE"
                cp -f "$restore_config/docker-compose.yml" "$COMPOSE_FILE"

                if [ -f "$restore_config/nginx-n8n.conf" ]; then
                    cp -f "$restore_config/nginx-n8n.conf" "$NGINX_SITE"
                    nginx -t && systemctl reload nginx
                fi

                rm -rf "$DATA_DIR/data"
                mkdir -p "$DATA_DIR/data"
                cp -a "$restore_app_data/." "$DATA_DIR/data/"

                chown -R 1000:1000 "$DATA_DIR/data"
                chmod -R u+rwX,go-rwx "$DATA_DIR/data"

                echo -e "${BLUE}→ Recreating PostgreSQL data directory...${NC}"
                rm -rf "$DATA_DIR/postgres"
                mkdir -p "$DATA_DIR/postgres"
                chown -R 999:999 "$DATA_DIR/postgres"
                chmod 700 "$DATA_DIR/postgres"

                set -a
                source "$ENV_FILE"
                set +a

                echo -e "${BLUE}→ Starting a fresh PostgreSQL instance...${NC}"
                cd "$INSTALL_DIR"
                docker compose up -d db

                echo -e "${BLUE}→ Waiting for PostgreSQL...${NC}"
                local db_ready=false
                for _ in $(seq 1 30); do
                    if docker exec n8n-db pg_isready \
                        -U "$POSTGRES_USER" \
                        -d "$POSTGRES_DB" >/dev/null 2>&1; then
                        db_ready=true
                        break
                    fi
                    sleep 2
                done

                if [ "$db_ready" != true ]; then
                    echo -e "${RED}PostgreSQL did not become ready. Check: docker logs n8n-db${NC}"
                    rm -rf "$restore_dir"
                    pause
                    return
                fi

                echo -e "${BLUE}→ Importing database SQL dump...${NC}"
                if ! docker exec -i n8n-db psql \
                    -v ON_ERROR_STOP=1 \
                    -U "$POSTGRES_USER" \
                    -d "$POSTGRES_DB" < "$dump_file"; then
                    echo -e "${RED}Database import failed. Services remain stopped for inspection.${NC}"
                    rm -rf "$restore_dir"
                    pause
                    return
                fi

                echo -e "${BLUE}→ Starting n8n...${NC}"
                docker compose up -d --force-recreate

                rm -rf "$restore_dir"

                echo -e "${GREEN}N8N System restore completed successfully.${NC}"
				echo ""
                echo -e "${YELLOW}Use Status & Live Logs to verify startup.${NC}"
				echo ""
				docker compose logs -f --tail 10
				echo ""
                ;;

            0)
                return
                ;;

            *)
                echo -e "${RED}Invalid selection.${NC}"
                pause
                ;;
        esac
    done
}

remove_n8n() {
    echo -e "${RED}	WARNING : Delete EVERYTHING?${NC}"
    read -rp "Type 'DELETE': " confirm
    if [[ "$confirm" == "DELETE" ]]; then
        systemctl stop n8n-docker
        systemctl disable n8n-docker
        rm -f "$SYSTEMD_FILE"
        systemctl daemon-reload
        cd "$INSTALL_DIR" && docker compose down -v || true
        rm -rf "$INSTALL_DIR" "$DATA_DIR" "$NGINX_SITE" /etc/nginx/sites-enabled/n8n /usr/local/bin/n8n
        systemctl reload nginx
        echo -e "${GREEN}Removed.${NC}"
    fi
    pause
}

# --- Management Sub-Menu ---
management_sub_menu() {
    while true; do
        clear
        echo ""
        echo -e "Github Page : ${PURPLE} https://github.com/im-JvD/n8n-installer${NC}"
        echo ""
        echo -e "   =========================================="
        echo -e "   ${BLUE}      N8N Manager ${NC}( ${GREEN}PostgreSQL${NC} )"
        echo -e "   ${NC}             Version ${GREEN}1.0.0${NC}"
        echo -e "   =========================================="
        echo ""
        echo -e "	${NC}1 - ${YELLOW}Restart Service"
        echo -e "	${NC}2 - ${GREEN}Backup${NC} & ${RED}Restore${NC}"
        echo -e "	${NC}3 - ${GREEN}Status${NC} & ${GREEN}Live${NC} Logs"
        echo ""
        echo -e "      ${NC}0 - ${NC}Back"
        echo ""
        read -rp "   Choice: " m_choice
        case "$m_choice" in
            1) 
                cd "$INSTALL_DIR" && docker compose up -d --force-recreate
				echo ""
                echo -e "${GREEN}	N8N Service Restarted.${NC}"; pause ;;
				echo ""
				docker compose logs -f --tail 10
				echo ""
            2) backup_restore_menu ;;
            3) show_status_and_logs ;;
            0) break ;;
        esac
    done
}

# --- Main Menu ---
menu() {
    make_global
    while true; do
        clear
        echo ""
        echo -e "Github Page : ${PURPLE} https://github.com/im-JvD/n8n-installer${NC}"
        echo ""
        echo -e "   =========================================="
        echo -e "   ${BLUE}      N8N Manager ${NC}( ${GREEN}PostgreSQL${NC} )"
        echo -e "   ${NC}             Version ${GREEN}1.0.0${NC}"
        echo -e "   =========================================="
        echo ""
        echo -e "	${NC}1 - ${GREEN}Installing ${NC}N8N Service"
        echo -e "	${NC}2 - ${YELLOW}Management ${NC}N8N Service"
        echo -e "	${NC}3 - ${GREEN}Update ${NC}Service"
        echo -e "	${NC}4 - ${RED}Remove ${NC}Everything"
        echo ""
        echo -e "      ${NC}0 - ${NC}Exit"
        echo ""
        echo -e "   ==================="
        echo ""
        read -rp "   Choice: " choice
        case "$choice" in
            1) install_n8n ;;
            2) management_sub_menu ;;
            3) update_n8n ;;
            4) remove_n8n ;;
            0) exit 0 ;;
        esac
    done
}

menu
