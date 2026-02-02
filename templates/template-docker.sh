#!/bin/bash
# ==============================================================================
# DOCKER INSTALLER TEMPLATE
# ==============================================================================
# Template for installing Docker-based applications via Docker Compose
# Examples: lingarr
#
# Usage: bash <appname>.sh [--update [--verbose]|--remove [--force]|--register-panel]
#
# CUSTOMIZATION POINTS (search for "# CUSTOMIZE:"):
# 1. App variables (name, image, port, icon, etc.)
# 2. Docker Compose environment variables in _install_<app>()
# 3. Docker Compose volumes in _install_<app>()
# 4. Nginx location config in _nginx_<app>()
# 5. Any app-specific discovery functions
#
# WHAT THIS TEMPLATE PROVIDES:
# - Docker Engine + Compose auto-installation
# - docker-compose.yml generation
# - Systemd oneshot service wrapping Docker Compose
# - Nginx reverse proxy with WebSocket support
# - Panel registration
# - --update flag for image updates
# - --remove with config purge option
# - Port persistence in swizdb across re-runs
# ==============================================================================

# CUSTOMIZE: Replace "myapp" with your app name throughout this file
# Tip: Use sed 's/myapp/yourapp/g' and 's/Myapp/Yourapp/g'

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# ==============================================================================
# Panel Helper - Download and cache for panel integration
# ==============================================================================
PANEL_HELPER_LOCAL="/opt/swizzin-extras/panel_helpers.sh"
PANEL_HELPER_URL="https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/panel_helpers.sh"

_load_panel_helper() {
	if [[ -f "$PANEL_HELPER_LOCAL" ]]; then
		# shellcheck source=panel_helpers.sh
		. "$PANEL_HELPER_LOCAL"
		return
	fi

	mkdir -p "$(dirname "$PANEL_HELPER_LOCAL")"
	if curl -fsSL "$PANEL_HELPER_URL" -o "$PANEL_HELPER_LOCAL" >>"$log" 2>&1; then
		chmod +x "$PANEL_HELPER_LOCAL"
		. "$PANEL_HELPER_LOCAL"
	else
		echo_info "Could not fetch panel helper; skipping panel integration"
	fi
}

# ==============================================================================
# Logging
# ==============================================================================
export log=/root/logs/swizzin.log
touch "$log"

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
# CUSTOMIZE: Set all app-specific variables here

app_name="myapp"
app_pretty="Myapp"             # Display name (capitalized)
app_lockname="${app_name//-/}" # Lock file name (no hyphens)
app_baseurl="${app_name}"      # URL path (e.g., /myapp)

# CUSTOMIZE: Docker image
app_image="myapp/myapp:latest" # Docker image (e.g., "lingarr/lingarr:latest")
app_container_port="8080"      # Port the app listens on inside the container

# Directories
app_dir="/opt/${app_name}"
app_configdir="${app_dir}/config"

# Systemd
app_servicefile="${app_name}.service"

# Panel icon
app_icon_name="${app_name}"
# CUSTOMIZE: Set icon URL or use "placeholder" for default
app_icon_url="https://example.com/icon.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================
# Get owner from swizdb or fall back to master user
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
		curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | \
			gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$log" 2>&1
		chmod a+r /etc/apt/keyrings/docker.gpg
	fi

	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" | \
		tee /etc/apt/sources.list.d/docker.list > /dev/null

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
# App Installation
# ==============================================================================
_install_myapp() {
	mkdir -p "$app_configdir"
	chown -R "${user}:${user}" "$app_dir"

	local uid gid
	uid=$(id -u "$user")
	gid=$(id -g "$user")

	# Persist port in swizdb
	swizdb set "${app_name}/port" "$app_port"

	echo_progress_start "Generating Docker Compose configuration"

	# CUSTOMIZE: Adjust environment variables and volumes for your app.
	# Build the docker-compose.yml using a block redirect for clean YAML output.
	# Use the heredoc for the static portion, then echo for dynamic parts.
	{
		cat <<COMPOSE
services:
  ${app_name}:
    image: ${app_image}
    container_name: ${app_name}
    restart: unless-stopped
    user: "${uid}:${gid}"
    ports:
      - "127.0.0.1:${app_port}:${app_container_port}"
    environment:
COMPOSE
		# CUSTOMIZE: Add your app's environment variables here
		echo "      - EXAMPLE_VAR=value"
		echo "    volumes:"
		echo "      - ${app_configdir}:/app/config"
		# CUSTOMIZE: Add additional volume mounts here
		# echo "      - /path/on/host:/path/in/container"
	} > "${app_dir}/docker-compose.yml"

	echo_progress_done "Docker Compose configuration generated"

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
# Removal
# ==============================================================================
_remove_myapp() {
	local force="$1"

	if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_pretty} is not installed (use --force to override)"
		exit 1
	fi

	echo_info "Removing ${app_pretty}..."

	# Ask about purging configuration
	if ask "Would you like to purge the configuration?" N; then
		purgeconfig="true"
	else
		purgeconfig="false"
	fi

	# Stop and remove container
	echo_progress_start "Stopping ${app_pretty} container"
	if [[ -f "${app_dir}/docker-compose.yml" ]]; then
		docker compose -f "${app_dir}/docker-compose.yml" down >>"$log" 2>&1 || true
	fi
	echo_progress_done "Container stopped"

	# Remove Docker image
	echo_progress_start "Removing Docker image"
	docker rmi "$app_image" >>"$log" 2>&1 || true
	echo_progress_done "Docker image removed"

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
		systemctl reload nginx 2>/dev/null || true
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
	else
		echo_info "Configuration kept at: ${app_configdir}"
		rm -f "${app_dir}/docker-compose.yml"
	fi

	# Remove lock file
	rm -f "/install/.${app_lockname}.lock"

	echo_success "${app_pretty} has been removed"
	exit 0
}

# ==============================================================================
# Update (Docker-specific: pull latest image and recreate container)
# ==============================================================================
_update_myapp() {
	if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_pretty} is not installed"
		exit 1
	fi

	echo_info "Updating ${app_pretty}..."

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

	# Clean up old dangling images
	_verbose "Pruning unused images"
	docker image prune -f >>"$log" 2>&1 || true

	echo_success "${app_pretty} has been updated"
	exit 0
}

# ==============================================================================
# Systemd Service (oneshot wrapper for Docker Compose)
# ==============================================================================
_systemd_myapp() {
	echo_progress_start "Installing systemd service"

	cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty}
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

	systemctl -q daemon-reload
	systemctl enable -q "$app_servicefile"
	echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_myapp() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx"

		# CUSTOMIZE: Adjust proxy settings as needed.
		# WebSocket headers (Upgrade/Connection) are included by default
		# for apps using real-time UI frameworks (e.g., SignalR, Socket.IO).
		# Remove them if your app doesn't use WebSockets.
		#
		# If the app has no base_url support, add sub_filter directives to
		# rewrite asset paths (see lingarr.sh or zurg.sh for examples):
		#   sub_filter_once off;
		#   sub_filter_types text/html text/css text/javascript application/javascript application/json;
		#   sub_filter 'href="/' 'href="/${app_baseurl}/';
		#   sub_filter 'src="/' 'src="/${app_baseurl}/';
		#   etc.
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

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /${app_baseurl}/api {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/api;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

		systemctl reload nginx
		echo_progress_done "Nginx configured"
	else
		echo_info "${app_pretty} will run on port ${app_port}"
	fi
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

# Handle --remove flag
if [[ "$1" == "--remove" ]]; then
	_remove_myapp "$2"
fi

# Handle --update flag
if [[ "$1" == "--update" ]]; then
	_update_myapp
fi

# Handle --register-panel flag
if [[ "$1" == "--register-panel" ]]; then
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
fi

# Check if already installed
if [[ -f "/install/.${app_lockname}.lock" ]]; then
	echo_info "${app_pretty} is already installed"
else
	# Set owner in swizdb
	echo_info "Setting ${app_pretty} owner = ${user}"
	swizdb set "${app_name}/owner" "$user"

	# Run installation
	_install_docker
	_install_myapp
	_systemd_myapp
	_nginx_myapp
fi

# Register with panel (runs on both fresh install and re-run)
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

echo_success "${app_pretty} installed"
echo_info "Access at: https://your-server/${app_baseurl}/"
