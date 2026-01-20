#!/bin/bash
# cleanuparr installer
# STiXzoOR 2025
# Usage: bash cleanuparr.sh [--remove [--force]] [--register-panel]

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
touch $log

app_name="cleanuparr"

# Get owner from swizdb (needed for both install and remove)
if ! CLEANUPARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
	CLEANUPARR_OWNER="$(_get_master_username)"
fi
user="$CLEANUPARR_OWNER"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("unzip")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_binary="Cleanuparr"
app_configdir="$app_dir/config"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/cleanuparr.png"

_install_cleanuparr() {
	if [ ! -d "$app_dir" ]; then
		mkdir -p "$app_dir"
	fi
	if [ ! -d "$app_configdir" ]; then
		mkdir -p "$app_configdir"
	fi
	chown -R "$user":"$user" "$app_dir"

	apt_install "${app_reqs[@]}"

	echo_progress_start "Downloading release archive"

	case "$(_os_arch)" in
	"amd64") arch='linux-amd64' ;;
	"arm64") arch="linux-arm64" ;;
	*)
		echo_error "Arch not supported"
		exit 1
		;;
	esac

	latest=$(curl -sL https://api.github.com/repos/Cleanuparr/Cleanuparr/releases/latest | grep "browser_download_url" | grep "$arch" | grep ".zip" | cut -d \" -f4) || {
		echo_error "Failed to query GitHub for latest version"
		exit 1
	}

	if ! curl "$latest" -L -o "/tmp/$app_name.zip" >>"$log" 2>&1; then
		echo_error "Download failed, exiting"
		exit 1
	fi
	echo_progress_done "Archive downloaded"

	echo_progress_start "Extracting archive"
	# Extract to temp location first (zip contains versioned subfolder)
	rm -rf "/tmp/$app_name-extract"
	mkdir -p "/tmp/$app_name-extract"
	unzip -o "/tmp/$app_name.zip" -d "/tmp/$app_name-extract" >>"$log" 2>&1 || {
		echo_error "Failed to extract"
		exit 1
	}
	rm -f "/tmp/$app_name.zip"

	# Move contents from versioned subfolder to app_dir
	extracted_folder=$(find "/tmp/$app_name-extract" -maxdepth 1 -type d -name "Cleanuparr-*" | head -1)
	if [ -z "$extracted_folder" ]; then
		echo_error "Could not find extracted folder"
		exit 1
	fi
	# Move all files from extracted folder to app_dir (preserve config if exists)
	mv "$extracted_folder"/* "$app_dir/" >>"$log" 2>&1
	rm -rf "/tmp/$app_name-extract"
	echo_progress_done "Archive extracted"

	chmod +x "$app_dir/$app_binary"

	echo_progress_start "Creating default config"
	cat >"$app_configdir/cleanuparr.json" <<CFG
{
  "PORT": ${app_port},
  "BIND_ADDRESS": "127.0.0.1",
  "BASE_PATH": "/${app_baseurl}"
}
CFG

	chown -R "$user":"$user" "$app_dir"
	echo_progress_done "Default config created"
}

_remove_cleanuparr() {
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

	# Remove binary/directory
	echo_progress_start "Removing ${app_name^} files"
	if [ "$purgeconfig" = "true" ]; then
		rm -rf "$app_dir"
		echo_progress_done "All files removed"
	else
		rm -f "$app_dir/$app_binary"
		echo_progress_done "Binary removed (config kept at $app_configdir)"
	fi

	# Remove nginx config
	if [ -f "/etc/nginx/apps/$app_name.conf" ]; then
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

	# Remove swizdb entry
	if [ "$purgeconfig" = "true" ]; then
		swizdb clear "$app_name/owner" 2>/dev/null || true
	fi

	# Remove lock file
	rm -f "/install/.$app_lockname.lock"

	echo_success "${app_name^} has been removed"
	exit 0
}

_systemd_cleanuparr() {
	echo_progress_start "Installing Systemd service"
	cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} Daemon
After=syslog.target network.target

[Service]
User=${user}
Group=${app_group}
Type=simple
WorkingDirectory=${app_dir}
ExecStart=${app_dir}/${app_binary}
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

	systemctl -q daemon-reload
	systemctl enable --now -q "$app_servicefile"
	sleep 1
	echo_progress_done "${app_name^} service installed and enabled"
}

_nginx_cleanuparr() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx"
		cat >/etc/nginx/apps/$app_name.conf <<-NGX
			location /$app_baseurl {
			  return 301 /$app_baseurl/;
			}

			location ^~ /$app_baseurl/ {
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/;
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

			location ^~ /$app_baseurl/api {
			    auth_request off;
			    proxy_pass http://127.0.0.1:$app_port/$app_baseurl/api;
			}
		NGX

		systemctl reload nginx
		echo_progress_done "Nginx configured"
	else
		echo_info "$app_name will run on port $app_port"
	fi
}

# Handle --remove flag
if [ "$1" = "--remove" ]; then
	_remove_cleanuparr "$2"
fi

# Handle --register-panel flag
if [ "$1" = "--register-panel" ]; then
	if [ ! -f "/install/.$app_lockname.lock" ]; then
		echo_error "${app_name^} is not installed"
		exit 1
	fi
	_load_panel_helper
	if command -v panel_register_app >/dev/null 2>&1; then
		panel_register_app \
			"$app_name" \
			"Cleanuparr" \
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

# Check if already installed
if [ -f "/install/.$app_lockname.lock" ]; then
	echo_info "${app_name^} is already installed"
else
	# Set owner for install
	if [ -n "$CLEANUPARR_OWNER" ]; then
		echo_info "Setting ${app_name^} owner = $CLEANUPARR_OWNER"
		swizdb set "$app_name/owner" "$CLEANUPARR_OWNER"
	fi

	_install_cleanuparr
	_systemd_cleanuparr
	_nginx_cleanuparr
fi

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Cleanuparr" \
		"/$app_baseurl" \
		"" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
