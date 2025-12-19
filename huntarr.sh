#!/bin/bash
# huntarr installer
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

app_name="huntarr"

if [ -z "$HUNTARR_OWNER" ]; then
	if ! HUNTARR_OWNER="$(swizdb get "$app_name/owner")"; then
		HUNTARR_OWNER="$(_get_master_username)"
		echo_info "Setting ${app_name^} owner = $HUNTARR_OWNER"
		swizdb set "$app_name/owner" "$HUNTARR_OWNER"
	fi
else
	echo_info "Setting ${app_name^} owner = $HUNTARR_OWNER"
	swizdb set "$app_name/owner" "$HUNTARR_OWNER"
fi

user="$HUNTARR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl" "git")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://raw.githubusercontent.com/plexguide/Huntarr.io/refs/heads/main/docs/images/huntarr-logo.png"

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

_install_huntarr() {
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

	git clone https://github.com/plexguide/Huntarr.io.git "$app_dir" >>"$log" 2>&1 || {
		echo_error "Failed to clone ${app_name^} repository"
		exit 1
	}
	chown -R "$user":"$user" "$app_dir"
	echo_progress_done "Repository cloned"

	echo_progress_start "Installing ${app_name^} dependencies"

	# Create pyproject.toml for uv if only requirements.txt exists
	if [ -f "$app_dir/requirements.txt" ] && [ ! -f "$app_dir/pyproject.toml" ]; then
		cat >"$app_dir/pyproject.toml" <<PYPROJ
[project]
name = "huntarr"
version = "0.0.0"
requires-python = ">=3.11"
dependencies = []

[tool.uv]
PYPROJ
		# Add dependencies from requirements.txt
		su - "$user" -c "cd '$app_dir' && uv add \$(cat requirements.txt | grep -v '^#' | grep -v '^\$' | tr '\n' ' ')" >>"$log" 2>&1 || {
			echo_error "Failed to add ${app_name^} dependencies"
			exit 1
		}
	else
		su - "$user" -c "cd '$app_dir' && uv sync" >>"$log" 2>&1 || {
			echo_error "Failed to install ${app_name^} dependencies"
			exit 1
		}
	fi

	echo_progress_done "Dependencies installed"

	# Get system timezone
	system_tz="UTC"
	if [ -f /etc/timezone ]; then
		system_tz=$(cat /etc/timezone)
	elif [ -L /etc/localtime ]; then
		system_tz=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
	fi

	# Create env file
	cat >"$app_configdir/env.conf" <<EOF
# Huntarr environment
TZ=$system_tz
BASE_URL=/$app_baseurl
CONFIG_DIR=$app_configdir
EOF

	chown -R "$user":"$user" "$app_configdir"
}

_systemd_huntarr() {
	echo_progress_start "Installing Systemd service"

	cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - Automated media discovery for *arr apps
After=network.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_dir
EnvironmentFile=$app_configdir/env.conf
Environment=PORT=$app_port
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
}

_nginx_huntarr() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx"
		cat >/etc/nginx/apps/$app_name.conf <<-NGX
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
		echo_info "${app_name^} will run on port $app_port"
	fi
}

_install_huntarr
_systemd_huntarr
_nginx_huntarr

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Huntarr" \
		"/$app_baseurl" \
		"" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
