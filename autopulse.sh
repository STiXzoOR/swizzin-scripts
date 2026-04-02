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
