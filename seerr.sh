#!/bin/bash
# seerr installer
# STiXzoOR 2025
# Usage: bash seerr.sh [--remove [--force]]

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

app_name="seerr"

# Get owner from swizdb (needed for both install and remove)
if ! SEERR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
	SEERR_OWNER="$(_get_master_username)"
fi
user="$SEERR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"

# Only require SEERR_DOMAIN for install (not remove)
if [ "$1" != "--remove" ]; then
	: "${SEERR_DOMAIN:?SEERR_DOMAIN must be set to the FQDN for Seerr (e.g. seerr.example.com)}"
	app_domain="$SEERR_DOMAIN"

	# LE hostname used with box install letsencrypt
	le_hostname="${SEERR_LE_HOSTNAME:-$app_domain}"

	# Set to "yes" to run Let's Encrypt interactively
	le_interactive="${SEERR_LE_INTERACTIVE:-no}"
fi

fnm_install_url="https://fnm.vercel.app/install"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl" "jq" "wget")
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/overseerr.png"
organizr_config="/opt/swizzin/organizr-auth.conf"

# Get Organizr domain for frame-ancestors (if configured)
_get_organizr_domain() {
	if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
		grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
	fi
}

if [ ! -d "$swiz_configdir" ]; then
	mkdir -p "$swiz_configdir"
fi
chown "$user":"$user" "$swiz_configdir"

_install_seerr() {
	# Config + logs under user's ~/.config/Seerr
	if [ ! -d "$app_configdir" ]; then
		mkdir -p "$app_configdir"
	fi
	if [ ! -d "$app_configdir/logs" ]; then
		mkdir -p "$app_configdir/logs"
	fi
	chown -R "$user":"$user" "$app_configdir"

	# OS-level deps
	apt_install "${app_reqs[@]}"

	# Install fnm, Node LTS and pnpm for app user
	echo_progress_start "Installing fnm, Node LTS and pnpm for $user"

	if ! su - "$user" -c 'command -v fnm >/dev/null 2>&1'; then
		su - "$user" -c "curl -fsSL \"$fnm_install_url\" | bash" >>"$log" 2>&1 || {
			echo_error "Failed to install fnm"
			exit 1
		}
	fi

	# Source fnm environment and install Node LTS + pnpm
	fnm_env='export FNM_PATH="$HOME/.local/share/fnm"; export PATH="$FNM_PATH:$PATH"; eval "$(fnm env)"'
	su - "$user" -c "$fnm_env; fnm install lts-latest && fnm use lts-latest && fnm default lts-latest && npm install -g pnpm@9" >>"$log" 2>&1 || {
		echo_error "Failed to install Node LTS and pnpm via fnm"
		exit 1
	}

	# Resolve absolute Node path and bake into systemd
	node_path="$(su - "$user" -c "$fnm_env; which node" 2>>"$log")"
	if [ -z "$node_path" ]; then
		echo_error "Could not resolve Node path"
		exit 1
	fi
	echo_info "Using Node binary at: $node_path"

	echo_progress_done "fnm, Node LTS and pnpm installed"

	echo_progress_start "Downloading and extracting Seerr source code"

	dlurl="$(curl -sS https://api.github.com/repos/seerr-team/seerr/releases/latest | jq -r .tarball_url)" || {
		echo_error "Failed to query GitHub for latest Seerr release"
		exit 1
	}

	if ! curl -sL "$dlurl" -o "/tmp/$app_name.tar.gz" >>"$log" 2>&1; then
		echo_error "Download failed"
		exit 1
	fi

	mkdir -p "$app_dir"
	tar --strip-components=1 -C "$app_dir" -xzvf "/tmp/$app_name.tar.gz" >>"$log" 2>&1 || {
		echo_error "Failed to extract Seerr archive"
		exit 1
	}
	rm -f "/tmp/$app_name.tar.gz"
	chown -R "$user":"$user" "$app_dir"
	echo_progress_done "Seerr source code extracted to $app_dir"

	echo_progress_start "Configuring and building Seerr"

	# Bypass Node engine strictness if present (as in original script)
	if [ -f "$app_dir/.npmrc" ]; then
		sed -i 's|engine-strict=true|engine-strict=false|g' "$app_dir/.npmrc" || true
	fi

	# Optional CPU limit tweak in next.config.js (non-fatal if pattern not found)
	if [ -f "$app_dir/next.config.js" ]; then
		sed -i "s|256000,|256000,\n    cpus: 6,|g" "$app_dir/next.config.js" || true
	fi

	# Install deps + build using pnpm as the app user
	su - "$user" -c "$fnm_env; cd '$app_dir' && pnpm install" >>"$log" 2>&1 || {
		echo_error "Failed to install Seerr dependencies"
		exit 1
	}

	# Build for root path (subdomain), Seerr base URL = "/"
	su - "$user" -c "$fnm_env; cd '$app_dir' && seerr_BASEURL='/' pnpm build" >>"$log" 2>&1 || {
		echo_error "Failed to build Seerr"
		exit 1
	}

	echo_progress_done "Seerr built successfully"

	# Write env file
	cat >"$app_configdir/env.conf" <<EOF
# Seerr environment
PORT=$app_port
seerr_BASEURL="/"
EOF

	chown -R "$user":"$user" "$app_configdir"

	# Export node_path for the systemd function (global)
	SEERR_NODE_PATH="$node_path"
}

_systemd_seerr() {
	echo_progress_start "Installing Systemd service"

	# Use resolved Node path from fnm
	node_bin="${SEERR_NODE_PATH:-/usr/bin/node}"

	cat >"/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=${app_name^} Service
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
User=${user}
Group=${app_group}
UMask=002
EnvironmentFile=$app_configdir/env.conf
Environment=NODE_ENV=production
Environment=CONFIG_DIRECTORY=$app_configdir
WorkingDirectory=$app_dir
ExecStart=$node_bin dist/index.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
SyslogIdentifier=$app_name

# Hardening (adapted from upstream)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectClock=true
ProtectControlGroups=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
RemoveIPC=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native
SystemCallErrorNumber=EPERM
SystemCallFilter=@system-service
SystemCallFilter=~@privileged

[Install]
WantedBy=multi-user.target
EOF

	systemctl -q daemon-reload
	systemctl enable --now -q "$app_servicefile"
	sleep 1
	echo_progress_done "${app_name^} service installed and enabled"
	echo_info "${app_name^} is running on http://127.0.0.1:$app_port/"
}

_nginx_seerr() {
	if [[ -f /install/.nginx.lock ]]; then
		echo_progress_start "Configuring nginx vhost for ${app_name^} on $app_domain"

		local cert_dir="/etc/nginx/ssl/$le_hostname"
		local vhost_file="/etc/nginx/sites-available/$app_name"
		local enabled_link="/etc/nginx/sites-enabled/$app_name"

		# If no cert yet, invoke Swizzin's LE helper
		if [ ! -d "$cert_dir" ]; then
			echo_info "No Let's Encrypt cert found at $cert_dir, requesting one via box install letsencrypt"

			if [ "$le_interactive" = "yes" ]; then
				# Interactive mode - let user answer prompts (e.g., for CloudFlare DNS)
				echo_info "Running Let's Encrypt in interactive mode..."
				LE_HOSTNAME="$le_hostname" box install letsencrypt </dev/tty
				le_result=$?
			else
				# Non-interactive mode - use uppercase variable names as per Swizzin docs
				LE_HOSTNAME="$le_hostname" LE_DEFAULTCONF=no LE_BOOL_CF=no \
					box install letsencrypt >>"$log" 2>&1
				le_result=$?
			fi

			if [ $le_result -ne 0 ]; then
				echo_error "Failed to obtain Let's Encrypt certificate for $le_hostname"
				echo_error "Check $log for details or run manually: LE_HOSTNAME=$le_hostname box install letsencrypt"
				echo_progress_done "Nginx configuration skipped due to LE failure"
				return 1
			fi

			echo_info "Let's Encrypt certificate issued for $le_hostname"
		fi

		# Get Organizr domain for frame-ancestors
		local organizr_domain
		organizr_domain=$(_get_organizr_domain)
		local csp_header=""
		if [ -n "$organizr_domain" ]; then
			csp_header="add_header Content-Security-Policy \"frame-ancestors 'self' https://$organizr_domain\";"
		fi

		# Create dedicated vhost for Seerr
		cat >"$vhost_file" <<-NGX
			server {
			    listen 80;
			    listen [::]:80;
			    server_name $app_domain;

			    # Keep ACME support compatible with default
			    location /.well-known {
			        alias /srv/.well-known;
			        allow all;
			        default_type "text/plain";
			        autoindex on;
			    }

			    location / {
			        return 301 https://\$host\$request_uri;
			    }
			}

			server {
			    listen 443 ssl http2;
			    listen [::]:443 ssl http2;
			    server_name $app_domain;

			    ssl_certificate           /etc/nginx/ssl/$le_hostname/fullchain.pem;
			    ssl_certificate_key       /etc/nginx/ssl/$le_hostname/key.pem;
			    include snippets/ssl-params.conf;

			    ${csp_header}

			    # Seerr reverse proxy
			    location / {
			        include snippets/proxy.conf;
			        proxy_pass http://127.0.0.1:$app_port;
			    }
			}
		NGX

		# Enable vhost if not already enabled
		if [ ! -L "$enabled_link" ]; then
			ln -s "$vhost_file" "$enabled_link"
		fi

		systemctl reload nginx
		echo_progress_done "Nginx configured — Seerr public at https://$app_domain (cert: $le_hostname)"
	else
		echo_info "${app_name^} will run on port $app_port (no nginx configured)"
	fi
}

_remove_seerr() {
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

	# Remove nginx vhost
	local vhost_file="/etc/nginx/sites-available/$app_name"
	local enabled_link="/etc/nginx/sites-enabled/$app_name"
	if [ -f "$vhost_file" ] || [ -L "$enabled_link" ]; then
		echo_progress_start "Removing nginx configuration"
		rm -f "$enabled_link"
		rm -f "$vhost_file"
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
	else
		echo_info "Configuration files kept at: $app_configdir"
	fi

	# Remove lock file
	rm -f "/install/.$app_lockname.lock"

	echo_success "${app_name^} has been removed"
	echo_info "Note: Let's Encrypt certificate was not removed. Remove manually if needed."
	exit 0
}

# Handle --remove flag
if [ "$1" = "--remove" ]; then
	_remove_seerr "$2"
fi

# Set owner for install
if [ -n "$SEERR_OWNER" ]; then
	echo_info "Setting ${app_name^} owner = $SEERR_OWNER"
	swizdb set "$app_name/owner" "$SEERR_OWNER"
fi

# Set panel URL override (needs app_domain which is only set for install)
app_panel_urloverride="https://${app_domain}"

_install_seerr
_systemd_seerr
_nginx_seerr

_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
	panel_register_app \
		"$app_name" \
		"Seerr" \
		"" \
		"$app_panel_urloverride" \
		"$app_name" \
		"$app_icon_name" \
		"$app_icon_url" \
		"true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
