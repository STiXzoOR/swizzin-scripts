#!/bin/bash
# byparr installer
# STiXzoOR 2025

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

if [ -z "$BYPARR_OWNER" ]; then
	if ! BYPARR_OWNER="$(swizdb get "$app_name/owner")"; then
		BYPARR_OWNER="$(_get_master_username)"
		echo_info "Setting ${app_name^} owner = $BYPARR_OWNER"
		swizdb set "$app_name/owner" "$BYPARR_OWNER"
	fi
else
	echo_info "Setting ${app_name^} owner = $BYPARR_OWNER"
	swizdb set "$app_name/owner" "$BYPARR_OWNER"
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
app_icon_url="https://raw.githubusercontent.com/ThePhaseless/Byparr/refs/heads/main/icon/1080x1080.png"

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
