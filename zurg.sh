#!/bin/bash
# zurg installer
# STiXzoOR 2025

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

app_name="zurg"

if [ -z "$ZURG_OWNER" ]; then
	if ! ZURG_OWNER="$(swizdb get "$app_name/owner")"; then
		ZURG_OWNER="$(_get_master_username)"
		echo_info "Setting ${app_name^} owner = $ZURG_OWNER"
		swizdb set "$app_name/owner" "$ZURG_OWNER"
	fi
else
	echo_info "Setting ${app_name^} owner = $ZURG_OWNER"
	swizdb set "$app_name/owner" "$ZURG_OWNER"
fi

user="$ZURG_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name}"
app_group="$user"
app_port=9999
app_reqs=("curl" "rclone" "unzip" "fuse3")
app_servicefile="$app_name.service"
app_mount_servicefile="rclone-$app_name.service"
app_dir="/usr/bin"
app_binary="$app_name"
app_lockname="${app_name//-/}"
app_mount_point="/mnt/$app_name"
app_icon_name="placeholder"
app_icon_url=""

if [ ! -d "$swiz_configdir" ]; then
	mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

_install_zurg() {
	if [ ! -d "$app_configdir" ]; then
		mkdir -p "$app_configdir"
	fi
	chown -R "$user":"$user" "$app_configdir"

	apt_install "${app_reqs[@]}"

	# Prompt for Real-Debrid token if not already configured
	echo_info "Checking for Real-Debrid API token"
	if [ ! -f "$app_configdir/config.yml" ] || ! grep -qE '^token: .+' "$app_configdir/config.yml" 2>/dev/null; then
		echo_query "Paste your Real-Debrid API token" "from https://real-debrid.com/apitoken"
		read -r RD_TOKEN

		if [ -z "$RD_TOKEN" ]; then
			echo_error "Real-Debrid API token is required. Cannot continue!"
			exit 1
		fi
	else
		echo_info "Existing token found in config"
		RD_TOKEN=$(grep -E '^token: ' "$app_configdir/config.yml" | sed 's/token: //')
	fi

	echo_progress_start "Downloading release archive"

	case "$(_os_arch)" in
	"amd64") arch='linux-amd64' ;;
	"arm64") arch="linux-arm64" ;;
	"armhf") arch="linux-arm-6" ;;
	*)
		echo_error "Arch not supported"
		exit 1
		;;
	esac

	latest=$(curl -sL https://api.github.com/repos/debridmediamanager/zurg-testing/releases/latest | grep "browser_download_url" | grep "$arch" | cut -d \" -f4) || {
		echo_error "Failed to query GitHub for latest version"
		exit 1
	}

	if ! curl "$latest" -L -o "/tmp/$app_name.zip" >>"$log" 2>&1; then
		echo_error "Download failed, exiting"
		exit 1
	fi
	echo_progress_done "Archive downloaded"

	echo_progress_start "Extracting archive"

	unzip -o "/tmp/$app_name.zip" -d "/tmp/$app_name" >>"$log" 2>&1 || {
		echo_error "Failed to extract"
		exit 1
	}
	mv "/tmp/$app_name/$app_binary" "$app_dir/$app_binary"
	rm -rf "/tmp/$app_name.zip" "/tmp/$app_name"
	chmod +x "$app_dir/$app_binary"
	echo_progress_done "Archive extracted"

	echo_progress_start "Creating configuration"

	# Create config.yml
	cat >"$app_configdir/config.yml" <<CFG
# Zurg configuration
# Documentation: https://github.com/debridmediamanager/zurg-testing

zurg: v1
token: ${RD_TOKEN}

host: "127.0.0.1"
port: ${app_port}

# How often to check for changes (seconds)
# Note: This should match --dir-cache-time in rclone mount service
check_for_changes_every_secs: 10

# Repair settings
repair_every_mins: 60
enable_repair: true

# Automatically delete RAR torrents after extraction
auto_delete_rar_torrents: false

# Retain folder structure in library
retain_folder_name_extension: false
retain_rd_torrent_name: false

# Network settings
concurrent_workers: 32
download_timeout_secs: 10

# On library update hook (optional)
# on_library_update: |
#   echo "Library updated"

# Directory definitions
directories:
  torrents:
    group_order: 10
    group: media
    filters:
      - regex: /.*/
CFG

	# Create rclone config for user
	local rclone_configdir="/home/$user/.config/rclone"
	if [ ! -d "$rclone_configdir" ]; then
		mkdir -p "$rclone_configdir"
	fi

	cat >"$rclone_configdir/rclone.conf" <<RCLONE
[zurg]
type = webdav
url = http://127.0.0.1:${app_port}/dav
vendor = other
pacer_min_sleep = 0
RCLONE

	chown -R "$user":"$user" "$rclone_configdir"
	chown -R "$user":"$user" "$app_configdir"

	# Create mount point
	if [ ! -d "$app_mount_point" ]; then
		mkdir -p "$app_mount_point"
	fi
	chown "$user":"$user" "$app_mount_point"

	echo_progress_done "Configuration created"
}

_systemd_zurg() {
	echo_progress_start "Installing Systemd services"

	# Main zurg service
	cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} - Real-Debrid WebDAV server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Group=${app_group}
WorkingDirectory=$app_configdir
ExecStart=$app_dir/$app_binary --config $app_configdir/config.yml
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

	# Rclone mount service
	cat >"/etc/systemd/system/$app_mount_servicefile" <<EOF
[Unit]
Description=Rclone mount for ${app_name^}
After=${app_servicefile}
Requires=${app_servicefile}

[Service]
Type=notify
User=${user}
Group=${app_group}
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/rclone mount zurg: $app_mount_point \\
    --config /home/${user}/.config/rclone/rclone.conf \\
    --read-only \\
    --no-modtime \\
    --no-checksum \\
    --poll-interval 0 \\
    --dir-cache-time 10s \\
    --attr-timeout 15s \\
    --vfs-read-wait 75ms \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 256G \\
    --vfs-cache-max-age 72h \\
    --vfs-cache-poll-interval 10m \\
    --buffer-size 32M \\
    --vfs-read-chunk-size 2M \\
    --vfs-read-chunk-size-limit 64M \\
    --allow-other \\
    --uid $(id -u "$user") \\
    --gid $(id -g "$user") \\
    -v
ExecStop=/bin/fusermount -uz $app_mount_point
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

	# Ensure allow_other is enabled in fuse.conf
	if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
		echo "user_allow_other" >>/etc/fuse.conf
	fi

	systemctl -q daemon-reload
	systemctl enable --now -q "$app_servicefile"
	sleep 2
	systemctl enable --now -q "$app_mount_servicefile"
	sleep 1

	echo_progress_done "${app_name^} services installed and enabled"
	echo_info "${app_name^} WebDAV running on http://127.0.0.1:$app_port"
	echo_info "Real-Debrid content mounted at $app_mount_point"
}

_install_zurg
_systemd_zurg

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Zurg" \
		"" \
		"http://127.0.0.1:$app_port" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
echo_info "Your Real-Debrid library is available at: $app_mount_point"
