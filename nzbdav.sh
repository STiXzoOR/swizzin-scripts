#!/bin/bash
set -euo pipefail
# nzbdav installer
# STiXzoOR 2026
# Usage: bash nzbdav.sh [--update [--verbose]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

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

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_systemd_unit_written=""
_lock_file_created=""
app_mount_point=""

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
        # FUSE unmount cleanup
        if [[ -n "$app_mount_point" ]] && mountpoint -q "${app_mount_point}" 2>/dev/null; then
            fusermount -uz "${app_mount_point}" 2>/dev/null || true
        fi
        rm -f "/etc/systemd/system/rclone-nzbdav.service" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
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

app_name="nzbdav"
app_pretty="NZBDav"
app_lockname="${app_name}"
app_baseurl="${app_name}"
app_image="nzbdav/nzbdav:latest"
app_dir="/opt/nzbdav"
app_configdir="${app_dir}/config"
app_servicefile="${app_name}.service"
app_mount_servicefile="rclone-nzbdav.service"
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/nzbdav.png"
app_default_mount="/mnt/nzbdav"
app_reqs=("curl" "fuse3")

# ==============================================================================
# User/Owner Setup
# ==============================================================================
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
    app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Port persistence - read existing port from swizdb, allocate only on fresh install
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
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
# rclone Installation
# ==============================================================================
_install_rclone() {
    if command -v rclone &>/dev/null; then
        local current_version
        current_version=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
        echo_info "rclone $current_version already installed"
        return 0
    fi

    echo_progress_start "Installing rclone"
    # The official install script may return non-zero if already latest
    curl -fsSL https://rclone.org/install.sh | bash >>"$log" 2>&1 || true

    # Verify rclone is now available
    if command -v rclone &>/dev/null; then
        echo_progress_done "rclone installed: $(rclone version 2>/dev/null | head -1 | awk '{print $2}')"
    else
        echo_error "Failed to install rclone"
        exit 1
    fi
}

# ==============================================================================
# FUSE Configuration
# ==============================================================================
_configure_fuse() {
    if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
        echo "user_allow_other" >>/etc/fuse.conf
    fi
}

# ==============================================================================
# Mount Point Configuration
# ==============================================================================
_get_mount_point() {
    # Skip if already set
    if [[ -n "$app_mount_point" ]]; then
        echo_info "Using mount point: $app_mount_point"
        return
    fi

    # Check environment variable first
    if [[ -n "${NZBDAV_MOUNT_PATH:-}" ]]; then
        echo_info "Using mount point from NZBDAV_MOUNT_PATH: $NZBDAV_MOUNT_PATH"
        app_mount_point="$NZBDAV_MOUNT_PATH"
        return
    fi

    # Check existing config in swizdb
    local existing_mount
    existing_mount=$(swizdb get "${app_name}/mount_point" 2>/dev/null) || true

    local default_mount="${existing_mount:-$app_default_mount}"

    echo_query "Enter NZBDav mount point" "[$default_mount]"
    read -r input_mount </dev/tty

    if [[ -z "$input_mount" ]]; then
        app_mount_point="$default_mount"
    else
        # Validate absolute path
        if [[ ! "$input_mount" = /* ]]; then
            echo_error "Mount point must be an absolute path (start with /)"
            exit 1
        fi
        app_mount_point="$input_mount"
    fi

    echo_info "Using mount point: $app_mount_point"
}

# ==============================================================================
# Docker Compose / Container
# ==============================================================================
_install_nzbdav() {
    mkdir -p "$app_configdir"
    chmod 700 "$app_configdir"

    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    # Persist port in swizdb
    swizdb set "${app_name}/port" "$app_port"

    echo_progress_start "Generating Docker Compose configuration"

    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  nzbdav:
    image: ${app_image}
    container_name: nzbdav
    restart: unless-stopped
    ports:
      - "127.0.0.1:${app_port}:3000"
    environment:
      - PUID=${uid}
      - PGID=${gid}
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ${app_configdir}:/config
      - /mnt:/mnt:rslave
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 1m
      timeout: 5s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
COMPOSE

    echo_progress_done "Docker Compose configuration generated"
    chmod 600 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"

    echo_progress_start "Pulling ${app_pretty} Docker image"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting ${app_pretty} container"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "${app_pretty} container started"
}

# ==============================================================================
# Systemd Services
# ==============================================================================
_systemd_nzbdav() {
    echo_progress_start "Installing systemd service for Docker container"

    cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (WebDAV server for Usenet streaming)
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

[Install]
WantedBy=multi-user.target
EOF

    _systemd_unit_written="${app_servicefile}"
    systemctl -q daemon-reload
    systemctl enable -q "${app_servicefile}"
    echo_progress_done "Docker systemd service installed and enabled"
}

_systemd_rclone_nzbdav() {
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    echo_progress_start "Installing rclone mount systemd service"

    cat >"/etc/systemd/system/${app_mount_servicefile}" <<EOF
[Unit]
Description=rclone NZBDav WebDAV mount
After=nzbdav.service
Requires=nzbdav.service

[Service]
Type=notify
User=${user}
Group=${user}
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do curl -sf http://127.0.0.1:${app_port}/health && exit 0; sleep 2; done; echo "NZBDav health check timed out after 60s"; exit 1'
ExecStart=/usr/bin/rclone mount nzbdav: ${app_mount_point} \
    --config ${app_dir}/rclone.conf \
    --uid ${uid} --gid ${gid} \
    --allow-other \
    --links \
    --use-cookies \
    --vfs-cache-mode full \
    --buffer-size 0M \
    --vfs-read-ahead 512M \
    --vfs-cache-max-size 20G \
    --vfs-cache-max-age 24h \
    --dir-cache-time 20s
ExecStop=/bin/fusermount -uz ${app_mount_point}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    echo_progress_done "rclone mount systemd service installed (not yet enabled)"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_nzbdav() {
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

			    # Disable upstream compression so sub_filter can rewrite
			    proxy_set_header Accept-Encoding "";

			    # Rewrite URLs in responses (NZBDav has no base URL support)
			    sub_filter_once off;
			    sub_filter_types text/html text/css text/javascript application/javascript application/json;
			    sub_filter 'href="/' 'href="/${app_baseurl}/';
			    sub_filter 'src="/' 'src="/${app_baseurl}/';
			    sub_filter 'action="/' 'action="/${app_baseurl}/';
			    sub_filter 'url(/' 'url(/${app_baseurl}/';
			    sub_filter '"/api/' '"/${app_baseurl}/api/';
			    sub_filter "'/api/" "'/${app_baseurl}/api/";
			    sub_filter 'fetch("/' 'fetch("/${app_baseurl}/';
			    sub_filter "fetch('/" "fetch('/${app_baseurl}/";

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			# SABnzbd API bypass - NZBDav's own API key provides authentication
			location ^~ /${app_baseurl}/api {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/api;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
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
# rclone Setup (deferred — requires NZBDav web UI configuration first)
# ==============================================================================
_setup_rclone() {
    echo_info "Setting up rclone WebDAV mount for ${app_pretty}..."

    # Get or confirm mount point
    _get_mount_point
    swizdb set "${app_name}/mount_point" "$app_mount_point"

    # Prompt for WebDAV password
    echo_query "Enter NZBDav WebDAV password (configured in the web UI)"
    read -rs webdav_pass </dev/tty
    echo ""

    if [[ -z "$webdav_pass" ]]; then
        echo_error "WebDAV password cannot be empty"
        exit 1
    fi

    # Obscure the password for rclone config
    echo_progress_start "Obscuring WebDAV password"
    local obscured
    obscured=$(echo "$webdav_pass" | rclone obscure -) || {
        echo_error "Failed to obscure password"
        exit 1
    }
    echo_progress_done "Password obscured"

    # Write rclone.conf with restricted permissions
    echo_progress_start "Writing rclone configuration"
    (
        umask 077
        cat >"${app_dir}/rclone.conf" <<RCLONE
[nzbdav]
type = webdav
url = http://127.0.0.1:${app_port}/
vendor = other
user = admin
pass = ${obscured}
RCLONE
    )
    chown "${user}:${user}" "${app_dir}/rclone.conf"
    echo_progress_done "rclone configuration written"

    # Create mount point
    if [[ ! -d "$app_mount_point" ]]; then
        mkdir -p "$app_mount_point"
    fi
    chown "${user}:${user}" "$app_mount_point"

    # Write (or update) rclone mount systemd service
    _systemd_rclone_nzbdav

    # Enable and start rclone mount
    echo_progress_start "Starting rclone mount"
    systemctl enable --now -q "${app_mount_servicefile}"
    echo_progress_done "rclone mount started"

    echo ""
    echo_success "rclone WebDAV mount configured and started"
    echo_info "Mount point: $app_mount_point"
    echo_info "rclone config: ${app_dir}/rclone.conf"
}

# ==============================================================================
# Post-Install Messaging
# ==============================================================================
_post_install_message() {
    echo ""
    echo_info "============================================"
    echo_info " ${app_pretty} First-Run Setup"
    echo_info "============================================"
    echo ""
    echo_info "1. Open the NZBDav web UI at: https://your-server/${app_baseurl}/"
    echo_info "2. Configure your Usenet provider and WebDAV password"
    echo_info "3. Re-run this script to set up the rclone mount:"
    echo_info "     bash ${SCRIPT_DIR}/${app_name}.sh"
    echo ""
    echo_info "The rclone mount service has been created but NOT enabled."
    echo_info "It will be enabled when you re-run after configuring the web UI."
    echo ""
    echo_info "SABnzbd API URL (from inside Docker):"
    echo_info "  http://host.docker.internal:PORT/sabnzbd/api"
    echo ""
    echo_info "Arr connection (from inside Docker):"
    echo_info "  http://host.docker.internal:PORT"
    echo ""
}

# ==============================================================================
# Fresh Install
# ==============================================================================
_install_fresh() {
    _cleanup_needed=true

    # Install dependencies
    apt_install "${app_reqs[@]}"

    # Set owner in swizdb
    echo_info "Setting ${app_pretty} owner = ${user}"
    swizdb set "${app_name}/owner" "$user"

    # Get mount point for later rclone setup
    _get_mount_point
    swizdb set "${app_name}/mount_point" "$app_mount_point"

    _install_docker
    _install_rclone
    _configure_fuse
    _install_nzbdav
    _systemd_nzbdav

    # Create rclone mount systemd service (but do NOT enable — deferred setup)
    _systemd_rclone_nzbdav

    _nginx_nzbdav

    # Panel registration
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

    touch "/install/.${app_lockname}.lock"
    _lock_file_created="/install/.${app_lockname}.lock"
    _cleanup_needed=false

    echo_success "${app_pretty} installed"
    _post_install_message
}

# ==============================================================================
# Update
# ==============================================================================
_update_nzbdav() {
    if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed"
        exit 1
    fi

    echo_info "Updating ${app_pretty}..."

    # Save rclone mount state before update
    local rclone_was_active
    rclone_was_active=$(systemctl is-active "${app_mount_servicefile}" 2>/dev/null) || rclone_was_active="inactive"

    # Stop rclone mount first (unmount before stopping backend)
    if [[ "$rclone_was_active" == "active" ]]; then
        echo_progress_start "Stopping rclone mount"
        systemctl stop "${app_mount_servicefile}" 2>/dev/null || true
        echo_progress_done "rclone mount stopped"
    fi

    echo_progress_start "Pulling latest ${app_pretty} image"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    echo_progress_start "Recreating ${app_pretty} container"
    _verbose "Running: docker compose up -d"
    docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    # Restart rclone mount if it was active
    if [[ "$rclone_was_active" == "active" ]]; then
        echo_progress_start "Restarting rclone mount"
        systemctl start "${app_mount_servicefile}" 2>/dev/null || true
        echo_progress_done "rclone mount restarted"
    fi

    # Clean up old dangling images
    _verbose "Pruning unused images"
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_pretty} has been updated"
    exit 0
}

# ==============================================================================
# Remove
# ==============================================================================
_remove_nzbdav() {
    local force="${1:-}"

    if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
        echo_error "${app_pretty} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_pretty}..."

    # Get mount point from swizdb (needed for unmounting)
    app_mount_point=$(swizdb get "${app_name}/mount_point" 2>/dev/null) || app_mount_point="$app_default_mount"

    # Ask about purging configuration (skip prompt if --force)
    if [[ "$force" == "--force" ]]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # 1. Stop rclone mount FIRST (unmount before stopping backend)
    if [[ -f "/etc/systemd/system/${app_mount_servicefile}" ]]; then
        echo_progress_start "Stopping rclone mount service"
        systemctl stop "${app_mount_servicefile}" 2>/dev/null || true
        systemctl disable "${app_mount_servicefile}" 2>/dev/null || true
        echo_progress_done "rclone mount service stopped"
    fi

    # 2. Cleanup stale FUSE mount
    if mountpoint -q "$app_mount_point" 2>/dev/null; then
        echo_progress_start "Unmounting ${app_mount_point}"
        fusermount -uz "$app_mount_point" 2>/dev/null || umount -f "$app_mount_point" 2>/dev/null || true
        echo_progress_done "Unmounted"
    fi

    # 3. Stop Docker container
    echo_progress_start "Stopping ${app_pretty} container"
    if [[ -f "${app_dir}/docker-compose.yml" ]]; then
        docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
    fi
    echo_progress_done "Container stopped"

    # Remove Docker image
    echo_progress_start "Removing Docker image"
    docker rmi "${app_image}" >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    # 4. Remove both systemd services
    echo_progress_start "Removing systemd services"
    systemctl stop "${app_servicefile}" 2>/dev/null || true
    systemctl disable "${app_servicefile}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${app_servicefile}"
    rm -f "/etc/systemd/system/${app_mount_servicefile}"
    systemctl daemon-reload
    echo_progress_done "Services removed"

    # 5. Remove nginx config
    if [[ -f "/etc/nginx/apps/${app_name}.conf" ]]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/${app_name}.conf"
        _reload_nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    # 6. Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # 7. Purge or keep config
    if [[ "$purgeconfig" = "true" ]]; then
        echo_progress_start "Purging configuration and data"
        # Remove rclone VFS cache
        local vfs_cache="/home/${user}/.cache/rclone/vfs/nzbdav"
        if [[ -d "$vfs_cache" ]]; then
            local cache_size
            cache_size=$(du -sh "$vfs_cache" 2>/dev/null | cut -f1) || cache_size="unknown"
            rm -rf "$vfs_cache"
            echo_info "Cleared VFS cache ($cache_size freed)"
        fi
        # Remove app directory (config, rclone.conf, docker-compose.yml)
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "${app_name}/owner" 2>/dev/null || true
        swizdb clear "${app_name}/port" 2>/dev/null || true
        swizdb clear "${app_name}/mount_point" 2>/dev/null || true
    else
        echo_info "Configuration kept at: ${app_configdir}"
        rm -f "${app_dir}/docker-compose.yml"
    fi

    # Remove mount point directory if empty
    if [[ -d "$app_mount_point" ]]; then
        rmdir "$app_mount_point" 2>/dev/null || true
    fi

    # 8. Remove lock file
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
    echo "  (no args)             Install / re-run to set up rclone mount"
    echo "  --update [--verbose]  Pull latest Docker image"
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
        _update_nzbdav
        ;;
    "--remove")
        _remove_nzbdav "${2:-}"
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
        # Default: install or re-run
        if [[ -f "/install/.${app_lockname}.lock" ]]; then
            # Re-run: check if rclone needs setup
            if [[ ! -f "${app_dir}/rclone.conf" ]]; then
                _setup_rclone
            else
                echo_info "${app_pretty} already installed, restarting services"
                systemctl restart "${app_servicefile}" 2>/dev/null || true
                systemctl restart "${app_mount_servicefile}" 2>/dev/null || true
            fi

            # Re-register panel on every re-run
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
            exit 0
        fi

        # Fresh install
        _install_fresh
        ;;
    *)
        _usage
        ;;
esac
