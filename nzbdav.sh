#!/bin/bash
set -euo pipefail
# nzbdav installer
# STiXzoOR 2026
# Usage: bash nzbdav.sh [--update [--verbose]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

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
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/nzb-dav.png"
app_default_mount="/mnt/nzbdav"
app_reqs=("curl" "fuse3" "sqlite3")

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
# NZBDav Health Check & Internal API
# ==============================================================================
_wait_for_health() {
    local max_wait="${1:-60}"
    local interval=2
    local elapsed=0
    while (( elapsed < max_wait )); do
        if curl -sf "http://127.0.0.1:${app_port}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        (( elapsed += interval )) || true
    done
    return 1
}

# POST config updates to NZBDav's internal API
# Usage: _nzbdav_api_post "config.key" "value" ["key2" "value2" ...]
_nzbdav_api_post() {
    local api_key
    api_key=$(docker exec nzbdav printenv FRONTEND_BACKEND_API_KEY 2>/dev/null) || return 1

    local form_args=()
    while [[ $# -gt 0 ]]; do
        form_args+=(-F "configName=$1" -F "configValue=$2")
        shift 2
    done

    curl -sf -X POST "http://127.0.0.1:${app_port}/api/update-config" \
        -H "x-api-key: ${api_key}" \
        "${form_args[@]}" >/dev/null 2>&1
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
    network_mode: host
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - PORT=${app_port}
    volumes:
      - ${app_configdir}:/config
      - /mnt:/mnt:rslave
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${app_port}/health"]
      interval: 1m
      timeout: 5s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
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
Wants=${app_mount_servicefile}

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
BindsTo=nzbdav.service

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
# njs Module (React Router manifest arg rewriting)
# ==============================================================================
_install_njs_manifest_rewriter() {
    # Install nginx njs module if not present
    if [[ ! -f /usr/lib/nginx/modules/ngx_http_js_module.so ]]; then
        echo_progress_start "Installing nginx njs module"
        apt-get install -y nginx-module-njs >>"$log" 2>&1 || {
            echo_warn "Failed to install nginx-module-njs; lazy route discovery may not work"
            return 0
        }
        echo_progress_done "nginx njs module installed"
    fi

    # Enable the module
    if [[ ! -f /etc/nginx/modules-enabled/50-mod-http-js.conf ]]; then
        echo 'load_module /usr/lib/nginx/modules/ngx_http_js_module.so;' \
            >/etc/nginx/modules-enabled/50-mod-http-js.conf
    fi

    # Add js_import to nginx.conf http block if not present
    if ! grep -q 'js_import nzbdav' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/include \/etc\/nginx\/mime.types;/a\\n\t# njs scripts for NZBDav React Router support\n\tjs_import nzbdav from /etc/nginx/njs.d/nzbdav_manifest.js;\n\tsubrequest_output_buffer_size 4k;' /etc/nginx/nginx.conf
    fi

    # Write the njs script
    mkdir -p /etc/nginx/njs.d
    cat >/etc/nginx/njs.d/nzbdav_manifest.js <<'NJSEOF'
// Strip /nzbdav prefix from p= query parameter values in __manifest requests.
// React Router sends full pathnames (with basename) but the upstream expects bare route paths.
async function proxy_manifest(r) {
    var args = (r.variables.args || '').replace(/%2Fnzbdav%2F/gi, '%2F').replace(/\/nzbdav\//g, '/');
    var resp = await r.subrequest('/_nzbdav_manifest_upstream', { args: args });

    for (var h in resp.headersOut) {
        r.headersOut[h] = resp.headersOut[h];
    }
    r.return(resp.status, resp.responseBuffer);
}

export default { proxy_manifest };
NJSEOF
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
			    proxy_redirect / /${app_baseurl}/;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    # Disable upstream compression so sub_filter can rewrite
			    proxy_set_header Accept-Encoding "";

			    # Rewrite URLs in responses (NZBDav is a React Router SSR app with no base URL support)
			    sub_filter_once off;
			    sub_filter_types text/css text/javascript application/javascript application/json;

			    # React Router basename — controls all client-side routing
			    sub_filter '"basename":"/"' '"basename":"/${app_baseurl}"';

			    # HTML attributes
			    sub_filter 'href="/' 'href="/${app_baseurl}/';
			    sub_filter 'src="/' 'src="/${app_baseurl}/';
			    sub_filter 'action="/' 'action="/${app_baseurl}/';

			    # JSX properties in bundled JS (React virtual DOM)
			    sub_filter 'href:"/' 'href:"/${app_baseurl}/';
			    sub_filter 'src:"/' 'src:"/${app_baseurl}/';

			    # ES module imports and dynamic imports
			    sub_filter 'from "/' 'from "/${app_baseurl}/';
			    sub_filter 'import("/' 'import("/${app_baseurl}/';

			    # Asset and API paths in JSON manifests / bundled JS
			    sub_filter '"/assets/' '"/${app_baseurl}/assets/';
			    sub_filter '"/api/' '"/${app_baseurl}/api/';
			    sub_filter '"/settings/' '"/${app_baseurl}/settings/';
			    sub_filter '"/data/' '"/${app_baseurl}/data/';
			    sub_filter '"/explore/' '"/${app_baseurl}/explore/';

			    # WebSocket URL (connects to origin root without this)
			    sub_filter '.origin.replace(/^http/,"ws")' '.origin.replace(/^http/,"ws")+"/${app_baseurl}/"';

			    # CSS url()
			    sub_filter 'url(/' 'url(/${app_baseurl}/';

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			# React Router lazy route discovery — njs strips /${app_baseurl} prefix from p= route paths
			location = /${app_baseurl}/__manifest {
			    js_content nzbdav.proxy_manifest;
			}

			# Internal subrequest target for __manifest
			location = /_nzbdav_manifest_upstream {
			    internal;
			    proxy_pass http://127.0.0.1:${app_port}/__manifest;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_set_header Accept-Encoding "";
			    sub_filter_once off;
			    sub_filter_types application/json;
			    sub_filter '"/assets/' '"/${app_baseurl}/assets/';
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

        # Install njs module and script for React Router manifest arg rewriting
        _install_njs_manifest_rewriter

        _reload_nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "${app_pretty} will run on port ${app_port}"
    fi
}

# ==============================================================================
# rclone Setup (auto-configures WebDAV credentials via internal API)
# ==============================================================================
_setup_rclone() {
    echo_info "Setting up rclone WebDAV mount for ${app_pretty}..."

    # Get or confirm mount point
    _get_mount_point
    swizdb set "${app_name}/mount_point" "$app_mount_point"

    local webdav_pass="" api_setup=false

    # Try automated setup via internal API
    if _wait_for_health 60; then
        webdav_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)

        if _nzbdav_api_post "webdav.user" "admin" "webdav.pass" "${webdav_pass}"; then
            api_setup=true
            echo_info "WebDAV credentials configured automatically"

            # Tell NZBDav where the rclone mount lives (Phase 3)
            _nzbdav_api_post "rclone.mount-dir" "${app_mount_point}" || true
        fi
    fi

    # Fallback: manual prompt (re-run path or API failure)
    if [[ "$api_setup" == "false" ]]; then
        echo_warn "Automatic WebDAV setup unavailable — falling back to manual configuration."
        echo_query "Enter NZBDav WebDAV password (configured in the web UI)" ""
        read -rs webdav_pass </dev/tty
        echo ""

        if [[ -z "$webdav_pass" ]]; then
            echo_error "WebDAV password cannot be empty"
            exit 1
        fi
    fi

    # Obscure the password for rclone config
    echo_progress_start "Configuring rclone"
    local obscured
    obscured=$(echo "$webdav_pass" | rclone obscure -) || {
        echo_error "Failed to obscure password"
        exit 1
    }
    unset webdav_pass

    # Write rclone.conf with restricted permissions
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
    echo_progress_done "rclone configured"

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

    echo_success "rclone WebDAV mount configured at ${app_mount_point}"
}

# ==============================================================================
# Post-Install Messaging
# ==============================================================================
_post_install_message() {
    echo ""
    echo_info "============================================"
    echo_info " ${app_pretty} Installation Complete"
    echo_info "============================================"
    echo ""

    if [[ -f "${app_dir}/rclone.conf" ]]; then
        echo_info "Auto-configured:"
        echo_info "  WebDAV credentials (admin / random password)"
        echo_info "  rclone mount at ${app_mount_point}"
        echo_info "  rclone config at ${app_dir}/rclone.conf"
    else
        echo_info "rclone mount not yet configured."
        echo_info "Re-run: bash ${SCRIPT_DIR}/${app_name}.sh"
    fi

    echo ""
    echo_warn "REMAINING SETUP (web UI required):"
    echo_info "  1. Open: https://your-server/${app_baseurl}/"
    echo_info "  2. Configure your Usenet provider in Settings > Usenet"
    echo_info "  3. Review SABnzbd settings in Settings > SABnzbd"
    echo ""
    echo_info "SABnzbd API: http://127.0.0.1:${app_port}/api"
    echo_info "API Key: check NZBDav Settings > SABnzbd after first-run setup"
    echo_info "Arr connections use: http://127.0.0.1:<arr_port>"
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

    _install_docker
    _install_rclone
    _configure_fuse
    _install_nzbdav
    _systemd_nzbdav
    _nginx_nzbdav

    # Mark v0.6.0 migration as complete (fresh installs don't need it)
    touch "${app_configdir}/.v060-migrated"

    # Wait for container health before auto-configuration
    echo_progress_start "Waiting for ${app_pretty} to be ready"
    if _wait_for_health 60; then
        echo_progress_done "${app_pretty} is ready"
    else
        echo_warn "${app_pretty} health check timed out"
    fi

    # Auto-configure WebDAV credentials + rclone mount
    _setup_rclone

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

    # Back up config before update
    local backup_dir="${app_configdir}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${app_configdir}" "$backup_dir" 2>/dev/null && \
        echo_info "Config backed up to ${backup_dir}" || true

    # Save rclone mount state before update
    local rclone_was_active
    rclone_was_active=$(systemctl is-active "${app_mount_servicefile}" 2>/dev/null) || rclone_was_active="inactive"

    # Stop rclone mount first (unmount before stopping backend)
    if [[ "$rclone_was_active" == "active" ]]; then
        echo_progress_start "Stopping rclone mount"
        systemctl stop "${app_mount_servicefile}" 2>/dev/null || true
        echo_progress_done "rclone mount stopped"
    fi

    # Regenerate compose file (picks up host networking/PORT changes from installer updates)
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    echo_progress_start "Updating Docker Compose configuration"
    cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  nzbdav:
    image: ${app_image}
    container_name: nzbdav
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=${uid}
      - PGID=${gid}
      - PORT=${app_port}
    volumes:
      - ${app_configdir}:/config
      - /mnt:/mnt:rslave
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${app_port}/health"]
      interval: 1m
      timeout: 5s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
COMPOSE
    chmod 600 "${app_dir}/docker-compose.yml"
    chown root:root "${app_dir}/docker-compose.yml"
    echo_progress_done "Docker Compose configuration updated"

    echo_progress_start "Pulling latest ${app_pretty} image"
    _verbose "Running: docker compose -f ${app_dir}/docker-compose.yml pull"
    docker compose -f "${app_dir}/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    # Handle v0.6.0 migration (one-time, irreversible DB migration)
    if [[ ! -f "${app_configdir}/.v060-migrated" ]]; then
        echo_warn "Applying v0.6.0 database migration (one-time, irreversible)..."
        # Temporarily add UPGRADE env var
        sed -i '/- PGID=/a\      - UPGRADE=0.6.0' "${app_dir}/docker-compose.yml"

        docker compose -f "${app_dir}/docker-compose.yml" up -d >>"$log" 2>&1 || {
            echo_error "Failed to start v0.6.0 migration"
            exit 1
        }
        _wait_for_health 120 || echo_warn "Health check timed out during migration"

        # Remove UPGRADE env var and recreate cleanly
        sed -i '/- UPGRADE=0.6.0/d' "${app_dir}/docker-compose.yml"
        touch "${app_configdir}/.v060-migrated"
        echo_info "v0.6.0 migration complete"
    fi

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
        _remove_nginx_conf "$app_name"
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
