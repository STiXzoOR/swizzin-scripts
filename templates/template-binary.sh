#!/bin/bash
# ==============================================================================
# BINARY INSTALLER TEMPLATE
# ==============================================================================
# Template for installing single-binary applications to /usr/bin
# Examples: decypharr, notifiarr
#
# Usage: bash <appname>.sh [--remove [--force]]
#
# CUSTOMIZATION POINTS (search for "# CUSTOMIZE:"):
# 1. App variables (name, port, binary URL, icon, etc.)
# 2. Architecture mapping in _install_<app>()
# 3. Config file format in _install_<app>()
# 4. Systemd service options in _systemd_<app>()
# 5. Nginx location config in _nginx_<app>()
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
# App Configuration
# ==============================================================================
# CUSTOMIZE: Set all app-specific variables here

app_name="myapp"
app_pretty="Myapp"             # Display name (capitalized)
app_lockname="${app_name//-/}" # Lock file name (no hyphens)
app_baseurl="${app_name}"      # URL path (e.g., /myapp)

# Binary location
app_dir="/usr/bin"
app_binary="${app_name}"

# Port allocation
app_port=$(port 10000 12000)

# Dependencies (apt packages)
app_reqs=("curl")

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

# Config directories
swiz_configdir="/home/${user}/.config"
app_configdir="${swiz_configdir}/${app_pretty}"

# Ensure base config directory exists
if [[ ! -d "$swiz_configdir" ]]; then
	mkdir -p "$swiz_configdir"
fi
chown "${user}:${user}" "$swiz_configdir"

# ==============================================================================
# Installation
# ==============================================================================
_install_myapp() {
	# Create config directory
	if [[ ! -d "$app_configdir" ]]; then
		mkdir -p "$app_configdir"
	fi
	chown -R "${user}:${user}" "$app_configdir"

	# Install dependencies
	apt_install "${app_reqs[@]}"

	echo_progress_start "Downloading release archive"

	# CUSTOMIZE: Map architecture names to what the release uses
	case "$(_os_arch)" in
	"amd64") arch='x86_64' ;;
	"arm64") arch='arm64' ;;
	"armhf") arch='armv6' ;;
	*)
		echo_error "Architecture not supported"
		exit 1
		;;
	esac

	# CUSTOMIZE: Set the GitHub API URL for releases
	local github_repo="owner/repo"
	latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" |
		grep "browser_download_url" |
		grep "${arch}" |
		grep ".tar.gz" |
		cut -d\" -f4) || {
		echo_error "Failed to query GitHub for latest version"
		exit 1
	}

	if ! curl -fsSL "$latest" -o "/tmp/${app_name}.tar.gz" >>"$log" 2>&1; then
		echo_error "Download failed"
		exit 1
	fi
	echo_progress_done "Archive downloaded"

	echo_progress_start "Extracting archive"
	tar xf "/tmp/${app_name}.tar.gz" --directory "${app_dir}/" >>"$log" 2>&1 || {
		echo_error "Failed to extract"
		exit 1
	}
	rm -f "/tmp/${app_name}.tar.gz"
	chmod +x "${app_dir}/${app_binary}"
	echo_progress_done "Archive extracted"

	# CUSTOMIZE: Create default config file
	echo_progress_start "Creating default config"
	cat >"${app_configdir}/config.json" <<-CFG
		{
		  "port": ${app_port},
		  "url_base": "/${app_baseurl}/"
		}
	CFG
	chown -R "${user}:${user}" "$app_configdir"
	echo_progress_done "Default config created"
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

	# Stop and disable service
	echo_progress_start "Stopping and disabling service"
	systemctl stop "$app_servicefile" 2>/dev/null || true
	systemctl disable "$app_servicefile" 2>/dev/null || true
	rm -f "/etc/systemd/system/${app_servicefile}"
	systemctl daemon-reload
	echo_progress_done "Service removed"

	# Remove binary
	echo_progress_start "Removing binary"
	rm -f "${app_dir}/${app_binary}"
	echo_progress_done "Binary removed"

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

# ==============================================================================
# Systemd Service
# ==============================================================================
_systemd_myapp() {
	echo_progress_start "Installing systemd service"

	# CUSTOMIZE: Adjust ExecStart and other service options as needed
	cat >"/etc/systemd/system/${app_servicefile}" <<-EOF
		[Unit]
		Description=${app_pretty} Daemon
		After=syslog.target network.target

		[Service]
		User=${user}
		Group=${app_group}
		Type=simple
		ExecStart=${app_dir}/${app_binary} --config=${app_configdir}
		WorkingDirectory=${app_configdir}
		TimeoutStopSec=20
		KillMode=process
		Restart=on-failure
		RestartSec=5

		[Install]
		WantedBy=multi-user.target
	EOF

	systemctl daemon-reload
	systemctl enable --now "$app_servicefile" >>"$log" 2>&1
	echo_progress_done "Service installed and enabled"
}

# ==============================================================================
# Nginx Configuration
# ==============================================================================
_nginx_myapp() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx"

		# CUSTOMIZE: Adjust proxy settings as needed
		cat >"/etc/nginx/apps/${app_name}.conf" <<-NGX
			location /${app_baseurl} {
			    return 301 /${app_baseurl}/;
			}

			location ^~ /${app_baseurl}/ {
			    proxy_pass http://127.0.0.1:${app_port}/${app_baseurl}/;
			    proxy_set_header Host \$host;
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
			    auth_basic off;
			    proxy_pass http://127.0.0.1:${app_port}/${app_baseurl}/api;
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

# Handle --remove flag
if [[ "$1" == "--remove" ]]; then
	_remove_myapp "$2"
fi

# Set owner in swizdb
echo_info "Setting ${app_pretty} owner = ${user}"
swizdb set "${app_name}/owner" "$user"

# Run installation
_install_myapp
_systemd_myapp
_nginx_myapp

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

echo_success "${app_pretty} installed"
echo_info "Access at: https://your-server/${app_baseurl}/"
