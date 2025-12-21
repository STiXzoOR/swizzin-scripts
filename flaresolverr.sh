#!/bin/bash
# flaresolverr installer
# STiXzoOR 2025
# Usage: bash flaresolverr.sh [--remove [--force]]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# Panel Helper - Download and cache for panel integration
PANEL_HELPER_LOCAL="/opt/swizzin/panel_helpers.sh"
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

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

app_name="flaresolverr"
app_pretty="FlareSolverr"
app_lockname="${app_name//-/}"

# Binary location - FlareSolverr extracts to a directory
app_dir="/opt/flaresolverr"
app_binary="flaresolverr"

# Port - 8191 is the default FlareSolverr port
app_port=8191

# Dependencies
app_reqs=("curl" "xvfb")

# Systemd
app_servicefile="${app_name}.service"

# Panel icon
app_icon_name="${app_name}"
app_icon_url="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/flaresolverr.png"

# Get owner from swizdb or fall back to master user
if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
	app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Config directories
swiz_configdir="/home/${user}/.config"
app_configdir="${swiz_configdir}/${app_pretty}"

# Ensure base config directory exists
if [[ ! -d "$swiz_configdir" ]]; then
	mkdir -p "$swiz_configdir"
fi
chown "${user}:${user}" "$swiz_configdir"

_install_flaresolverr() {
	# Create config directory
	if [[ ! -d "$app_configdir" ]]; then
		mkdir -p "$app_configdir"
	fi
	chown -R "${user}:${user}" "$app_configdir"

	# Install dependencies
	apt_install "${app_reqs[@]}"

	# Check architecture - FlareSolverr only supports x64
	case "$(_os_arch)" in
	"amd64") arch='linux_x64' ;;
	*)
		echo_error "FlareSolverr only supports amd64/x64 architecture"
		exit 1
		;;
	esac

	echo_progress_start "Downloading FlareSolverr"

	# Get latest release URL
	local github_repo="FlareSolverr/FlareSolverr"
	latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" |
		grep "browser_download_url" |
		grep "${arch}" |
		grep ".tar.gz" |
		cut -d\" -f4) || {
		echo_error "Failed to query GitHub for latest version"
		exit 1
	}

	if [[ -z "$latest" ]]; then
		echo_error "Could not find download URL for ${arch}"
		exit 1
	fi

	if ! curl -fsSL "$latest" -o "/tmp/${app_name}.tar.gz" >>"$log" 2>&1; then
		echo_error "Download failed"
		exit 1
	fi
	echo_progress_done "Downloaded"

	echo_progress_start "Extracting archive"

	# Remove old installation if exists
	if [[ -d "$app_dir" ]]; then
		rm -rf "$app_dir"
	fi

	# Create directory and extract
	mkdir -p "$app_dir"
	tar xf "/tmp/${app_name}.tar.gz" --strip-components=1 -C "$app_dir" >>"$log" 2>&1 || {
		echo_error "Failed to extract"
		exit 1
	}
	rm -f "/tmp/${app_name}.tar.gz"
	chown -R "${user}:${user}" "$app_dir"
	chmod +x "${app_dir}/${app_binary}"
	echo_progress_done "Extracted"

	# Create environment config file
	echo_progress_start "Creating configuration"
	cat >"${app_configdir}/env.conf" <<-EOF
		# FlareSolverr Configuration
		# See: https://github.com/FlareSolverr/FlareSolverr#environment-variables

		# Server settings
		HOST=127.0.0.1
		PORT=${app_port}

		# Logging
		LOG_LEVEL=info
		LOG_HTML=false

		# Browser settings
		HEADLESS=true

		# Timeouts (in milliseconds)
		BROWSER_TIMEOUT=40000
		TEST_URL=https://www.google.com

		# TZ for proper timezone (uncomment and set if needed)
		# TZ=UTC
	EOF
	chown -R "${user}:${user}" "$app_configdir"
	echo_progress_done "Configuration created"
}

_remove_flaresolverr() {
	local force="$1"

	if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_pretty} is not installed (use --force to override)"
		exit 1
	fi

	echo_info "Removing ${app_pretty}..."

	# Ask about purging configuration (skip if --force)
	if [[ "$force" == "--force" ]]; then
		purgeconfig="true"
	elif ask "Would you like to purge the configuration?" N; then
		purgeconfig="true"
	else
		purgeconfig="false"
	fi

	# Stop and disable service
	echo_progress_start "Stopping and disabling service"
	systemctl stop "$app_servicefile" 2>/dev/null || true
	systemctl disable "$app_servicefile" 2>/dev/null || true
	rm -f "/etc/systemd/system/${app_servicefile}"
	systemctl daemon-reload
	echo_progress_done "Service removed"

	# Remove application directory
	echo_progress_start "Removing application"
	rm -rf "$app_dir"
	echo_progress_done "Application removed"

	# Remove from panel
	_load_panel_helper
	if command -v panel_unregister_app >/dev/null 2>&1; then
		echo_progress_start "Removing from panel"
		panel_unregister_app "$app_name"
		echo_progress_done "Removed from panel"
	fi

	# Purge config if requested
	if [[ "$purgeconfig" == "true" ]]; then
		echo_progress_start "Purging configuration files"
		rm -rf "$app_configdir"
		swizdb clear "${app_name}/owner" 2>/dev/null || true
		echo_progress_done "Configuration purged"
	else
		echo_info "Configuration files kept at: ${app_configdir}"
	fi

	# Remove lock file
	rm -f "/install/.${app_lockname}.lock"

	echo_success "${app_pretty} has been removed"
	exit 0
}

_systemd_flaresolverr() {
	echo_progress_start "Installing systemd service"

	cat >"/etc/systemd/system/${app_servicefile}" <<-EOF
		[Unit]
		Description=FlareSolverr - Proxy server to bypass Cloudflare protection
		After=network.target

		[Service]
		Type=simple
		User=${user}
		Group=${app_group}
		WorkingDirectory=${app_dir}
		EnvironmentFile=${app_configdir}/env.conf
		ExecStart=${app_dir}/${app_binary}
		TimeoutStopSec=20
		KillMode=process
		Restart=on-failure
		RestartSec=5

		[Install]
		WantedBy=multi-user.target
	EOF

	systemctl daemon-reload
	systemctl enable --now "$app_servicefile" >>"$log" 2>&1
	sleep 2
	echo_progress_done "Service installed and enabled"
}

# Handle --remove flag
if [[ "$1" == "--remove" ]]; then
	_remove_flaresolverr "$2"
fi

# Check for conflicting Byparr installation
if [[ -f "/install/.byparr.lock" ]]; then
	echo_warn "Byparr is installed and uses the same port (8191)"
	echo_warn "Both services cannot run simultaneously"
	if ! ask "Would you like to remove Byparr and continue with FlareSolverr installation?" N; then
		echo_info "Installation cancelled"
		exit 0
	fi
	# Remove Byparr
	echo_info "Removing Byparr..."
	systemctl stop byparr 2>/dev/null || true
	systemctl disable byparr 2>/dev/null || true
	rm -f /etc/systemd/system/byparr.service
	systemctl daemon-reload
	rm -rf /opt/byparr
	rm -f /install/.byparr.lock
	_load_panel_helper
	if command -v panel_unregister_app >/dev/null 2>&1; then
		panel_unregister_app "byparr"
	fi
	echo_info "Byparr removed"
fi

# Set owner in swizdb
echo_info "Setting ${app_pretty} owner = ${user}"
swizdb set "${app_name}/owner" "$user"

# Run installation
_install_flaresolverr
_systemd_flaresolverr

# Register with panel (no nginx - API-only service)
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"$app_pretty" \
		"" \
		"http://127.0.0.1:${app_port}" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

# Create lock file
touch "/install/.${app_lockname}.lock"

echo_success "${app_pretty} installed"
echo_info "FlareSolverr is running on http://127.0.0.1:${app_port}"
echo_info "Configure in Prowlarr/Jackett as FlareSolverr proxy: http://127.0.0.1:${app_port}"
