#!/bin/bash
# seerr installer
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

app_name="seerr"

# REQUIRED: public FQDN for Seerr, e.g. seerr.example.com
: "${SEERR_DOMAIN:?SEERR_DOMAIN must be set to the FQDN for Seerr (e.g. seerr.example.com)}"
app_domain="$SEERR_DOMAIN"

# LE hostname used with box install letsencrypt
# - simplest: same as Seerr domain (seerr.example.com)
# - for wildcard: could be example.com if you issued *.example.com manually
le_hostname="${SEERR_LE_HOSTNAME:-$app_domain}"

# Resolve owner (same pattern as decypharr/notifiarr)
if [ -z "$SEERR_OWNER" ]; then
	if ! SEERR_OWNER="$(swizdb get "$app_name/owner")"; then
		SEERR_OWNER="$(_get_master_username)"
		echo_info "Setting ${app_name^} owner = $SEERR_OWNER"
		swizdb set "$app_name/owner" "$SEERR_OWNER"
	fi
else
	echo_info "Setting ${app_name^} owner = $SEERR_OWNER"
	swizdb set "$app_name/owner" "$SEERR_OWNER"
fi

fnm_install_url="https://fnm.vercel.app/install"
user="$SEERR_OWNER"
swiz_configdir="/home/$user/.config"
app_configdir="$swiz_configdir/${app_name^}"
app_group="$user"
app_port=$(port 10000 12000)
app_reqs=("curl" "jq" "wget")
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_lockname="${app_name//-/}"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/overseerr.png"
app_panel_urloverride="https://${app_domain}"

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

	su - "$user" -c 'bash -lc "fnm install --lts && fnm use --lts && npm install -g pnpm@9"' >>"$log" 2>&1 || {
		echo_error "Failed to install Node LTS and pnpm via fnm"
		exit 1
	}

	# Resolve absolute Node path for LTS and bake into systemd
	node_path="$(su - "$user" -c 'bash -lc "fnm which --lts"' 2>>"$log")"
	if [ -z "$node_path" ]; then
		echo_error "Could not resolve Node LTS path via fnm"
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
	su - "$user" -c "cd '$app_dir' && pnpm install" >>"$log" 2>&1 || {
		echo_error "Failed to install Seerr dependencies"
		exit 1
	}

	# Build for root path (subdomain), Seerr base URL = "/"
	su - "$user" -c "cd '$app_dir' && seerr_BASEURL='/' pnpm build" >>"$log" 2>&1 || {
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
ProtectHome=read-only
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

			# We are already root, no need for sudo
			LE_hostname="$le_hostname" \
			LE_defaultconf=no \
			box install letsencrypt >>"$log" 2>&1 || {
				echo_error "Failed to obtain Let's Encrypt certificate for $le_hostname"
				echo_error "You may need to run: LE_hostname=$le_hostname box install letsencrypt manually"
				echo_progress_done "Nginx configuration skipped due to LE failure"
				return 1
			}

			echo_info "Let's Encrypt certificate issued for $le_hostname"
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