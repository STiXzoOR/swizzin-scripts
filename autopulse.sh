#!/bin/bash
set -euo pipefail
# autopulse installer
# STiXzoOR 2026
# Usage: bash autopulse.sh [--update [--verbose]|--remove [--force]|--register-panel]

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
	if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
		. "${SCRIPT_DIR}/panel_helpers.sh"
		return
	fi
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

app_name="autopulse"
app_pretty="Autopulse"
app_lockname="${app_name}"
app_baseurl="${app_name}"
app_image_api="ghcr.io/dan-online/autopulse:latest"
app_image_ui="ghcr.io/dan-online/autopulse:ui-dynamic"

app_dir="/opt/${app_name}"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://raw.githubusercontent.com/dan-online/autopulse/main/ui/static/favicon.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================

if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
	app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Port persistence — API port
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
	app_port="$_existing_port"
elif [[ -n "${AUTOPULSE_PORT:-}" ]]; then
	app_port="$AUTOPULSE_PORT"
else
	app_port=$(port 10000 12000)
fi

# Port persistence — UI port
if _existing_ui_port="$(swizdb get "${app_name}/ui_port" 2>/dev/null)" && [[ -n "$_existing_ui_port" ]]; then
	app_ui_port="$_existing_ui_port"
elif [[ -n "${AUTOPULSE_UI_PORT:-}" ]]; then
	app_ui_port="$AUTOPULSE_UI_PORT"
else
	app_ui_port=$(port 10000 12000)
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

	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		docker-ce docker-ce-cli containerd.io docker-compose-plugin >>"$log" 2>&1 || {
		echo_error "Failed to install Docker packages"
		exit 1
	}

	systemctl enable --now docker >>"$log" 2>&1

	if ! docker info >/dev/null 2>&1; then
		echo_error "Docker failed to start"
		exit 1
	fi

	echo_progress_done "Docker installed"
}

# ==============================================================================
# Ensure jq is available (needed for API interactions)
# ==============================================================================
_ensure_jq() {
	if command -v jq >/dev/null 2>&1; then
		return 0
	fi
	echo_progress_start "Installing jq"
	apt_install jq
	echo_progress_done "jq installed"
}

# ==============================================================================
# Arr Instance Auto-Discovery
# ==============================================================================

# Parallel arrays populated by _discover_arrs
ARR_NAMES=()
ARR_TYPES=()    # "sonarr" or "radarr" or "lidarr" or "readarr"
ARR_PORTS=()
ARR_APIKEYS=()
ARR_URLBASES=()

_discover_arrs() {
	echo_progress_start "Discovering arr instances"

	local lock_basename config_dir_name arr_type instance_name
	local cfg port apikey urlbase

	for lock in /install/.sonarr.lock /install/.sonarr_*.lock \
		/install/.radarr.lock /install/.radarr_*.lock \
		/install/.lidarr.lock /install/.lidarr_*.lock \
		/install/.readarr.lock /install/.readarr_*.lock; do
		[[ -f "$lock" ]] || continue

		lock_basename=$(basename "$lock" .lock)
		lock_basename="${lock_basename#.}" # Remove leading dot

		# Determine arr type and config directory name
		case "$lock_basename" in
			sonarr)
				arr_type="sonarr"
				config_dir_name="Sonarr"
				instance_name="sonarr"
				;;
			sonarr_*)
				arr_type="sonarr"
				instance_name="${lock_basename/sonarr_/sonarr-}"
				config_dir_name="${instance_name}"
				;;
			radarr)
				arr_type="radarr"
				config_dir_name="Radarr"
				instance_name="radarr"
				;;
			radarr_*)
				arr_type="radarr"
				instance_name="${lock_basename/radarr_/radarr-}"
				config_dir_name="${instance_name}"
				;;
			lidarr)
				arr_type="lidarr"
				config_dir_name="Lidarr"
				instance_name="lidarr"
				;;
			lidarr_*)
				arr_type="lidarr"
				instance_name="${lock_basename/lidarr_/lidarr-}"
				config_dir_name="${instance_name}"
				;;
			readarr)
				arr_type="readarr"
				config_dir_name="Readarr"
				instance_name="readarr"
				;;
			readarr_*)
				arr_type="readarr"
				instance_name="${lock_basename/readarr_/readarr-}"
				config_dir_name="${instance_name}"
				;;
			*) continue ;;
		esac

		# Find config.xml
		for cfg in /home/*/.config/"${config_dir_name}"/config.xml; do
			[[ -f "$cfg" ]] || continue

			port=$(grep -oP '(?<=<Port>)[^<]+' "$cfg" 2>/dev/null) || continue
			apikey=$(grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" 2>/dev/null) || continue
			urlbase=$(grep -oP '(?<=<UrlBase>)[^<]+' "$cfg" 2>/dev/null) || true

			ARR_NAMES+=("$instance_name")
			ARR_TYPES+=("$arr_type")
			ARR_PORTS+=("$port")
			ARR_APIKEYS+=("$apikey")
			ARR_URLBASES+=("${urlbase:-}")

			_verbose "Found ${instance_name} on port ${port} (urlbase: ${urlbase:-none})"
			break
		done
	done

	if [[ ${#ARR_NAMES[@]} -eq 0 ]]; then
		echo_warn "No arr instances found"
	else
		echo_progress_done "Found ${#ARR_NAMES[@]} arr instance(s): ${ARR_NAMES[*]}"
	fi
}

# ==============================================================================
# Media Server Auto-Discovery
# ==============================================================================

# Parallel arrays populated by _discover_media_servers
MS_NAMES=()
MS_TYPES=()    # "emby" or "jellyfin" or "plex"
MS_URLS=()
MS_TOKENS=()

_discover_media_servers() {
	echo_progress_start "Discovering media servers"

	# --- Emby ---
	if [[ -f /install/.emby.lock ]]; then
		local emby_port="8096"
		local emby_token=""

		# Try to find existing API key from Emby
		if [[ -f /var/lib/emby/config/system.xml ]]; then
			# Check if there's an existing Autopulse API key we created before
			emby_token=$(swizdb get "${app_name}/emby_token" 2>/dev/null) || true
		fi

		# If no stored token, create one via Emby API
		if [[ -z "$emby_token" ]]; then
			_verbose "Creating Emby API key for Autopulse"
			local create_response
			create_response=$(curl -s -X POST \
				"http://127.0.0.1:${emby_port}/emby/Auth/Keys" \
				-H "Content-Type: application/x-www-form-urlencoded" \
				-d "App=Autopulse" 2>/dev/null) || true

			# Read back the keys to find ours
			local keys_json
			keys_json=$(curl -s "http://127.0.0.1:${emby_port}/emby/Auth/Keys" 2>/dev/null) || true
			if [[ -n "$keys_json" ]]; then
				emby_token=$(echo "$keys_json" | jq -r '.Items[]? | select(.AppName == "Autopulse") | .AccessToken' 2>/dev/null | head -1) || true
			fi

			if [[ -z "$emby_token" ]]; then
				echo_warn "Could not auto-create Emby API key. You may need to create one manually."
				echo_query "Enter Emby API key (or leave empty to skip):" ""
				read -r emby_token </dev/tty
			fi
		fi

		if [[ -n "$emby_token" ]]; then
			MS_NAMES+=("emby")
			MS_TYPES+=("emby")
			MS_URLS+=("http://127.0.0.1:${emby_port}")
			MS_TOKENS+=("$emby_token")
			swizdb set "${app_name}/emby_token" "$emby_token"
			_verbose "Found Emby on port ${emby_port}"
		fi
	fi

	# --- Jellyfin ---
	if [[ -f /install/.jellyfin.lock ]]; then
		local jf_port="8096"
		local jf_token=""

		# Check for stored token
		jf_token=$(swizdb get "${app_name}/jellyfin_token" 2>/dev/null) || true

		# Try to find port from Jellyfin config
		local jf_network_xml
		for jf_network_xml in /var/lib/jellyfin/config/network.xml /home/*/.config/jellyfin/network.xml; do
			if [[ -f "$jf_network_xml" ]]; then
				local jf_cfg_port
				jf_cfg_port=$(grep -oP '(?<=<HttpServerPortNumber>)[^<]+' "$jf_network_xml" 2>/dev/null) || true
				[[ -n "$jf_cfg_port" ]] && jf_port="$jf_cfg_port"
				break
			fi
		done

		# If no stored token, create one via Jellyfin API
		if [[ -z "$jf_token" ]]; then
			_verbose "Creating Jellyfin API key for Autopulse"
			# Jellyfin requires an existing admin API key to create new keys
			# Try to find one from existing config or prompt
			echo_query "Enter Jellyfin API key (Settings > API Keys > Add):" ""
			read -r jf_token </dev/tty
		fi

		if [[ -n "$jf_token" ]]; then
			MS_NAMES+=("jellyfin")
			MS_TYPES+=("jellyfin")
			MS_URLS+=("http://127.0.0.1:${jf_port}")
			MS_TOKENS+=("$jf_token")
			swizdb set "${app_name}/jellyfin_token" "$jf_token"
			_verbose "Found Jellyfin on port ${jf_port}"
		fi
	fi

	# --- Plex ---
	if [[ -f /install/.plex.lock ]]; then
		local plex_port="32400"
		local plex_token=""

		# Read token from Preferences.xml
		local plex_prefs
		for plex_prefs in "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml" \
			/home/*/.config/plexmediaserver/Preferences.xml; do
			if [[ -f "$plex_prefs" ]]; then
				plex_token=$(grep -oP 'PlexOnlineToken="[^"]*"' "$plex_prefs" 2>/dev/null \
					| head -1 | sed 's/PlexOnlineToken="//;s/"//') || true
				break
			fi
		done

		if [[ -z "$plex_token" ]]; then
			echo_query "Enter Plex token (from Preferences.xml or plex.tv/claim):" ""
			read -r plex_token </dev/tty
		fi

		if [[ -n "$plex_token" ]]; then
			MS_NAMES+=("plex")
			MS_TYPES+=("plex")
			MS_URLS+=("http://127.0.0.1:${plex_port}")
			MS_TOKENS+=("$plex_token")
			_verbose "Found Plex on port ${plex_port}"
		fi
	fi

	if [[ ${#MS_NAMES[@]} -eq 0 ]]; then
		echo_warn "No media servers found. Autopulse needs at least one target."
		echo_info "You can manually edit ${app_dir}/config.yaml after install."
	else
		echo_progress_done "Found ${#MS_NAMES[@]} media server(s): ${MS_NAMES[*]}"
	fi
}

# ==============================================================================
# Config Generation
# ==============================================================================
_generate_config() {
	echo_progress_start "Generating Autopulse configuration"

	mkdir -p "${app_dir}/data"
	chown -R "${user}:${user}" "$app_dir"

	# Persist ports
	swizdb set "${app_name}/port" "$app_port"
	swizdb set "${app_name}/ui_port" "$app_ui_port"
	swizdb set "${app_name}/owner" "$user"

	# Generate or reuse auth password
	local auth_password
	if auth_password="$(swizdb get "${app_name}/auth_password" 2>/dev/null)" && [[ -n "$auth_password" ]]; then
		_verbose "Reusing existing auth password"
	elif [[ -n "${AUTOPULSE_AUTH_PASSWORD:-}" ]]; then
		auth_password="$AUTOPULSE_AUTH_PASSWORD"
	else
		auth_password=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c -16)
	fi
	swizdb set "${app_name}/auth_password" "$auth_password"

	# Generate or reuse UI secret
	local ui_secret
	if ui_secret="$(swizdb get "${app_name}/ui_secret" 2>/dev/null)" && [[ -n "$ui_secret" ]]; then
		_verbose "Reusing existing UI secret"
	else
		ui_secret=$(openssl rand -hex 32)
	fi
	swizdb set "${app_name}/ui_secret" "$ui_secret"

	# --- Build config.yaml ---
	{
		cat <<-YAML
		app:
		  hostname: 0.0.0.0
		  port: ${app_port}
		  log_level: info

		auth:
		  username: ${user}
		  password: ${auth_password}

		YAML

		# Triggers section
		if [[ ${#ARR_NAMES[@]} -gt 0 ]]; then
			echo "triggers:"
			local i
			for ((i = 0; i < ${#ARR_NAMES[@]}; i++)); do
				echo "  ${ARR_NAMES[$i]}:"
				echo "    type: ${ARR_TYPES[$i]}"
			done
			echo ""
		fi

		# Targets section
		if [[ ${#MS_NAMES[@]} -gt 0 ]]; then
			echo "targets:"
			local i
			for ((i = 0; i < ${#MS_NAMES[@]}; i++)); do
				echo "  ${MS_NAMES[$i]}:"
				echo "    type: ${MS_TYPES[$i]}"
				echo "    url: ${MS_URLS[$i]}"
				echo "    token: ${MS_TOKENS[$i]}"
			done
			echo ""
		fi
	} >"${app_dir}/config.yaml"

	chmod 600 "${app_dir}/config.yaml"
	chown root:root "${app_dir}/config.yaml"

	echo_progress_done "Configuration generated"
}

# ==============================================================================
# Docker Compose Generation
# ==============================================================================
_generate_compose() {
	echo_progress_start "Generating Docker Compose configuration"

	local uid gid
	uid=$(id -u "$user")
	gid=$(id -g "$user")

	local auth_password
	auth_password=$(swizdb get "${app_name}/auth_password" 2>/dev/null)
	local ui_secret
	ui_secret=$(swizdb get "${app_name}/ui_secret" 2>/dev/null)

	cat >"${app_dir}/docker-compose.yml" <<COMPOSE
services:
  autopulse:
    image: ${app_image_api}
    container_name: autopulse
    restart: unless-stopped
    network_mode: host
    user: "${uid}:${gid}"
    environment:
      AUTOPULSE__APP__DATABASE_URL: sqlite://data/autopulse.db
    volumes:
      - ${app_dir}/config.yaml:/app/config.yaml:ro
      - ${app_dir}/data:/app/data
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  autopulse-ui:
    image: ${app_image_ui}
    container_name: autopulse-ui
    restart: unless-stopped
    network_mode: host
    environment:
      BASE_PATH: /autopulse
      ORIGIN: http://localhost:${app_ui_port}
      PORT: "${app_ui_port}"
      FORCE_AUTH: "true"
      FORCE_SERVER_URL: http://localhost:${app_port}
      FORCE_USERNAME: ${user}
      FORCE_PASSWORD: ${auth_password}
      SECRET: ${ui_secret}
    depends_on:
      - autopulse
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
COMPOSE

	chmod 600 "${app_dir}/docker-compose.yml"
	chown root:root "${app_dir}/docker-compose.yml"

	echo_progress_done "Docker Compose configuration generated"
}

# ==============================================================================
# Systemd Service
# ==============================================================================
_systemd_autopulse() {
	echo_progress_start "Installing systemd service"

	cat >"/etc/systemd/system/${app_servicefile}" <<EOF
[Unit]
Description=${app_pretty} (Media Server Library Notifier)
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

	_systemd_unit_written="$app_servicefile"
	systemctl -q daemon-reload
	systemctl enable -q "$app_servicefile"
	echo_progress_done "Systemd service installed and enabled"
}

# ==============================================================================
# Nginx Reverse Proxy
# ==============================================================================
_nginx_autopulse() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx"

		cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_ui_port}/${app_baseurl}/;
			    proxy_set_header Host \$host;
			    proxy_set_header X-Real-IP \$remote_addr;
			    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
			    proxy_set_header X-Forwarded-Host \$host;
			    proxy_set_header X-Forwarded-Proto \$scheme;
			    proxy_http_version 1.1;
			    proxy_set_header Upgrade \$http_upgrade;
			    proxy_set_header Connection \$http_connection;

			    auth_basic "What's the password?";
			    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
			}

			location ^~ /${app_baseurl}/triggers/ {
			    auth_request off;
			    proxy_pass http://127.0.0.1:${app_port}/triggers/;
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
		echo_info "${app_pretty} API running on port ${app_port}, UI on port ${app_ui_port}"
	fi
}

# ==============================================================================
# Panel Registration
# ==============================================================================
_panel_autopulse() {
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
}

# ==============================================================================
# Arr Webhook Auto-Configuration
# ==============================================================================
_configure_arr_webhooks() {
	if [[ ${#ARR_NAMES[@]} -eq 0 ]]; then
		return 0
	fi

	echo_progress_start "Configuring arr webhooks"

	local i
	for ((i = 0; i < ${#ARR_NAMES[@]}; i++)); do
		local name="${ARR_NAMES[$i]}"
		local port="${ARR_PORTS[$i]}"
		local apikey="${ARR_APIKEYS[$i]}"
		local urlbase="${ARR_URLBASES[$i]}"
		local base_url="http://127.0.0.1:${port}"
		[[ -n "$urlbase" ]] && base_url="${base_url}/${urlbase#/}"

		local webhook_url="http://localhost:${app_port}/triggers/${name}"

		_verbose "Configuring webhook for ${name} -> ${webhook_url}"

		# Check for existing Autopulse notification
		local existing
		existing=$(curl -s --config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
			"${base_url}/api/v3/notification" 2>/dev/null) || true

		local already_exists=false
		if [[ -n "$existing" ]] && echo "$existing" | jq -e '.[] | select(.name == "Autopulse")' >/dev/null 2>&1; then
			already_exists=true
		fi

		if [[ "$already_exists" == "true" ]]; then
			_verbose "Autopulse webhook already configured in ${name}, skipping"
			continue
		fi

		# Determine event field names based on arr type
		local payload
		payload=$(cat <<-JSONEOF
		{
		  "name": "Autopulse",
		  "implementation": "Webhook",
		  "implementationName": "Webhook",
		  "configContract": "WebhookSettings",
		  "enable": true,
		  "onGrab": false,
		  "onDownload": true,
		  "onUpgrade": true,
		  "onRename": true,
		  "onSeriesDelete": true,
		  "onEpisodeFileDelete": true,
		  "onMovieDelete": true,
		  "onMovieFileDelete": true,
		  "onAlbumDelete": true,
		  "onTrackFileDelete": true,
		  "onBookDelete": true,
		  "onBookFileDelete": true,
		  "onHealthIssue": false,
		  "supportsOnGrab": true,
		  "supportsOnDownload": true,
		  "supportsOnUpgrade": true,
		  "supportsOnRename": true,
		  "supportsOnSeriesDelete": true,
		  "supportsOnEpisodeFileDelete": true,
		  "supportsOnMovieDelete": true,
		  "supportsOnMovieFileDelete": true,
		  "supportsOnAlbumDelete": true,
		  "supportsOnTrackFileDelete": true,
		  "supportsOnBookDelete": true,
		  "supportsOnBookFileDelete": true,
		  "fields": [
		    {"name": "url", "value": "${webhook_url}"},
		    {"name": "method", "value": 1}
		  ],
		  "tags": []
		}
		JSONEOF
		)

		local http_code
		http_code=$(curl -s -o /dev/null -w '%{http_code}' \
			--config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
			-X POST "${base_url}/api/v3/notification" \
			-H "Content-Type: application/json" \
			-d "$payload" 2>/dev/null) || true

		if [[ "$http_code" == "201" ]]; then
			_verbose "Webhook added to ${name}"
		else
			echo_warn "Failed to add webhook to ${name} (HTTP ${http_code})"
		fi
	done

	echo_progress_done "Arr webhooks configured"
}

# ==============================================================================
# Optionally disable existing media server Connect entries
# ==============================================================================
_disable_arr_media_connects() {
	if [[ ${#ARR_NAMES[@]} -eq 0 ]]; then
		return 0
	fi

	if ! ask "Disable existing Emby/Jellyfin/Plex Connect entries in arr instances?\n(These trigger slow full library scans that Autopulse replaces)" Y; then
		return 0
	fi

	local i
	for ((i = 0; i < ${#ARR_NAMES[@]}; i++)); do
		local name="${ARR_NAMES[$i]}"
		local port="${ARR_PORTS[$i]}"
		local apikey="${ARR_APIKEYS[$i]}"
		local urlbase="${ARR_URLBASES[$i]}"
		local base_url="http://127.0.0.1:${port}"
		[[ -n "$urlbase" ]] && base_url="${base_url}/${urlbase#/}"

		local notifications
		notifications=$(curl -s --config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
			"${base_url}/api/v3/notification" 2>/dev/null) || continue

		# Find Emby/Jellyfin/Plex connect entries and disable them
		local ids_to_disable
		ids_to_disable=$(echo "$notifications" | jq -r \
			'.[] | select(.implementation == "Emby" or .implementation == "Jellyfin" or .implementation == "PlexServer" or .implementation == "Plex") | select(.enable == true) | .id' 2>/dev/null) || continue

		for nid in $ids_to_disable; do
			local existing_notification
			existing_notification=$(echo "$notifications" | jq ".[] | select(.id == $nid)" 2>/dev/null) || continue

			# Set enable=false
			local updated
			updated=$(echo "$existing_notification" | jq '.enable = false' 2>/dev/null) || continue

			curl -s -o /dev/null \
				--config <(printf 'header = "X-Api-Key: %s"' "$apikey") \
				-X PUT "${base_url}/api/v3/notification/${nid}" \
				-H "Content-Type: application/json" \
				-d "$updated" 2>/dev/null || true

			local impl_name
			impl_name=$(echo "$existing_notification" | jq -r '.implementation' 2>/dev/null) || impl_name="unknown"
			_verbose "Disabled ${impl_name} connect in ${name} (id=${nid})"
		done
	done

	echo_info "Existing media server Connect entries disabled"
}
