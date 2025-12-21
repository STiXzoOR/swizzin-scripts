#!/bin/bash
# ==============================================================================
# SUBDOMAIN CONVERTER TEMPLATE
# ==============================================================================
# Template for converting existing Swizzin apps from subfolder to subdomain mode
# Examples: plex-subdomain, emby-subdomain, jellyfin-subdomain
#
# Usage: bash <appname>-subdomain.sh [--revert|--remove [--force]]
#
# Required Environment:
#   <APPNAME>_DOMAIN      - Public FQDN for the app (e.g., plex.example.com)
#
# Optional Environment:
#   <APPNAME>_LE_HOSTNAME     - Let's Encrypt hostname (defaults to domain)
#   <APPNAME>_LE_INTERACTIVE  - Set to "yes" for interactive LE (CloudFlare DNS)
#
# CUSTOMIZATION POINTS (search for "# CUSTOMIZE:"):
# 1. App variables (name, port, lock name)
# 2. Nginx vhost configuration in _create_subdomain_vhost()
# 3. Subfolder config restoration in _revert()
# ==============================================================================

# CUSTOMIZE: Replace "myapp" with your app name throughout this file
# Tip: Use sed 's/myapp/yourapp/g' and 's/Myapp/Yourapp/g' and 's/MYAPP/YOURAPP/g'

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# ==============================================================================
# Logging
# ==============================================================================
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# App Configuration
# ==============================================================================
# CUSTOMIZE: Set app-specific variables

app_name="myapp"
app_port="8080"                       # The port the app listens on
app_lockname="myapp"                  # Lock file name (usually same as app_name)

# File paths
backup_dir="/opt/swizzin/${app_name}-backups"
subfolder_conf="/etc/nginx/apps/${app_name}.conf"
subdomain_vhost="/etc/nginx/sites-available/${app_name}"
subdomain_enabled="/etc/nginx/sites-enabled/${app_name}"
profiles_py="/opt/swizzin/core/custom/profiles.py"
organizr_config="/opt/swizzin/organizr-auth.conf"

# ==============================================================================
# Environment Helpers
# ==============================================================================

# Get domain from env
# CUSTOMIZE: Change MYAPP_DOMAIN to match your app
_get_domain() {
	echo "${MYAPP_DOMAIN:-}"
}

# Get Organizr domain for frame-ancestors (if configured)
_get_organizr_domain() {
	if [[ -f "$organizr_config" ]] && grep -q "^ORGANIZR_DOMAIN=" "$organizr_config"; then
		grep "^ORGANIZR_DOMAIN=" "$organizr_config" | cut -d'"' -f2
	fi
}

# ==============================================================================
# Organizr Integration
# ==============================================================================

# Remove app from Organizr protected apps and nginx includes
_exclude_from_organizr() {
	local modified=false
	local apps_include="/etc/nginx/snippets/organizr-apps.conf"

	# Remove from protected apps config
	if [[ -f "$organizr_config" ]] && grep -q "^${app_name}:" "$organizr_config"; then
		echo_progress_start "Removing ${app_name^} from Organizr protected apps"
		sed -i "/^${app_name}:/d" "$organizr_config"
		modified=true
	fi

	# Remove from apps include file
	if [[ -f "$apps_include" ]] && grep -q "include /etc/nginx/apps/${app_name}.conf;" "$apps_include"; then
		sed -i "\|include /etc/nginx/apps/${app_name}.conf;|d" "$apps_include"
		modified=true
	fi

	if [[ "$modified" == "true" ]]; then
		echo_progress_done "Removed from Organizr"
	fi
}

# Notify about re-adding to Organizr (for revert)
_include_in_organizr() {
	if [[ -f "$organizr_config" ]] && ! grep -q "^${app_name}:" "$organizr_config"; then
		echo_info "Note: ${app_name^} can be re-added to Organizr protection via: bash organizr-subdomain.sh --configure"
	fi
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================
_preflight() {
	if [[ ! -f /install/.nginx.lock ]]; then
		echo_error "nginx is not installed. Please install nginx first."
		exit 1
	fi

	if [[ "$1" != "revert" ]] && [[ "$1" != "remove" ]]; then
		local domain
		domain=$(_get_domain)
		if [[ -z "$domain" ]]; then
			# CUSTOMIZE: Update env var name
			echo_error "MYAPP_DOMAIN must be set (e.g., export MYAPP_DOMAIN=\"myapp.example.com\")"
			exit 1
		fi
	fi
}

# ==============================================================================
# State Detection
# ==============================================================================
_get_install_state() {
	if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo "not_installed"
	elif [[ -f "$subdomain_vhost" ]]; then
		echo "subdomain"
	else
		# Subfolder config or no config - treat as subfolder (ready for conversion)
		echo "subfolder"
	fi
}

# ==============================================================================
# Base App Installation
# ==============================================================================
_install_app() {
	if [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_info "Installing ${app_name^} via box install ${app_name}..."
		box install "$app_name" || {
			echo_error "Failed to install ${app_name^}"
			exit 1
		}
	else
		echo_info "${app_name^} already installed"
	fi
}

# ==============================================================================
# Let's Encrypt Certificate
# ==============================================================================
_request_certificate() {
	local domain="$1"
	# CUSTOMIZE: Update env var names
	local le_hostname="${MYAPP_LE_HOSTNAME:-$domain}"
	local cert_dir="/etc/nginx/ssl/${le_hostname}"
	local le_interactive="${MYAPP_LE_INTERACTIVE:-no}"

	if [[ -d "$cert_dir" ]]; then
		echo_info "Let's Encrypt certificate already exists for ${le_hostname}"
		return 0
	fi

	echo_info "Requesting Let's Encrypt certificate for ${le_hostname}"

	if [[ "$le_interactive" == "yes" ]]; then
		echo_info "Running Let's Encrypt in interactive mode..."
		LE_HOSTNAME="$le_hostname" box install letsencrypt </dev/tty
		local result=$?
	else
		LE_HOSTNAME="$le_hostname" LE_DEFAULTCONF=no LE_BOOL_CF=no \
			box install letsencrypt >>"$log" 2>&1
		local result=$?
	fi

	if [[ $result -ne 0 ]]; then
		echo_error "Failed to obtain Let's Encrypt certificate for ${le_hostname}"
		echo_error "Check $log for details or run manually: LE_HOSTNAME=${le_hostname} box install letsencrypt"
		exit 1
	fi

	echo_info "Let's Encrypt certificate issued for ${le_hostname}"
}

# ==============================================================================
# Backup Helpers
# ==============================================================================
_ensure_backup_dir() {
	if [[ ! -d "$backup_dir" ]]; then
		mkdir -p "$backup_dir"
	fi
}

_backup_file() {
	local src="$1"
	local name
	name=$(basename "$src")
	_ensure_backup_dir
	if [[ -f "$src" ]]; then
		cp "$src" "${backup_dir}/${name}.bak"
	fi
}

# ==============================================================================
# Subdomain Vhost Creation
# ==============================================================================
_create_subdomain_vhost() {
	local domain="$1"
	local le_hostname="${2:-$domain}"
	local cert_dir="/etc/nginx/ssl/${le_hostname}"
	local organizr_domain
	organizr_domain=$(_get_organizr_domain)

	echo_progress_start "Creating subdomain nginx vhost"

	# Backup and remove subfolder config
	if [[ -f "$subfolder_conf" ]]; then
		_backup_file "$subfolder_conf"
		rm -f "$subfolder_conf"
	fi

	# Build CSP header for Organizr embedding
	local csp_header=""
	if [[ -n "$organizr_domain" ]]; then
		csp_header="add_header Content-Security-Policy \"frame-ancestors 'self' https://${organizr_domain}\";"
	fi

	# CUSTOMIZE: Adjust the vhost configuration for your app
	cat >"$subdomain_vhost" <<VHOST
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

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
    server_name ${domain};

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
    }
}
VHOST

	# Enable site
	if [[ ! -L "$subdomain_enabled" ]]; then
		ln -s "$subdomain_vhost" "$subdomain_enabled"
	fi

	echo_progress_done "Subdomain vhost created"
}

# ==============================================================================
# Panel Meta Management
# ==============================================================================
_add_panel_meta() {
	local domain="$1"

	echo_progress_start "Adding panel meta urloverride"

	# Ensure profiles.py exists
	mkdir -p "$(dirname "$profiles_py")"
	touch "$profiles_py"

	# Remove existing override if present
	sed -i "/^class ${app_name}_meta(${app_name}_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true

	# Add new override
	cat >>"$profiles_py" <<-PYTHON

		class ${app_name}_meta(${app_name}_meta):
		    baseurl = None
		    urloverride = "https://${domain}"
	PYTHON

	echo_progress_done "Panel meta updated"
}

_remove_panel_meta() {
	if [[ -f "$profiles_py" ]]; then
		echo_progress_start "Removing panel meta urloverride"
		sed -i "/^class ${app_name}_meta(${app_name}_meta):/,/^class \|^$/d" "$profiles_py" 2>/dev/null || true
		# Clean up empty lines at end of file
		sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$profiles_py" 2>/dev/null || true
		echo_progress_done "Panel meta removed"
	fi
}

# ==============================================================================
# Main Install Flow
# ==============================================================================
_install() {
	local domain
	domain=$(_get_domain)
	# CUSTOMIZE: Update env var name
	local le_hostname="${MYAPP_LE_HOSTNAME:-$domain}"
	local state
	state=$(_get_install_state)

	echo_info "${app_name^} Subdomain Setup"
	echo_info "Domain: ${domain}"
	[[ "$le_hostname" != "$domain" ]] && echo_info "LE Hostname: ${le_hostname}"
	echo_info "Current state: ${state}"

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
		echo_info "Access at: https://${domain}"
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

# ==============================================================================
# Revert to Subfolder Mode
# ==============================================================================
_revert() {
	echo_info "Reverting ${app_name^} to subfolder mode..."

	# Remove subdomain vhost
	if [[ -L "$subdomain_enabled" ]]; then
		rm -f "$subdomain_enabled"
	fi
	if [[ -f "$subdomain_vhost" ]]; then
		rm -f "$subdomain_vhost"
	fi

	# Restore subfolder config
	if [[ -f "${backup_dir}/${app_name}.conf.bak" ]]; then
		cp "${backup_dir}/${app_name}.conf.bak" "$subfolder_conf"
		echo_info "Restored subfolder nginx config"
	else
		# CUSTOMIZE: Recreate default subfolder config for your app
		echo_info "Recreating subfolder config..."
		cat >"$subfolder_conf" <<-NGX
			location /${app_name} {
			    return 301 /${app_name}/;
			}

			location ^~ /${app_name}/ {
			    include snippets/proxy.conf;
			    proxy_pass http://127.0.0.1:${app_port}/;
			}
		NGX
	fi

	# Remove panel meta override
	_remove_panel_meta

	# Notify about Organizr re-protection
	_include_in_organizr

	systemctl reload nginx
	echo_success "${app_name^} reverted to subfolder mode"
	echo_info "Access at: https://your-server/${app_name}/"
}

# ==============================================================================
# Complete Removal
# ==============================================================================
_remove() {
	local force="$1"

	if [[ "$force" != "--force" ]] && [[ ! -f "/install/.${app_lockname}.lock" ]]; then
		echo_error "${app_name^} is not installed (use --force to override)"
		exit 1
	fi

	echo_info "Removing ${app_name^}..."

	# Revert first if on subdomain
	if [[ -f "$subdomain_vhost" ]]; then
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

# ==============================================================================
# Main
# ==============================================================================
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
