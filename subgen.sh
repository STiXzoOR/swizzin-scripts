#!/bin/bash
# subgen installer
# STiXzoOR 2025
# Usage: bash subgen.sh [--remove [--force]]

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

app_name="subgen"

# Get owner from swizdb (needed for both install and remove)
if ! SUBGEN_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
	SUBGEN_OWNER="$(_get_master_username)"
fi
user="$SUBGEN_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl" "git" "ffmpeg")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"
app_icon_name="$app_name"
app_icon_url="https://raw.githubusercontent.com/McCloudS/subgen/main/icon.png"

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

_install_subgen() {
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

	git clone https://github.com/McCloudS/subgen.git "$app_dir" >>"$log" 2>&1 || {
		echo_error "Failed to clone ${app_name^} repository"
		exit 1
	}
	chown -R "$user":"$user" "$app_dir"
	echo_progress_done "Repository cloned"

	echo_progress_start "Installing ${app_name^} dependencies"

	# Create pyproject.toml for uv if only requirements.txt exists
	if [ -f "$app_dir/requirements.txt" ] && [ ! -f "$app_dir/pyproject.toml" ]; then
		# Build dependencies array from requirements.txt (strip comments)
		deps_array=$(grep -vE '^\s*#|^\s*$' "$app_dir/requirements.txt" | sed 's/\s*#.*//' | sed 's/.*/"&",/' | tr '\n' ' ' | sed 's/, $//')
		cat >"$app_dir/pyproject.toml" <<PYPROJ
[project]
name = "subgen"
version = "0.0.0"
requires-python = ">=3.9,<3.12"
dependencies = [$deps_array]
PYPROJ
	fi

	su - "$user" -c "cd '$app_dir' && uv sync" >>"$log" 2>&1 || {
		echo_error "Failed to install ${app_name^} dependencies"
		exit 1
	}

	echo_progress_done "Dependencies installed"

	# Detect CPU thread count for Whisper
	cpu_threads=$(nproc 2>/dev/null || echo 4)
	if [ "$cpu_threads" -gt 8 ]; then
		cpu_threads=8
	fi

	# Create env file with sensible defaults
	cat >"$app_configdir/env.conf" <<EOF
# Subgen environment
# Webhook port for Plex/Jellyfin/Emby notifications
WEBHOOK_PORT=$app_port

# Whisper settings
WHISPER_MODEL=medium
TRANSCRIBE_DEVICE=cpu
WHISPER_THREADS=$cpu_threads

# Subtitle settings
WORD_LEVEL_HIGHLIGHT=False
SUBTITLE_FORMAT=srt

# Debug
DEBUG=False
EOF

	chown -R "$user":"$user" "$app_configdir"
	echo_info "Configure Plex/Jellyfin/Emby webhook to: http://<server>:$app_port/webhook"
}

_remove_subgen() {
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

_systemd_subgen() {
	echo_progress_start "Installing Systemd service"

	cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - Automatic subtitle generation using Whisper
After=network.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_dir
EnvironmentFile=$app_configdir/env.conf
ExecStart=/home/${user}/.local/bin/uv run python launcher.py -u -i -s
Restart=on-failure
RestartSec=10
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

	systemctl -q daemon-reload
	systemctl enable --now -q "$app_servicefile"
	sleep 1
	echo_progress_done "${app_name^} service installed and enabled"
	echo_info "${app_name^} webhook available at http://127.0.0.1:$app_port/webhook"
}

# Handle --remove flag
if [ "$1" = "--remove" ]; then
	_remove_subgen "$2"
fi

# Set owner for install
if [ -n "$SUBGEN_OWNER" ]; then
	echo_info "Setting ${app_name^} owner = $SUBGEN_OWNER"
	swizdb set "$app_name/owner" "$SUBGEN_OWNER"
fi

_install_subgen
_systemd_subgen

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Subgen" \
		"" \
		"http://127.0.0.1:$app_port" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
