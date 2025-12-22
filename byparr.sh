#!/bin/bash
# byparr installer
# STiXzoOR 2025
# Usage: bash byparr.sh [--remove [--force]]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

PANEL_HELPER_LOCAL="/opt/swizzin/panel_helpers.sh"
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

app_name="byparr"

# Get owner from swizdb (needed for both install and remove)
if ! BYPARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
	BYPARR_OWNER="$(_get_master_username)"
fi
user="$BYPARR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=8191
app_reqs=("curl" "git")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/byparr.png"

if [ ! -d "$swiz_configdir" ]; then
	mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

_install_uv() {
	# Install uv for the app user if not present
	if su - "$user" -c 'command -v uv >/dev/null 2>&1'; then
		echo_info "uv already installed for $user"
		return 0
	fi

	echo_progress_start "Installing uv for $user"
	su - "$user" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >>"$log" 2>&1 || {
		echo_error "Failed to install uv"
		exit 1
	}
	echo_progress_done "uv installed"
}

_install_byparr() {
	if [ ! -d "$app_configdir" ]; then
		mkdir -p "$app_configdir"
	fi
	chown -R "$user":"$user" "$app_configdir"

	apt_install "${app_reqs[@]}"

	_install_uv

	echo_progress_start "Cloning ${app_name^} repository"

	if [ -d "$app_dir" ]; then
		rm -rf "$app_dir"
	fi

	git clone https://github.com/ThePhaseless/Byparr.git "$app_dir" >>"$log" 2>&1 || {
		echo_error "Failed to clone ${app_name^} repository"
		exit 1
	}
	chown -R "$user":"$user" "$app_dir"
	echo_progress_done "Repository cloned"

	echo_progress_start "Installing ${app_name^} dependencies"
	su - "$user" -c "cd '$app_dir' && uv sync" >>"$log" 2>&1 || {
		echo_error "Failed to install ${app_name^} dependencies"
		exit 1
	}
	echo_progress_done "Dependencies installed"

	# Create env file
	cat >"$app_configdir/env.conf" <<EOF
# Byparr environment
HOST=127.0.0.1
PORT=$app_port
EOF

	chown -R "$user":"$user" "$app_configdir"
}

_remove_byparr() {
	local force="$1"
	if [ "$force" != "--force" ] && [ ! -f "/install/.$app_lockname.lock" ]; then
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

	# Stop and disable service
	echo_progress_start "Stopping and disabling ${app_name^} service"
	systemctl stop "$app_servicefile" 2>/dev/null || true
	systemctl disable "$app_servicefile" 2>/dev/null || true
	rm -f "/etc/systemd/system/$app_servicefile"
	systemctl daemon-reload
	echo_progress_done "Service removed"

	# Remove application directory
	echo_progress_start "Removing ${app_name^} application"
	rm -rf "$app_dir"
	echo_progress_done "Application removed"

	# Remove from panel
	_load_panel_helper
	if command -v panel_unregister_app >/dev/null 2>&1; then
		echo_progress_start "Removing from panel"
		panel_unregister_app "$app_name"
		echo_progress_done "Removed from panel"
	fi

	# Remove config directory if purging
	if [ "$purgeconfig" = "true" ]; then
		echo_progress_start "Purging configuration files"
		rm -rf "$app_configdir"
		echo_progress_done "Configuration purged"
		# Remove swizdb entry
		swizdb clear "$app_name/owner" 2>/dev/null || true
	else
		echo_info "Configuration files kept at: $app_configdir"
	fi

	# Remove lock file
	rm -f "/install/.$app_lockname.lock"

	echo_success "${app_name^} has been removed"
	exit 0
}

_systemd_byparr() {
	echo_progress_start "Installing Systemd service"

	cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - FlareSolverr alternative using Camoufox
After=network.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_dir
EnvironmentFile=$app_configdir/env.conf
ExecStart=/home/${user}/.local/bin/uv run python main.py
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

	systemctl -q daemon-reload
	systemctl enable --now -q "$app_servicefile"
	sleep 1
	echo_progress_done "${app_name^} service installed and enabled"
	echo_info "${app_name^} is running on http://127.0.0.1:$app_port"
}

# Handle --remove flag
if [[ "$1" == "--remove" ]]; then
	_remove_byparr "$2"
fi

# Check for conflicting FlareSolverr installation
if [[ -f "/install/.flaresolverr.lock" ]]; then
	echo_warn "FlareSolverr is installed and uses the same port (8191)"
	echo_warn "Both services cannot run simultaneously"
	if ! ask "Would you like to remove FlareSolverr and continue with Byparr installation?" N; then
		echo_info "Installation cancelled"
		exit 0
	fi
	# Remove FlareSolverr
	echo_info "Removing FlareSolverr..."
	systemctl stop flaresolverr 2>/dev/null || true
	systemctl disable flaresolverr 2>/dev/null || true
	rm -f /etc/systemd/system/flaresolverr.service
	systemctl daemon-reload
	rm -rf /opt/flaresolverr
	rm -f /install/.flaresolverr.lock
	_load_panel_helper
	if command -v panel_unregister_app >/dev/null 2>&1; then
		panel_unregister_app "flaresolverr"
	fi
	echo_info "FlareSolverr removed"
fi

# Set owner for install
if [ -n "$BYPARR_OWNER" ]; then
	echo_info "Setting ${app_name^} owner = $BYPARR_OWNER"
	swizdb set "$app_name/owner" "$BYPARR_OWNER"
fi

_install_byparr
_systemd_byparr

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Byparr" \
		"" \
		"http://127.0.0.1:$app_port" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
