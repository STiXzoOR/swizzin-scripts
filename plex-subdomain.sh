#!/bin/bash
# plex-subdomain - Convert Plex to subdomain mode
# STiXzoOR 2025
# Usage: bash plex-subdomain.sh [--revert|--remove [--force]]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

app_name="plex"
app_port="32400"
app_lockname="plex"

backup_dir="/opt/swizzin/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin/organizr-auth.conf"

# Get domain from env
_get_domain() {
	echo "${PLEX_DOMAIN:-}"
}

# Get Organizr domain for frame-ancestors (if configured)
_get_organizr_domain() {
	if [ -f "$organizr_config" ] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
		grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
	fi
}

# Remove app from Organizr protected apps and nginx includes
_exclude_from_organizr() {
	local modified=false
	local apps_include="/etc/nginx/snippets/organizr-apps.conf"

	# Remove from protected apps config
	if [ -f "$organizr_config" ] && grep -q "^${app_name}:" "$organizr_config"; then
		echo_progress_start "Removing ${app_name^} from Organizr protected apps"
		sed -i "/^${app_name}:/d" "$organizr_config"
		modified=true
	fi

	# Remove from apps include file
	if [ -f "$apps_include" ] && grep -q "include /etc/nginx/apps/${app_name}.conf;" "$apps_include"; then
		sed -i "\|include /etc/nginx/apps/${app_name}.conf;|d" "$apps_include"
		modified=true
	fi

	if [ "$modified" = true ]; then
		echo_progress_done "Removed from Organizr"
	fi
}

# Re-add app to Organizr protected apps (for revert)
_include_in_organizr() {
	if [ -f "$organizr_config" ] && ! grep -q "^${app_name}:" "$organizr_config"; then
		echo_info "Note: ${app_name^} can be re-added to Organizr protection via: bash organizr-subdomain.sh --configure"
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
			echo_error "PLEX_DOMAIN must be set (e.g., export PLEX_DOMAIN=\"plex.example.com\")"
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
	else
		# Subfolder config or no config - treat as subfolder (ready for subdomain conversion)
		echo "subfolder"
	fi
}

# Install Plex with nginx config if not installed
_install_app() {
	if [ ! -f "/install/.${app_lockname}.lock" ]; then
		echo_info "Installing ${app_name^} via plex.sh..."
		# Download and run plex.sh to install plex with nginx subfolder
		local plex_script="/tmp/plex.sh"
		curl -fsSL "https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/plex.sh" -o "$plex_script" || {
			echo_error "Failed to download plex.sh"
			exit 1
		}
		bash "$plex_script" || {
			echo_error "Failed to install ${app_name^}"
			exit 1
		}
		rm -f "$plex_script"
	elif [ ! -f "$subfolder_conf" ]; then
		# Plex installed but no nginx config - create it
		echo_info "Creating nginx subfolder config..."
		cat >"$subfolder_conf" <<-NGX
			location /plex {
			    return 301 \$scheme://\$host/plex/;
			}

			location ^~ /plex/ {
			    rewrite /plex/(.*) /\$1 break;
			    include /etc/nginx/snippets/proxy.conf;
			    proxy_pass http://127.0.0.1:${app_port};

			    proxy_set_header X-Plex-Client-Identifier \$http_x_plex_client_identifier;
			    proxy_set_header X-Plex-Device \$http_x_plex_device;
			    proxy_set_header X-Plex-Device-Name \$http_x_plex_device_name;
			    proxy_set_header X-Plex-Platform \$http_x_plex_platform;
			    proxy_set_header X-Plex-Platform-Version \$http_x_plex_platform_version;
			    proxy_set_header X-Plex-Product \$http_x_plex_product;
			    proxy_set_header X-Plex-Token \$http_x_plex_token;
			    proxy_set_header X-Plex-Version \$http_x_plex_version;
			    proxy_set_header X-Plex-Nocache \$http_x_plex_nocache;
			    proxy_set_header X-Plex-Provides \$http_x_plex_provides;
			    proxy_set_header X-Plex-Device-Vendor \$http_x_plex_device_vendor;
			    proxy_set_header X-Plex-Model \$http_x_plex_model;
			}

			if (\$http_referer ~* /plex) {
			    rewrite ^/web/(.*) /plex/web/\$1? redirect;
			}
		NGX
		systemctl reload nginx
	else
		echo_info "${app_name^} already installed"
	fi
}

# Request Let's Encrypt certificate
_request_certificate() {
	local domain="$1"
	local le_hostname="${PLEX_LE_HOSTNAME:-$domain}"
	local cert_dir="/etc/nginx/ssl/$le_hostname"
	local le_interactive="${PLEX_LE_INTERACTIVE:-no}"

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
    proxy_redirect off;
    proxy_buffering off;

    ${csp_header}

    location / {
        include snippets/proxy.conf;
        proxy_pass http://127.0.0.1:${app_port}/;

        proxy_set_header X-Plex-Client-Identifier \$http_x_plex_client_identifier;
        proxy_set_header X-Plex-Device \$http_x_plex_device;
        proxy_set_header X-Plex-Device-Name \$http_x_plex_device_name;
        proxy_set_header X-Plex-Platform \$http_x_plex_platform;
        proxy_set_header X-Plex-Platform-Version \$http_x_plex_platform_version;
        proxy_set_header X-Plex-Product \$http_x_plex_product;
        proxy_set_header X-Plex-Token \$http_x_plex_token;
        proxy_set_header X-Plex-Version \$http_x_plex_version;
        proxy_set_header X-Plex-Nocache \$http_x_plex_nocache;
        proxy_set_header X-Plex-Provides \$http_x_plex_provides;
        proxy_set_header X-Plex-Device-Vendor \$http_x_plex_device_vendor;
        proxy_set_header X-Plex-Model \$http_x_plex_model;
    }

    location /library/streams/ {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_pass_request_headers off;
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
    baseurl = None
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

# Main install flow
_install() {
	local domain
	domain=$(_get_domain)
	local le_hostname="${PLEX_LE_HOSTNAME:-$domain}"
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
		_exclude_from_organizr
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
		# Recreate default subfolder config
		echo_info "Recreating subfolder config..."
		cat >"$subfolder_conf" <<-NGX
			location /plex {
			    return 301 \$scheme://\$host/plex/;
			}

			location ^~ /plex/ {
			    rewrite /plex/(.*) /\$1 break;
			    include /etc/nginx/snippets/proxy.conf;
			    proxy_pass http://127.0.0.1:${app_port};

			    proxy_set_header X-Plex-Client-Identifier \$http_x_plex_client_identifier;
			    proxy_set_header X-Plex-Device \$http_x_plex_device;
			    proxy_set_header X-Plex-Device-Name \$http_x_plex_device_name;
			    proxy_set_header X-Plex-Platform \$http_x_plex_platform;
			    proxy_set_header X-Plex-Platform-Version \$http_x_plex_platform_version;
			    proxy_set_header X-Plex-Product \$http_x_plex_product;
			    proxy_set_header X-Plex-Token \$http_x_plex_token;
			    proxy_set_header X-Plex-Version \$http_x_plex_version;
			    proxy_set_header X-Plex-Nocache \$http_x_plex_nocache;
			    proxy_set_header X-Plex-Provides \$http_x_plex_provides;
			    proxy_set_header X-Plex-Device-Vendor \$http_x_plex_device_vendor;
			    proxy_set_header X-Plex-Model \$http_x_plex_model;
			}

			if (\$http_referer ~* /plex) {
			    rewrite ^/web/(.*) /plex/web/\$1? redirect;
			}
		NGX
	fi

	# Remove panel meta override
	_remove_panel_meta

	# Notify about Organizr re-protection
	_include_in_organizr

	systemctl reload nginx
	echo_success "${app_name^} reverted to subfolder mode"
	echo_info "Access at: https://your-server/plex/"
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
		# Remove subdomain vhost
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
