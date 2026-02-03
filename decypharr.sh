#!/bin/bash
# decypharr installer
# STiXzoOR 2025
# Usage: bash decypharr.sh [--update [--full] [--verbose]|--remove [--force]] [--register-panel] [--fix-mounts]

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

# ==============================================================================
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
	if [[ "$verbose" == "true" ]]; then
		echo_info "  $*"
	fi
}

app_name="decypharr"

# Get owner from swizdb (needed for both install and remove)
if ! DECYPHARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
	DECYPHARR_OWNER="$(_get_master_username)"
fi
user="$DECYPHARR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl" "fuse3")
app_servicefile="$app_name.service"
app_dir="/usr/bin"
app_binary="$app_name"
app_lockname="${app_name//-/}"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/decypharr.png"

if [ ! -d "$swiz_configdir" ]; then
	mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

app_default_mount="/mnt"

# Prompt for rclone mount path or use default/env
_get_mount_path() {
	# Check environment variable first
	if [ -n "$DECYPHARR_MOUNT_PATH" ]; then
		echo_info "Using mount path from DECYPHARR_MOUNT_PATH: $DECYPHARR_MOUNT_PATH"
		app_mount_path="$DECYPHARR_MOUNT_PATH"
		return
	fi

	# Check existing config in swizdb
	local existing_mount
	existing_mount=$(swizdb get "decypharr/mount_path" 2>/dev/null) || true

	local default_mount="${existing_mount:-$app_default_mount}"

	echo_query "Enter rclone mount path" "[$default_mount]"
	read -r input_mount </dev/tty

	if [ -z "$input_mount" ]; then
		app_mount_path="$default_mount"
	else
		# Validate absolute path
		if [[ ! "$input_mount" = /* ]]; then
			echo_error "Mount path must be an absolute path (start with /)"
			exit 1
		fi
		app_mount_path="$input_mount"
	fi

	echo_info "Using mount path: $app_mount_path"
}

# Install latest rclone from official script
_install_rclone() {
	if command -v rclone &>/dev/null; then
		local current_version
		current_version=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
		echo_info "rclone $current_version already installed"
		return 0
	fi

	echo_progress_start "Installing rclone"
	# The official install script may return non-zero if already latest
	curl -fsSL https://rclone.org/install.sh | bash >>"$log" 2>&1 || true

	# Verify rclone is now available
	if command -v rclone &>/dev/null; then
		echo_progress_done "rclone installed: $(rclone version 2>/dev/null | head -1 | awk '{print $2}')"
	else
		echo_error "Failed to install rclone"
		exit 1
	fi
}

# Get zurg configuration if installed
_get_zurg_config() {
	zurg_mount=""
	zurg_api_key=""

	if [ -f /install/.zurg.lock ]; then
		zurg_mount=$(swizdb get "zurg/mount_point" 2>/dev/null) || true
		zurg_api_key=$(swizdb get "zurg/api_key" 2>/dev/null) || true

		if [ -n "$zurg_mount" ]; then
			echo_info "Found zurg installation at: $zurg_mount"
		fi
	fi
}

# Prepare mount point directories with proper ownership
# When rclone is enabled, Decypharr creates FUSE mounts for each debrid service
# The mount points must be writable by the user running Decypharr
_prepare_mount_points() {
	local mount_base="$1"
	local owner="$2"

	# Known debrid services that Decypharr supports
	local debrid_services=("realdebrid" "torbox" "alldebrid" "debridlink" "premiumize" "offcloud")

	echo_progress_start "Preparing mount point directories"

	# Create base mount path if it doesn't exist
	if [ ! -d "$mount_base" ]; then
		mkdir -p "$mount_base"
	fi

	# Create mount points for each debrid service with proper ownership
	for service in "${debrid_services[@]}"; do
		local mount_point="${mount_base}/${service}"
		if [ ! -d "$mount_point" ]; then
			mkdir -p "$mount_point"
			_verbose "Created mount point: $mount_point"
		fi
		chown "$owner":"$owner" "$mount_point"
	done

	echo_progress_done "Mount points prepared with correct ownership"
}

_install_decypharr() {
	if [ ! -d "$app_configdir" ]; then
		mkdir -p "$app_configdir"
	fi
	chown -R "$user":"$user" "$app_configdir"

	apt_install "${app_reqs[@]}"
	_install_rclone

	echo_progress_start "Downloading release archive"

	case "$(_os_arch)" in
	"amd64") arch='x86_64' ;;
	"arm64") arch="arm64" ;;
	"armhf") arch="armv6" ;;
	*)
		echo_error "Arch not supported"
		exit 1
		;;
	esac

	# Using my fork of decypharr until original author fixes base URL issue
	latest=$(curl -sL https://api.github.com/repos/STiXzoOR/decypharr/releases/latest | grep "Linux_$arch" | grep browser_download_url | grep ".tar.gz" | cut -d \" -f4) || {
		echo_error "Failed to query GitHub for latest version"
		exit 1
	}

	if ! curl "$latest" -L -o "/tmp/$app_name.tar.gz" >>"$log" 2>&1; then
		echo_error "Download failed, exiting"
		exit 1
	fi
	echo_progress_done "Archive downloaded"

	echo_progress_start "Extracting archive"
	tar xfv "/tmp/$app_name.tar.gz" --directory /usr/bin/ >>"$log" 2>&1 || {
		echo_error "Failed to extract"
		exit 1
	}
	rm -rf "/tmp/$app_name.tar.gz"
	echo_progress_done "Archive extracted"

	chmod +x "$app_dir/$app_binary"

	echo_progress_start "Creating default config"

	# Build realdebrid folder path from zurg mount if available
	local rd_folder=""
	local rd_api_key=""
	local zurg_url=""
	local rclone_enabled="true"
	local use_webdav="true"
	if [ -n "$zurg_mount" ]; then
		rd_folder="${zurg_mount}/__all__/"
		rd_api_key="${zurg_api_key:-}"
		zurg_url="http://127.0.0.1:9999"
		rclone_enabled="false"  # zurg handles rclone mount
		use_webdav="false"      # use zurg's mount directly, not internal webdav
		echo_info "Zurg detected - using zurg's mount directly (webdav and internal rclone disabled)"
	fi

	cat >"$app_configdir/config.json" <<CFG
{
  "url_base": "/${app_baseurl}/",
  "port": "${app_port}",
  "log_level": "info",
  "debrids": [
    {
      "name": "realdebrid",
      "api_key": "${rd_api_key}",
      "download_api_keys": ["${rd_api_key}"],
      "folder": "${rd_folder}",
      "rate_limit": "250/minute",
      "minimum_free_slot": 1,
      "use_webdav": ${use_webdav},
      "torrents_refresh_interval": "15s",
      "download_links_refresh_interval": "40m",
      "workers": 600,
      "auto_expire_links_after": "3d",
      "folder_naming": "filename"
    }
  ],
  "qbittorrent": {
    "download_folder": "${app_mount_path}/symlinks/downloads",
    "refresh_interval": 5
  },
  "repair": {
    "interval": "12h",
    "zurg_url": "${zurg_url}",
    "workers": 1,
    "strategy": "per_torrent"
  },
  "webdav": {},
  "rclone": {
    "enabled": ${rclone_enabled},
    "mount_path": "${app_mount_path}",
    "vfs_cache_mode": "full",
    "vfs_cache_max_size": "256G",
    "vfs_cache_max_age": "72h",
    "vfs_cache_poll_interval": "1m",
    "vfs_read_ahead": "1G",
    "vfs_read_chunk_size": "off",
    "vfs_read_chunk_size_limit": "512M",
    "vfs_read_wait": "5ms",
    "max_read_ahead": "1M",
    "vfs_fast_fingerprint": true,
    "buffer_size": "256M",
    "async_read": false,
    "transfers": 8,
    "dir_cache_time": "1h",
    "attr_timeout": "15s",
    "no_modtime": true,
    "no_checksum": true,
    "log_level": "INFO"
  },
  "allowed_file_types": [
    "3gp",
    "ac3",
    "aiff",
    "alac",
    "amr",
    "ape",
    "asf",
    "asx",
    "avc",
    "avi",
    "bin",
    "bivx",
    "dat",
    "divx",
    "dts",
    "dv",
    "dvr-ms",
    "flac",
    "fli",
    "flv",
    "ifo",
    "img",
    "iso",
    "m2ts",
    "m2v",
    "m3u",
    "m4a",
    "m4p",
    "m4v",
    "mid",
    "midi",
    "mk3d",
    "mka",
    "mkv",
    "mov",
    "mp2",
    "mp3",
    "mp4",
    "mpa",
    "mpeg",
    "mpg",
    "nrg",
    "nsv",
    "nuv",
    "ogg",
    "ogm",
    "ogv",
    "pva",
    "qt",
    "ra",
    "rm",
    "rmvb",
    "strm",
    "svq3",
    "ts",
    "ty",
    "viv",
    "vob",
    "voc",
    "vp3",
    "wav",
    "webm",
    "wma",
    "wmv",
    "wpl",
    "wtv",
    "wv",
    "xvid"
  ]
}
CFG

	chown -R "$user":"$user" "$app_configdir"
	echo_progress_done "Default config created"
}

# ==============================================================================
# Backup (for rollback on failed update)
# ==============================================================================
_backup_decypharr() {
	local backup_dir="/tmp/swizzin-update-backups/${app_name}"

	_verbose "Creating backup directory: ${backup_dir}"
	mkdir -p "$backup_dir"

	if [[ -f "${app_dir}/${app_binary}" ]]; then
		_verbose "Backing up binary: ${app_dir}/${app_binary}"
		cp "${app_dir}/${app_binary}" "${backup_dir}/${app_binary}"
		_verbose "Backup complete ($(du -h "${backup_dir}/${app_binary}" | cut -f1))"
	else
		echo_error "Binary not found: ${app_dir}/${app_binary}"
		return 1
	fi
}

# ==============================================================================
# Rollback (restore from backup on failed update)
# ==============================================================================
_rollback_decypharr() {
	local backup_dir="/tmp/swizzin-update-backups/${app_name}"

	echo_error "Update failed, rolling back..."

	if [[ -f "${backup_dir}/${app_binary}" ]]; then
		_verbose "Restoring binary from backup"
		cp "${backup_dir}/${app_binary}" "${app_dir}/${app_binary}"
		chmod +x "${app_dir}/${app_binary}"

		_verbose "Restarting service"
		systemctl restart "$app_servicefile" 2>/dev/null || true

		echo_info "Rollback complete. Previous version restored."
	else
		echo_error "No backup found at ${backup_dir}"
		echo_info "Manual intervention required"
	fi

	rm -rf "$backup_dir"
}

# ==============================================================================
# Update
# ==============================================================================
_update_decypharr() {
	local full_reinstall="$1"

	if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_name^} is not installed"
		exit 1
	fi

	# Full reinstall
	if [[ "$full_reinstall" == "true" ]]; then
		echo_info "Performing full reinstall of ${app_name^}..."
		echo_progress_start "Stopping service"
		systemctl stop "$app_servicefile" 2>/dev/null || true
		echo_progress_done "Service stopped"

		# Get mount path from swizdb for reinstall
		local reinstall_mount_path
		reinstall_mount_path=$(swizdb get "decypharr/mount_path" 2>/dev/null) || reinstall_mount_path="$app_default_mount"
		app_mount_path="$reinstall_mount_path"

		_get_zurg_config
		_install_decypharr

		# Prepare mount points when rclone is enabled (no zurg)
		if [ -z "$zurg_mount" ]; then
			_prepare_mount_points "$app_mount_path" "$user"
		fi

		echo_progress_start "Starting service"
		systemctl start "$app_servicefile"
		echo_progress_done "Service started"
		echo_success "${app_name^} reinstalled"
		exit 0
	fi

	# Binary-only update (default)
	echo_info "Updating ${app_name^}..."

	echo_progress_start "Backing up current binary"
	if ! _backup_decypharr; then
		echo_error "Backup failed, aborting update"
		exit 1
	fi
	echo_progress_done "Backup created"

	echo_progress_start "Stopping service"
	systemctl stop "$app_servicefile" 2>/dev/null || true
	echo_progress_done "Service stopped"

	echo_progress_start "Downloading latest release"

	case "$(_os_arch)" in
	"amd64") arch='x86_64' ;;
	"arm64") arch='arm64' ;;
	"armhf") arch='armv6' ;;
	*)
		echo_error "Architecture not supported"
		_rollback_decypharr
		exit 1
		;;
	esac

	local github_repo="STiXzoOR/decypharr"
	_verbose "Querying GitHub API: https://api.github.com/repos/${github_repo}/releases/latest"

	latest=$(curl -sL "https://api.github.com/repos/${github_repo}/releases/latest" |
		grep "Linux_$arch" |
		grep "browser_download_url" |
		grep ".tar.gz" |
		cut -d\" -f4) || {
		echo_error "Failed to query GitHub"
		_rollback_decypharr
		exit 1
	}

	if [[ -z "$latest" ]]; then
		echo_error "No matching release found"
		_rollback_decypharr
		exit 1
	fi

	_verbose "Downloading: ${latest}"
	if ! curl -fsSL "$latest" -o "/tmp/${app_name}.tar.gz" >>"$log" 2>&1; then
		echo_error "Download failed"
		_rollback_decypharr
		exit 1
	fi
	echo_progress_done "Downloaded"

	echo_progress_start "Installing update"
	if ! tar xfv "/tmp/${app_name}.tar.gz" --directory /usr/bin/ >>"$log" 2>&1; then
		echo_error "Extraction failed"
		rm -f "/tmp/${app_name}.tar.gz"
		_rollback_decypharr
		exit 1
	fi
	rm -f "/tmp/${app_name}.tar.gz"
	chmod +x "${app_dir}/${app_binary}"
	echo_progress_done "Installed"

	echo_progress_start "Restarting service"
	systemctl start "$app_servicefile"

	sleep 2
	if systemctl is-active --quiet "$app_servicefile"; then
		echo_progress_done "Service running"
		_verbose "Service status: active"
	else
		echo_progress_done "Service may have issues"
		_rollback_decypharr
		exit 1
	fi

	rm -rf "/tmp/swizzin-update-backups/${app_name}"
	echo_success "${app_name^} updated"
	exit 0
}

_remove_decypharr() {
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

	# Remove binary
	echo_progress_start "Removing ${app_name^} binary"
	rm -f "$app_dir/$app_binary"
	echo_progress_done "Binary removed"

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

	# Remove config directory if purging
	if [ "$purgeconfig" = "true" ]; then
		echo_progress_start "Purging configuration files"
		rm -rf "$app_configdir"
		echo_progress_done "Configuration purged"
		# Remove swizdb entry
		swizdb clear "$app_name/owner" 2>/dev/null || true
		swizdb clear "decypharr/mount_path" 2>/dev/null || true
	else
		echo_info "Configuration files kept at: $app_configdir"
	fi

	# Remove lock file
	rm -f "/install/.$app_lockname.lock"

	echo_success "${app_name^} has been removed"
	exit 0
}

_systemd_decypharr() {
	echo_progress_start "Installing Systemd service"
	cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} Daemon
After=syslog.target network.target

[Service]
# Change the user and group variables here.
User=${user}
Group=${app_group}

Type=simple

# Change the path to ${app_name^} here if it is in a different location for you.
ExecStart=$app_dir/$app_binary --config=$app_configdir
TimeoutStopSec=20
KillMode=process
Restart=on-failure

# These lines optionally isolate (sandbox) ${app_name^} from the rest of the system.
# Make sure to add any paths it might use to the list below (space-separated).
#ReadWritePaths=$app_dir /path/to/media/folder
#ProtectSystem=strict
#PrivateDevices=true
#ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

	systemctl -q daemon-reload
	systemctl enable --now -q "$app_servicefile"
	sleep 1
	echo_progress_done "${app_name^} service installed and enabled"
}

_nginx_decypharr() {
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

# Parse global flags
for arg in "$@"; do
	case "$arg" in
	--verbose) verbose=true ;;
	esac
done

# Handle --update flag
if [[ "$1" == "--update" ]]; then
	full_reinstall=false
	for arg in "$@"; do
		case "$arg" in
		--full) full_reinstall=true ;;
		esac
	done
	_update_decypharr "$full_reinstall"
fi

# Handle --remove flag
if [ "$1" = "--remove" ]; then
	_remove_decypharr "$2"
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
			"Decypharr" \
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

# Handle --fix-mounts flag (fix mount point permissions for existing installs)
if [ "$1" = "--fix-mounts" ]; then
	if [ ! -f "/install/.$app_lockname.lock" ]; then
		echo_error "${app_name^} is not installed"
		exit 1
	fi

	# Get mount path from swizdb
	fix_mount_path=$(swizdb get "decypharr/mount_path" 2>/dev/null) || fix_mount_path="$app_default_mount"

	echo_info "Fixing mount point permissions at: $fix_mount_path"
	_prepare_mount_points "$fix_mount_path" "$user"

	# Restart service to retry mounts
	echo_progress_start "Restarting ${app_name^} service"
	systemctl restart "$app_servicefile"
	sleep 2
	if systemctl is-active --quiet "$app_servicefile"; then
		echo_progress_done "Service restarted"
	else
		echo_warn "Service may have issues, check: journalctl -u $app_servicefile"
	fi

	echo_success "Mount point permissions fixed"
	exit 0
fi

# Check if already installed
if [ -f "/install/.$app_lockname.lock" ]; then
	echo_info "${app_name^} is already installed"
else
	# Set owner for install
	if [ -n "$DECYPHARR_OWNER" ]; then
		echo_info "Setting ${app_name^} owner = $DECYPHARR_OWNER"
		swizdb set "$app_name/owner" "$DECYPHARR_OWNER"
	fi

	# Get mount path (interactive or from env)
	_get_mount_path

	# Get zurg config if installed
	_get_zurg_config

	_install_decypharr

	# Prepare mount points when rclone is enabled (no zurg)
	# This ensures the user has write access for FUSE mounts
	if [ -z "$zurg_mount" ]; then
		_prepare_mount_points "$app_mount_path" "$user"
	fi

	_systemd_decypharr
	_nginx_decypharr

	# Store configuration in swizdb
	swizdb set "decypharr/mount_path" "$app_mount_path"
fi

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Decypharr" \
		"/$app_baseurl" \
		"" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"

# Hint about symlink import script if Sonarr/Radarr are installed
if compgen -G "/install/.sonarr*.lock" >/dev/null 2>&1 || compgen -G "/install/.radarr*.lock" >/dev/null 2>&1; then
	echo ""
	echo_info "Sonarr/Radarr detected. To prevent 'Permission denied' errors"
	echo_info "when importing through symlinks to the zurg mount, consider using"
	echo_info "the symlink import script:"
	echo_info "  bash arr-symlink-import-setup.sh --install"
fi
