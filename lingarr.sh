#!/bin/bash
# lingarr installer
# STiXzoOR 2025
# Usage: bash lingarr.sh [--update|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

PANEL_HELPER_LOCAL="/opt/swizzin-extras/panel_helpers.sh"
PANEL_HELPER_URL="https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/panel_helpers.sh"

_load_panel_helper() {
	# If already on disk, just source it
	if [ -f "$PANEL_HELPER_LOCAL" ]; then
		. "$PANEL_HELPER_LOCAL"
		return
	fi

	# Try to fetch from GitHub and save permanently
	mkdir -p "$(dirname "$PANEL_HELPER_LOCAL")"
	if curl -fsSL "$PANEL_HELPER_URL" -o "$PANEL_HELPER_LOCAL" >>"$log" 2>&1; then
		chmod +x "$PANEL_HELPER_LOCAL" || true
		. "$PANEL_HELPER_LOCAL"
	else
		echo_info "Could not fetch panel helper from $PANEL_HELPER_URL; skipping panel integration"
	fi
}

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

app_name="lingarr"

# Get owner from swizdb (needed for both install and remove)
if ! LINGARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
	LINGARR_OWNER="$(_get_master_username)"
fi
user="$LINGARR_OWNER"
app_group="$user"

# Try to read existing port from swizdb, allocate new one only on fresh install
if _existing_port="$(swizdb get "$app_name/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
	app_port="$_existing_port"
else
	app_port=$(port 10000 12000)
fi

app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_configdir="$app_dir/config"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/lingarr.png"

# --- Function definitions ---

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

_discover_media_paths() {
	MEDIA_PATHS=()
	MEDIA_MOUNT_NAMES=()
	local -A seen_paths=()
	local -A seen_mounts=()

	echo_progress_start "Discovering media paths from Sonarr/Radarr"

	# Scan for arr lock files and query their databases (requires sqlite3)
	if ! command -v sqlite3 >/dev/null 2>&1; then
		echo_info "sqlite3 not found, skipping database auto-discovery"
	else
	for lock in /install/.sonarr.lock /install/.sonarr_*.lock /install/.radarr.lock /install/.radarr_*.lock; do
		[[ -f "$lock" ]] || continue

		local lock_basename
		lock_basename=$(basename "$lock" .lock)
		lock_basename="${lock_basename#.}" # Remove leading dot

		# Determine config directory name
		local config_dir_name
		case "$lock_basename" in
			sonarr) config_dir_name="Sonarr" ;;
			radarr) config_dir_name="Radarr" ;;
			sonarr_*)
				local instance="${lock_basename#sonarr_}"
				config_dir_name="sonarr-${instance}"
				;;
			radarr_*)
				local instance="${lock_basename#radarr_}"
				config_dir_name="radarr-${instance}"
				;;
			*) continue ;;
		esac

		# Find the database file
		for db in /home/*/.config/"${config_dir_name}"/*.db; do
			[[ -f "$db" ]] || continue
			# Query root folders
			while IFS= read -r path; do
				[[ -z "$path" ]] && continue
				# Remove trailing slash for consistency
				path="${path%/}"
				if [[ -z "${seen_paths[$path]+x}" ]]; then
					seen_paths["$path"]=1
					MEDIA_PATHS+=("$path")
				fi
			done < <(sqlite3 "$db" "SELECT Path FROM RootFolders;" 2>/dev/null)
		done
	done
	fi # sqlite3 check

	echo_progress_done "Discovery complete"

	# Generate mount names from path basenames
	for path in "${MEDIA_PATHS[@]}"; do
		local mount_name
		mount_name=$(basename "$path")
		# Handle duplicate mount names by appending a number
		if [[ -n "${seen_mounts[$mount_name]+x}" ]]; then
			local count=2
			while [[ -n "${seen_mounts[${mount_name}${count}]+x}" ]]; do
				((count++))
			done
			mount_name="${mount_name}${count}"
		fi
		seen_mounts["$mount_name"]=1
		MEDIA_MOUNT_NAMES+=("$mount_name")
	done

	# Display discovered paths
	if [[ ${#MEDIA_PATHS[@]} -gt 0 ]]; then
		echo_info "Discovered media paths:"
		for i in "${!MEDIA_PATHS[@]}"; do
			echo_info "  ${MEDIA_PATHS[$i]} -> /${MEDIA_MOUNT_NAMES[$i]}"
		done

		if ! ask "Use these paths?" Y; then
			MEDIA_PATHS=()
			MEDIA_MOUNT_NAMES=()
			seen_mounts=()
		fi
	else
		echo_info "No Sonarr/Radarr installations found for auto-discovery"
	fi

	# Allow adding additional paths (or all paths if none discovered/confirmed)
	while true; do
		if [[ ${#MEDIA_PATHS[@]} -eq 0 ]]; then
			echo_query "Enter a media path (e.g., /mnt/media/movies, or leave empty to cancel)"
		else
			if ! ask "Add another media path?" N; then
				break
			fi
			echo_query "Enter the media path (or leave empty to skip)"
		fi

		local new_path
		read -r new_path </dev/tty
		if [[ -z "$new_path" ]]; then
			[[ ${#MEDIA_PATHS[@]} -gt 0 ]] && break
			echo_info "No path entered"
			continue
		fi

		new_path="${new_path%/}"

		if [[ -n "${seen_paths[$new_path]+x}" ]]; then
			echo_info "Path already added, skipping"
			continue
		fi

		seen_paths["$new_path"]=1
		MEDIA_PATHS+=("$new_path")

		local mount_name
		mount_name=$(basename "$new_path")
		if [[ -n "${seen_mounts[$mount_name]+x}" ]]; then
			local count=2
			while [[ -n "${seen_mounts[${mount_name}${count}]+x}" ]]; do
				((count++))
			done
			mount_name="${mount_name}${count}"
		fi
		seen_mounts["$mount_name"]=1
		MEDIA_MOUNT_NAMES+=("$mount_name")

		echo_info "Added: $new_path -> /$mount_name"
	done

	if [[ ${#MEDIA_PATHS[@]} -eq 0 ]]; then
		echo_error "At least one media path is required"
		exit 1
	fi
}

_discover_arr_api() {
	SONARR_URL=""
	SONARR_API_KEY=""
	RADARR_URL=""
	RADARR_API_KEY=""

	# Only discover one Sonarr and one Radarr instance (base preferred).
	# Lingarr's web UI can be used to configure additional instances.

	# Try Sonarr (base first, then multi-instance)
	local sonarr_config=""
	if [[ -f /install/.sonarr.lock ]]; then
		for cfg in /home/*/.config/Sonarr/config.xml; do
			[[ -f "$cfg" ]] && sonarr_config="$cfg" && break
		done
	fi
	if [[ -z "$sonarr_config" ]]; then
		for lock in /install/.sonarr_*.lock; do
			[[ -f "$lock" ]] || continue
			local instance="${lock##*/}"
			instance="${instance#.sonarr_}"
			instance="${instance%.lock}"
			for cfg in /home/*/.config/sonarr-"${instance}"/config.xml; do
				[[ -f "$cfg" ]] && sonarr_config="$cfg" && break 2
			done
		done
	fi

	if [[ -n "$sonarr_config" ]]; then
		local api_key port
		api_key=$(grep -oP '<ApiKey>\K[^<]+' "$sonarr_config" 2>/dev/null) || true
		port=$(grep -oP '<Port>\K[^<]+' "$sonarr_config" 2>/dev/null) || true
		if [[ -n "$api_key" && -n "$port" ]]; then
			SONARR_URL="http://localhost:${port}"
			SONARR_API_KEY="$api_key"
			echo_info "Discovered Sonarr at ${SONARR_URL}"
		fi
	fi

	# Try Radarr (base first, then multi-instance)
	local radarr_config=""
	if [[ -f /install/.radarr.lock ]]; then
		for cfg in /home/*/.config/Radarr/config.xml; do
			[[ -f "$cfg" ]] && radarr_config="$cfg" && break
		done
	fi
	if [[ -z "$radarr_config" ]]; then
		for lock in /install/.radarr_*.lock; do
			[[ -f "$lock" ]] || continue
			local instance="${lock##*/}"
			instance="${instance#.radarr_}"
			instance="${instance%.lock}"
			for cfg in /home/*/.config/radarr-"${instance}"/config.xml; do
				[[ -f "$cfg" ]] && radarr_config="$cfg" && break 2
			done
		done
	fi

	if [[ -n "$radarr_config" ]]; then
		local api_key port
		api_key=$(grep -oP '<ApiKey>\K[^<]+' "$radarr_config" 2>/dev/null) || true
		port=$(grep -oP '<Port>\K[^<]+' "$radarr_config" 2>/dev/null) || true
		if [[ -n "$api_key" && -n "$port" ]]; then
			RADARR_URL="http://localhost:${port}"
			RADARR_API_KEY="$api_key"
			echo_info "Discovered Radarr at ${RADARR_URL}"
		fi
	fi
}

_install_lingarr() {
	mkdir -p "$app_configdir"
	chown -R "${user}:${user}" "$app_dir"

	local uid gid
	uid=$(id -u "$user")
	gid=$(id -g "$user")

	# Persist port in swizdb
	swizdb set "$app_name/port" "$app_port"

	echo_progress_start "Generating Docker Compose configuration"

	# Write docker-compose.yml with proper YAML formatting
	{
		cat <<COMPOSE
services:
  lingarr:
    image: lingarr/lingarr:latest
    container_name: lingarr
    restart: unless-stopped
    user: "${uid}:${gid}"
    ports:
      - "127.0.0.1:${app_port}:9876"
    environment:
      - ASPNETCORE_URLS=http://+:9876
      - DB_CONNECTION=sqlite
COMPOSE
		if [[ -n "${SONARR_URL:-}" ]]; then
			echo "      - SONARR_URL=${SONARR_URL}"
			echo "      - SONARR_API_KEY=${SONARR_API_KEY}"
		fi
		if [[ -n "${RADARR_URL:-}" ]]; then
			echo "      - RADARR_URL=${RADARR_URL}"
			echo "      - RADARR_API_KEY=${RADARR_API_KEY}"
		fi
		echo "    volumes:"
		echo "      - ${app_configdir}:/app/config"
		for i in "${!MEDIA_PATHS[@]}"; do
			echo "      - ${MEDIA_PATHS[$i]}:/${MEDIA_MOUNT_NAMES[$i]}"
		done
	} > "$app_dir/docker-compose.yml"

	echo_progress_done "Docker Compose configuration generated"

	echo_progress_start "Pulling Lingarr Docker image"
	docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
		echo_error "Failed to pull Docker image"
		exit 1
	}
	echo_progress_done "Docker image pulled"

	echo_progress_start "Starting Lingarr container"
	docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
		echo_error "Failed to start container"
		exit 1
	}
	echo_progress_done "Lingarr container started"
}

_systemd_lingarr() {
	echo_progress_start "Installing systemd service"
	cat > "/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=Lingarr (Subtitle Translation)
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

_nginx_lingarr() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx"
		cat > /etc/nginx/apps/$app_name.conf <<-NGX
			location /$app_baseurl {
			  return 301 /$app_baseurl/;
			}

			location ^~ /$app_baseurl/ {
			    proxy_pass http://127.0.0.1:$app_port/;
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

			    # Rewrite URLs in responses (Lingarr has no base_url support)
			    sub_filter_once off;
			    sub_filter_types text/html text/css text/javascript application/javascript application/json;
			    sub_filter 'href="/' 'href="/$app_baseurl/';
			    sub_filter 'src="/' 'src="/$app_baseurl/';
			    sub_filter 'action="/' 'action="/$app_baseurl/';
			    sub_filter 'url(/' 'url(/$app_baseurl/';
			    sub_filter '"/api/' '"/$app_baseurl/api/';
			    sub_filter "'/api/" "'/$app_baseurl/api/";
			    sub_filter 'fetch("/' 'fetch("/$app_baseurl/';
			    sub_filter "fetch('/" "fetch('/$app_baseurl/";
			    sub_filter '"/signalr' '"/$app_baseurl/signalr';
			    sub_filter "'/signalr" "'/$app_baseurl/signalr";
			    # Fix Vue Router base path (client-side routing)
			    sub_filter 'createWebHistory()' 'createWebHistory("/$app_baseurl/")';

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /$app_baseurl/api {
			    auth_request off;
			    proxy_pass http://127.0.0.1:$app_port/api;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			}
		NGX

		systemctl reload nginx
		echo_progress_done "Nginx configured"
	else
		echo_info "$app_name will run on port $app_port"
	fi
}

_update_lingarr() {
	if [[ ! -f "/install/.$app_lockname.lock" ]]; then
		echo_error "${app_name^} is not installed"
		exit 1
	fi

	echo_progress_start "Pulling latest Lingarr image"
	docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
		echo_error "Failed to pull latest image"
		exit 1
	}
	echo_progress_done "Latest image pulled"

	echo_progress_start "Recreating Lingarr container"
	docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
		echo_error "Failed to recreate container"
		exit 1
	}
	echo_progress_done "Container recreated"

	# Clean up old images
	docker image prune -f >>"$log" 2>&1 || true

	echo_success "${app_name^} has been updated"
	exit 0
}

_remove_lingarr() {
	local force="$1"
	if [[ "$force" != "--force" ]] && [[ ! -f "/install/.$app_lockname.lock" ]]; then
		echo_error "${app_name^} is not installed (use --force to override)"
		exit 1
	fi

	echo_info "Removing ${app_name^}..."

	# Ask about purging configuration
	if ask "Would you like to purge the configuration?" N; then
		purgeconfig="true"
	else
		purgeconfig="false"
	fi

	# Stop and remove container
	echo_progress_start "Stopping Lingarr container"
	if [[ -f "$app_dir/docker-compose.yml" ]]; then
		docker compose -f "$app_dir/docker-compose.yml" down >>"$log" 2>&1 || true
	fi
	echo_progress_done "Container stopped"

	# Remove Docker image
	echo_progress_start "Removing Docker image"
	docker rmi lingarr/lingarr >>"$log" 2>&1 || true
	echo_progress_done "Docker image removed"

	# Remove systemd service
	echo_progress_start "Removing systemd service"
	systemctl stop "$app_servicefile" 2>/dev/null || true
	systemctl disable "$app_servicefile" 2>/dev/null || true
	rm -f "/etc/systemd/system/$app_servicefile"
	systemctl daemon-reload
	echo_progress_done "Service removed"

	# Remove nginx config
	if [[ -f "/etc/nginx/apps/$app_name.conf" ]]; then
		echo_progress_start "Removing nginx configuration"
		rm -f "/etc/nginx/apps/$app_name.conf"
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
		swizdb clear "$app_name/owner" 2>/dev/null || true
		swizdb clear "$app_name/port" 2>/dev/null || true
	else
		echo_info "Configuration kept at: $app_configdir"
		rm -f "$app_dir/docker-compose.yml"
	fi

	# Remove lock file
	rm -f "/install/.$app_lockname.lock"

	echo_success "${app_name^} has been removed"
	exit 0
}

# --- Flag parsing ---

# Handle --remove flag
if [[ "$1" = "--remove" ]]; then
	_remove_lingarr "$2"
fi

# Handle --update flag
if [[ "$1" = "--update" ]]; then
	_update_lingarr
fi

# Handle --register-panel flag
if [[ "$1" = "--register-panel" ]]; then
	if [[ ! -f "/install/.$app_lockname.lock" ]]; then
		echo_error "${app_name^} is not installed"
		exit 1
	fi
	_load_panel_helper
	if command -v panel_register_app >/dev/null 2>&1; then
		panel_register_app \
			"$app_name" \
			"Lingarr" \
			"/$app_baseurl" \
			"" \
			"$app_name" \
			"$app_icon_name" \
			"$app_icon_url" \
			"true"
		systemctl restart panel 2>/dev/null || true
		echo_success "Panel registration updated for ${app_name^}"
	else
		echo_error "Panel helper not available"
		exit 1
	fi
	exit 0
fi

# --- Main install flow ---

# Check if already installed
if [[ -f "/install/.$app_lockname.lock" ]]; then
	echo_info "${app_name^} is already installed"
else
	# Set owner for install
	if [[ -n "$LINGARR_OWNER" ]]; then
		echo_info "Setting ${app_name^} owner = $LINGARR_OWNER"
		swizdb set "$app_name/owner" "$LINGARR_OWNER"
	fi

	_install_docker
	_discover_media_paths
	_discover_arr_api
	_install_lingarr
	_systemd_lingarr
	_nginx_lingarr
fi

# Panel registration (runs on both fresh install and re-run)
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Lingarr" \
		"/$app_baseurl" \
		"" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
