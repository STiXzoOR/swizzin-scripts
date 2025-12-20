#!/bin/bash
# jellyfin-subdomain - Convert Jellyfin to subdomain mode
# STiXzoOR 2025
# Usage: bash jellyfin-subdomain.sh [--revert|--remove [--force]]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

app_name="jellyfin"
app_port="8922"
app_protocol="https"
app_lockname="jellyfin"

backup_dir="/opt/swizzin/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin/organizr-auth.conf"

# Get domain from env
_get_domain() {
	echo "${JELLYFIN_DOMAIN:-}"
}

# Get Organizr domain for frame-ancestors (if configured)
_get_organizr_domain() {
	if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
		grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
	fi
}

# Pre-flight checks
_preflight() {
	if [ ! -f /install/.nginx.lock ]; then
		echo_error "nginx is not installed. Please install nginx first."
		exit 1
	fi

	if [ "$1" != "revert" ] && [ "$1" != "remove" ]; then
		local domain
		domain=$(_get_domain)
		if [ -z "$domain" ]; then
			echo_error "JELLYFIN_DOMAIN must be set (e.g., export JELLYFIN_DOMAIN=\"jellyfin.example.com\")"
			exit 1
		fi
	fi
}

# Check current state
_get_install_state() {
	if [ ! -f "/install/.${app_lockname}.lock" ]; then
		echo "not_installed"
	elif [ -f "$subdomain_vhost" ]; then
		echo "subdomain"
	elif [ -f "$subfolder_conf" ]; then
		echo "subfolder"
	else
		echo "unknown"
	fi
}

# Install app via box if not installed
_install_app() {
	if [ ! -f "/install/.${app_lockname}.lock" ]; then
		echo_info "Installing ${app_name^} via box install ${app_name}..."
		box install "$app_name" || {
			echo_error "Failed to install ${app_name^}"
			exit 1
		}
	else
		echo_info "${app_name^} already installed"
	fi
}

# Request Let's Encrypt certificate
_request_certificate() {
	local domain="$1"
	local le_hostname="${JELLYFIN_LE_HOSTNAME:-$domain}"
	local cert_dir="/etc/nginx/ssl/$le_hostname"
	local le_interactive="${JELLYFIN_LE_INTERACTIVE:-no}"

	if [ -d "$cert_dir" ]; then
		echo_info "Let's Encrypt certificate already exists for $le_hostname"
		return 0
	fi

	echo_info "Requesting Let's Encrypt certificate for $le_hostname"

	if [ "$le_interactive" = "yes" ]; then
		echo_info "Running Let's Encrypt in interactive mode..."
		LE_HOSTNAME="$le_hostname" box install letsencrypt </dev/tty
		local result=$?
	else
		LE_HOSTNAME="$le_hostname" LE_DEFAULTCONF=no LE_BOOL_CF=no \
			box install letsencrypt >>"$log" 2>&1
		local result=$?
	fi

	if [ $result -ne 0 ]; then
		echo_error "Failed to obtain Let's Encrypt certificate for $le_hostname"
		echo_error "Check $log for details or run manually: LE_HOSTNAME=$le_hostname box install letsencrypt"
		exit 1
	fi

	echo_info "Let's Encrypt certificate issued for $le_hostname"
}

# Create backup directory
_ensure_backup_dir() {
	if [ ! -d "$backup_dir" ]; then
		mkdir -p "$backup_dir"
	fi
}

# Backup a file
_backup_file() {
	local src="$1"
	local name
	name=$(basename "$src")
	_ensure_backup_dir
	if [ -f "$src" ]; then
		cp "$src" "$backup_dir/${name}.bak"
	fi
}

# Create subdomain vhost
_create_subdomain_vhost() {
	local domain="$1"
	local le_hostname="${2:-$domain}"
	local cert_dir="/etc/nginx/ssl/$le_hostname"
	local organizr_domain
	organizr_domain=$(_get_organizr_domain)

	echo_progress_start "Creating subdomain nginx vhost"

	# Backup and remove subfolder config
	if [ -f "$subfolder_conf" ]; then
		_backup_file "$subfolder_conf"
		rm -f "$subfolder_conf"
	fi

	# Build CSP header
	local csp_header=""
	if [ -n "$organizr_domain" ]; then
		csp_header="add_header Content-Security-Policy \"frame-ancestors 'self' https://$organizr_domain\";"
	fi

	cat >"$subdomain_vhost" <<VHOST
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

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
    server_name $domain;

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    include snippets/ssl-params.conf;

    client_max_body_size 0;

    ${csp_header}

    location / {
        proxy_pass ${app_protocol}://127.0.0.1:${app_port};
        proxy_pass_request_headers on;
        proxy_set_header Host \$proxy_host;
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Protocol \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_redirect off;
        proxy_buffering off;

        if (\$http_user_agent ~ Web0S) {
            add_header Access-Control-Allow-Origin "luna://com.webos.service.config" always;
        }

        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
    }

    location ~ (/jellyfin)?/socket {
        include /etc/nginx/snippets/proxy.conf;
        if (\$http_user_agent ~ Web0S) {
            add_header Access-Control-Allow-Origin "luna://com.webos.service.config" always;
        }
        proxy_pass ${app_protocol}://127.0.0.1:${app_port};
    }

    # Restrict access to /metrics
    # https://jellyfin.org/docs/general/networking/monitoring/#prometheus-metrics
    location /metrics {
        allow 192.168.0.0/16;
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 127.0.0.0/8;

        deny all;

        include /etc/nginx/snippets/proxy.conf;
        proxy_pass ${app_protocol}://127.0.0.1:${app_port};
    }
}
VHOST

	# Enable site
	if [ ! -L "$subdomain_enabled" ]; then
		ln -s "$subdomain_vhost" "$subdomain_enabled"
	fi

	echo_progress_done "Subdomain vhost created"
}

# Add panel meta urloverride
_add_panel_meta() {
	local domain="$1"

	echo_progress_start "Adding panel meta urloverride"

	# Ensure profiles.py exists
	mkdir -p "$(dirname "$profiles_py")"
	touch "$profiles_py"

	# Remove existing override if present
	sed -i "/^class ${app_name}_meta(${app_name}_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true

	# Add new override
	cat >>"$profiles_py" <<PYTHON

class ${app_name}_meta(${app_name}_meta):
    urloverride = "https://${domain}"
PYTHON

	echo_progress_done "Panel meta updated"
}

# Remove panel meta urloverride
_remove_panel_meta() {
	if [ -f "$profiles_py" ]; then
		echo_progress_start "Removing panel meta urloverride"
		sed -i "/^class ${app_name}_meta(${app_name}_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true
		# Clean up empty lines at end of file
		sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$profiles_py" 2>/dev/null || true
		echo_progress_done "Panel meta removed"
	fi
}

# Recreate default subfolder config
_create_subfolder_config() {
	cat >"$subfolder_conf" <<-'NGX'
		location /jellyfin {
		    proxy_pass https://127.0.0.1:8922;
		    proxy_pass_request_headers on;
		    proxy_set_header Host $proxy_host;
		    proxy_http_version 1.1;
		    proxy_set_header X-Real-IP $remote_addr;
		    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		    proxy_set_header X-Forwarded-Proto $scheme;
		    proxy_set_header X-Forwarded-Protocol $scheme;
		    proxy_set_header X-Forwarded-Host $http_host;
		    proxy_set_header Upgrade $http_upgrade;
		    proxy_set_header Connection $http_connection;
		    proxy_set_header X-Forwarded-Ssl on;
		    proxy_redirect off;
		    proxy_buffering off;
		    auth_basic off;
		}
	NGX
}

# Main install flow
_install() {
	local domain
	domain=$(_get_domain)
	local le_hostname="${JELLYFIN_LE_HOSTNAME:-$domain}"
	local state
	state=$(_get_install_state)

	echo_info "${app_name^} Subdomain Setup"
	echo_info "Domain: $domain"
	[ "$le_hostname" != "$domain" ] && echo_info "LE Hostname: $le_hostname"
	echo_info "Current state: $state"

	case "$state" in
	"not_installed")
		_install_app
		;& # fallthrough
	"subfolder")
		_request_certificate "$domain"
		_create_subdomain_vhost "$domain" "$le_hostname"
		_add_panel_meta "$domain"
		systemctl reload nginx
		echo_success "${app_name^} converted to subdomain mode"
		echo_info "Access at: https://$domain"
		;;
	"subdomain")
		echo_info "Already in subdomain mode"
		;;
	*)
		echo_error "Unknown installation state"
		exit 1
		;;
	esac
}

# Revert to subfolder mode
_revert() {
	echo_info "Reverting ${app_name^} to subfolder mode..."

	# Remove subdomain vhost
	if [ -L "$subdomain_enabled" ]; then
		rm -f "$subdomain_enabled"
	fi
	if [ -f "$subdomain_vhost" ]; then
		rm -f "$subdomain_vhost"
	fi

	# Restore subfolder config
	if [ -f "$backup_dir/${app_name}.conf.bak" ]; then
		cp "$backup_dir/${app_name}.conf.bak" "$subfolder_conf"
		echo_info "Restored subfolder nginx config"
	else
		echo_info "Recreating subfolder config..."
		_create_subfolder_config
	fi

	# Remove panel meta override
	_remove_panel_meta

	systemctl reload nginx
	echo_success "${app_name^} reverted to subfolder mode"
	echo_info "Access at: https://your-server/${app_name}/"
}

# Complete removal
_remove() {
	local force="$1"
	if [ "$force" != "--force" ] && [ ! -f "/install/.${app_lockname}.lock" ]; then
		echo_error "${app_name^} is not installed (use --force to override)"
		exit 1
	fi

	echo_info "Removing ${app_name^}..."

	# Revert first if on subdomain
	if [ -f "$subdomain_vhost" ]; then
		rm -f "$subdomain_enabled"
		rm -f "$subdomain_vhost"
		_remove_panel_meta
	fi

	# Remove subfolder config if exists
	rm -f "$subfolder_conf"

	# Remove backup dir
	rm -rf "$backup_dir"

	# Reload nginx
	systemctl reload nginx 2>/dev/null || true

	# Remove app via box
	echo_info "Removing ${app_name^} via box remove ${app_name}..."
	box remove "$app_name"

	echo_success "${app_name^} has been removed"
	echo_info "Note: Let's Encrypt certificate was not removed"
	exit 0
}

# Main
_preflight "$1"

case "$1" in
"--revert")
	_revert
	;;
"--remove")
	_remove "$2"
	;;
"")
	_install
	;;
*)
	echo "Usage: $0 [--revert|--remove [--force]]"
	echo ""
	echo "  (no args)    Convert ${app_name^} to subdomain mode"
	echo "  --revert     Revert to subfolder mode"
	echo "  --remove     Completely remove ${app_name^}"
	exit 1
	;;
esac
