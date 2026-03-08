#!/bin/bash
set -euo pipefail
# mediafusion installer
# STiXzoOR 2026
# Usage: bash mediafusion.sh [--update [--verbose]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

# shellcheck source=lib/debrid-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/debrid-utils.sh" 2>/dev/null || true

# shellcheck source=lib/prowlarr-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/prowlarr-utils.sh" 2>/dev/null || true

# ==============================================================================
# Panel Helper - Download and cache for panel integration
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HELPER_CACHE="/opt/swizzin-extras/panel_helpers.sh"

_load_panel_helper() {
    # Prefer local repo copy (no network dependency, no supply chain risk)
    if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
        . "${SCRIPT_DIR}/panel_helpers.sh"
        return
    fi
    # Fallback to cached copy from a previous repo-based run
    if [[ -f "$PANEL_HELPER_CACHE" ]]; then
        . "$PANEL_HELPER_CACHE"
        return
    fi
    echo_info "panel_helpers.sh not found; skipping panel integration"
}

# ==============================================================================
# Logging
# ==============================================================================
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
        [[ -n "$_systemd_unit_written" ]] && {
            systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
            systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${_systemd_unit_written}"
        }
        [[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
        _reload_nginx 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
    if [[ "$verbose" == "true" ]]; then
        echo_info "  $*"
    fi
}

# ==============================================================================
# App Configuration
# ==============================================================================

app_name="mediafusion"
app_pretty="MediaFusion"
app_lockname="${app_name}"
app_baseurl="${app_name}"

app_dir="/opt/mediafusion"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/mediafusion.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# ==============================================================================
# Port Allocation (4 dynamic ports)
# ==============================================================================
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi

if _existing_pg_port="$(swizdb get "${app_name}/pg_port" 2>/dev/null)" && [[ -n "$_existing_pg_port" ]]; then
    pg_port="$_existing_pg_port"
else
    pg_port=$(port 10000 12000)
fi

if _existing_redis_port="$(swizdb get "${app_name}/redis_port" 2>/dev/null)" && [[ -n "$_existing_redis_port" ]]; then
    redis_port="$_existing_redis_port"
else
    redis_port=$(port 10000 12000)
fi

if _existing_browser_port="$(swizdb get "${app_name}/browser_port" 2>/dev/null)" && [[ -n "$_existing_browser_port" ]]; then
    browser_port="$_existing_browser_port"
else
    browser_port=$(port 10000 12000)
fi

# ==============================================================================
# Docker Installation
# ==============================================================================
_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo_info "Docker and Docker Compose already installed"
        return 0
    fi

    echo_progress_start "Installing Docker"

    apt_install ca-certificates curl gnupg

    # Source os-release once for distro detection
    . /etc/os-release

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$log" 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update >>"$log" 2>&1

    # Use apt-get directly instead of apt_install — Docker's post-install
    # triggers service restarts that Swizzin's apt_install treats as errors
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
        echo_error "Failed to install Docker packages"
        exit 1
    }

    systemctl enable --now docker >>"$log" 2>&1

    # Verify Docker is running
    if ! docker info >/dev/null 2>&1; then
        echo_error "Docker failed to start"
        exit 1
    fi

    echo_progress_done "Docker installed"
}

# ==============================================================================
# Pre-install RAM Check
# ==============================================================================
_check_ram() {
    local total_mem_mb
    total_mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if (( total_mem_mb < 3072 )); then
        echo_warn "System has ${total_mem_mb}MB RAM. MediaFusion recommends 4GB+"
        if ! ask "Continue anyway?" N; then
            exit 0
        fi
    fi
}

# ==============================================================================
# App Installation (5-container compose)
# ==============================================================================
_install_mediafusion() {
    mkdir -p "${app_dir}/pgdata" "${app_dir}/redis"

    # Generate credentials
    local secret_key api_password db_pass server_hostname
    secret_key=$(openssl rand -hex 16)
    api_password=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c -16)
    db_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c -32)
    server_hostname=$(hostname -f)

    # Persist ports in swizdb
    swizdb set "${app_name}/port" "$app_port"
    swizdb set "${app_name}/pg_port" "$pg_port"
    swizdb set "${app_name}/redis_port" "$redis_port"
    swizdb set "${app_name}/browser_port" "$browser_port"

    echo_progress_start "Generating Docker Compose configuration"

    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  mediafusion:
    image: mhdzumair/mediafusion:latest
    container_name: mediafusion
    restart: unless-stopped
    network_mode: host
    environment:
      SECRET_KEY: "${secret_key}"
      API_PASSWORD: "${api_password}"
      POSTGRES_URI: "postgresql+asyncpg://mediafusion:${db_pass}@127.0.0.1:${pg_port}/mediafusion"
      REDIS_URL: "redis://127.0.0.1:${redis_port}"
      HOST_URL: "https://${server_hostname}/mediafusion"
      BROWSERLESS_URL: "http://127.0.0.1:${browser_port}"
    depends_on:
      mediafusion-postgres:
        condition: service_healthy
      mediafusion-redis:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  mediafusion-worker:
    image: mhdzumair/mediafusion:latest
    container_name: mediafusion-worker
    restart: unless-stopped
    network_mode: host
    command: pipenv run dramatiq api.task -p 1 -t 4
    environment:
      SECRET_KEY: "${secret_key}"
      POSTGRES_URI: "postgresql+asyncpg://mediafusion:${db_pass}@127.0.0.1:${pg_port}/mediafusion"
      REDIS_URL: "redis://127.0.0.1:${redis_port}"
      BROWSERLESS_URL: "http://127.0.0.1:${browser_port}"
    depends_on:
      - mediafusion
    deploy:
      resources:
        limits:
          memory: 1G
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  mediafusion-postgres:
    image: postgres:18-alpine
    container_name: mediafusion-postgres
    restart: unless-stopped
    shm_size: 512m
    environment:
      POSTGRES_USER: mediafusion
      POSTGRES_PASSWORD: "${db_pass}"
      POSTGRES_DB: mediafusion
    volumes:
      - ${app_dir}/pgdata:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:${pg_port}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mediafusion"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true

  mediafusion-redis:
    image: redis:7-alpine
    container_name: mediafusion-redis
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    volumes:
      - ${app_dir}/redis:/data
    ports:
      - "127.0.0.1:${redis_port}:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true

  mediafusion-browserless:
    image: ghcr.io/browserless/chromium:latest
    container_name: mediafusion-browserless
    restart: unless-stopped
    environment:
      - TIMEOUT=60000
      - CONCURRENT=2
      - HEALTH=true
    ports:
      - "127.0.0.1:${browser_port}:3000"
    networks:
      - mediafusion-net
    deploy:
      resources:
        limits:
          memory: 1536M
    security_opt:
      - no-new-privileges:true

networks:
  mediafusion-net:
    driver: bridge
COMPOSE

    # Secure compose file (contains credentials)
    chmod 600 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"

    echo_progress_done "Docker Compose configuration generated"

    echo_progress_start "Pulling MediaFusion Docker images (this may take a while)"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker images"
        exit 1
    }
    echo_progress_done "Docker images pulled"

    echo_progress_start "Starting MediaFusion containers"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start containers"
        exit 1
    }
    echo_progress_done "MediaFusion containers started"

    # Store api_password for post-install messaging
    _mediafusion_api_password="${api_password}"
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_mediafusion() {
    echo_progress_start "Installing systemd service"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=MediaFusion (Universal Stremio/Kodi Add-on with Torznab API)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="$app_servicefile"
    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_mediafusion() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"

        cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_port}/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_redirect off;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Longer timeouts for scraper operations
			    proxy_read_timeout 120s;
			    proxy_send_timeout 120s;

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			# Torznab API bypass for Prowlarr
			location ^~ /${app_baseurl}/torznab {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/torznab;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}

			# Manifest endpoint bypass (Stremio needs unauthenticated access)
			location ^~ /${app_baseurl}/manifest.json {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/manifest.json;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

        _nginx_config_written="/etc/nginx/apps/${app_name}.conf"
        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_pretty} will run on port ${app_port}"
    fi
}

# ==============================================================================
# Prowlarr Auto-Configuration
# ==============================================================================
_configure_prowlarr() {
    local torznab_url="http://127.0.0.1:${app_port}/torznab"

    # Always display manual instructions
    if command -v _display_prowlarr_torznab_info >/dev/null 2>&1; then
        _display_prowlarr_torznab_info "MediaFusion" "${torznab_url}" \
            "API Key: ${_mediafusion_api_password:-<see compose file>}"
    fi

    # Attempt auto-configuration if Prowlarr is installed
    if command -v _discover_prowlarr >/dev/null 2>&1; then
        if _discover_prowlarr; then
            _add_prowlarr_torznab "MediaFusion" "${torznab_url}" "${_mediafusion_api_password:-}" || true
        fi
    fi
}

# ==============================================================================
# Post-Install Info
# ==============================================================================
_post_install_info() {
    echo ""
    echo_info "MediaFusion installed with 5 containers"
    echo_warn "Background scrapers are initializing - results may be limited for 30-60 minutes"
    echo ""
    echo_info "Web UI: https://your-server/mediafusion/"
    echo_info "API Password: ${_mediafusion_api_password:-<see compose file>}"
    echo_info "Torznab URL: http://127.0.0.1:${app_port}/torznab"
    echo ""
    echo_info "To manually trigger scrapers, visit the web UI scraper control page"
    echo ""
}

# ==============================================================================
# Update
# ==============================================================================
_update_mediafusion() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    echo_progress_start "Pulling latest ${app_pretty} images"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest images"
        exit 1
    }
    echo_progress_done "Latest images pulled"

    echo_progress_start "Recreating ${app_pretty} containers"
    _verbose "Running: docker compose up -d"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate containers"
        exit 1
    }
    echo_progress_done "Containers recreated"

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_mediafusion() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Ask about purging configuration (skip prompt if --force)
    local purgeconfig
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove all containers
    echo_progress_start "Stopping ${app_pretty} containers"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Containers stopped"

    # Remove all Docker images
    echo_progress_start "Removing Docker images"
    docker rmi mhdzumair/mediafusion:latest >>"$log" 2>&1 || true
    docker rmi postgres:18-alpine >>"$log" 2>&1 || true
    docker rmi redis:7-alpine >>"$log" 2>&1 || true
    docker rmi ghcr.io/browserless/chromium:latest >>"$log" 2>&1 || true
    echo_progress_done "Docker images removed"

    # Remove Docker network
    docker network rm mediafusion-net 2>/dev/null || true

    # Remove systemd service
    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove nginx config
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/${app_name}.conf"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Purge or keep config
    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        swizdb clear "${app_name}/pg_port" 2>/dev/null || true
        swizdb clear "${app_name}/redis_port" 2>/dev/null || true
        swizdb clear "${app_name}/browser_port" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_dir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    # Remove lock file
    rm -f "/install/.${app_lockname}.lock"

    echo_success "${app_pretty} has been removed"
    exit 0
}

# ==============================================================================
# Usage
# ==============================================================================
_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  (no args)             Interactive setup"
    echo "  --update [--verbose]  Pull latest Docker images"
    echo "  --remove [--force]    Complete removal"
    echo "  --register-panel      Re-register with panel"
    exit 1
}

# ==============================================================================
# Main
# ==============================================================================

# Parse global flags
for arg in "$@"; do
    case "$arg" in
        --verbose) verbose=true ;;
    esac
done

case "${1:-}" in
    "--update")
        _update_mediafusion
        ;;
    "--remove")
        _remove_mediafusion "${2:-}"
        ;;
    "--register-panel")
        if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
            echo_error "${app_pretty} is not installed"
            exit 1
        fi
        _load_panel_helper
        if command -v panel_register_app >/dev/null 2>&1; then
            panel_register_app \
                "$app_name" \
                "$app_pretty" \
                "/${app_baseurl}" \
                "" \
                "$app_name" \
                "$app_icon_name" \
                "$app_icon_url" \
                "true"
            systemctl restart panel 2>/dev/null || true
            echo_success "Panel registration updated for ${app_pretty}"
        else
            echo_error "Panel helper not available"
            exit 1
        fi
        exit 0
        ;;
    "")
        # Interactive install (fall through to install logic below)
        ;;
    *)
        _usage
        ;;
esac

# ==============================================================================
# Install Logic
# ==============================================================================
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_info "${app_pretty} is already installed"
else
    _cleanup_needed=true

    # Pre-install RAM check
    _check_ram

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    # Run installation
    _install_docker
    _install_mediafusion
    _systemd_mediafusion
    _nginx_mediafusion
    _configure_prowlarr
    _post_install_info

    # Register with panel
    _load_panel_helper
    if command -v panel_register_app >/dev/null 2>&1; then
        panel_register_app \
            "$app_name" \
            "$app_pretty" \
            "/${app_baseurl}" \
            "" \
            "$app_name" \
            "$app_icon_name" \
            "$app_icon_url" \
            "true"
    fi

    # Create lock file
    touch "/install/.${app_lockname}.lock"
    _lock_file_created="/install/.${app_lockname}.lock"
    _cleanup_needed=false

    echo_success "${app_pretty} installed"
fi
