#!/bin/bash
# organizr-subdomain - Convert Organizr to subdomain with SSO authentication
# STiXzoOR 2025
# Usage: bash organizr-subdomain.sh [--configure|--revert|--remove]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

#shellcheck source=sources/functions/php
. /etc/swizzin/sources/functions/php

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

app_name="organizr"
app_dir="/srv/organizr"
app_db_dir="/srv/organizr_db"
config_dir="/opt/swizzin"
config_file="$config_dir/organizr-auth.conf"
backup_dir="$config_dir/organizr-backups"
auth_snippet="/etc/nginx/snippets/organizr-auth.conf"
subfolder_conf="/etc/nginx/apps/organizr.conf"
subdomain_vhost="/etc/nginx/sites-available/organizr"
subdomain_enabled="/etc/nginx/sites-enabled/organizr"

# Get domain from config file if exists, otherwise from env
_get_domain() {
	if [ -f "$config_file" ] && grep -q "^ORGANIZR_DOMAIN=" "$config_file"; then
		grep "^ORGANIZR_DOMAIN=" "$config_file" | cut -d'"' -f2
	else
		echo "${ORGANIZR_DOMAIN:-}"
	fi
}

# Pre-flight checks
_preflight() {
	# Check nginx
	if [ ! -f /install/.nginx.lock ]; then
		echo_error "nginx is not installed. Please install nginx first."
		exit 1
	fi

	# Check domain for install/configure
	if [ "$1" != "revert" ] && [ "$1" != "remove" ]; then
		local domain
		domain=$(_get_domain)
		if [ -z "$domain" ]; then
			echo_error "ORGANIZR_DOMAIN must be set (e.g., export ORGANIZR_DOMAIN=\"organizr.example.com\")"
			exit 1
		fi
	fi
}

# Check current state of Organizr installation
_get_install_state() {
	if [ ! -f /install/.organizr.lock ]; then
		echo "not_installed"
	elif [ -f "$subdomain_vhost" ]; then
		echo "subdomain"
	elif [ -f "$subfolder_conf" ]; then
		echo "subfolder"
	else
		echo "unknown"
	fi
}

# Install Organizr via box if not installed
_install_organizr() {
	if [ ! -f /install/.organizr.lock ]; then
		echo_info "Installing Organizr via box install organizr..."
		box install organizr || {
			echo_error "Failed to install Organizr"
			exit 1
		}
	else
		echo_info "Organizr already installed"
	fi
}

# Request Let's Encrypt certificate
_request_certificate() {
	local domain="$1"
	local cert_dir="/etc/nginx/ssl/$domain"

	if [ -d "$cert_dir" ]; then
		echo_info "Let's Encrypt certificate already exists for $domain"
		return 0
	fi

	echo_info "Requesting Let's Encrypt certificate for $domain"
	LE_HOSTNAME="$domain" LE_DEFAULTCONF=no LE_BOOL_CF=no \
		box install letsencrypt >>"$log" 2>&1
	local result=$?

	if [ $result -ne 0 ]; then
		echo_error "Failed to obtain Let's Encrypt certificate for $domain"
		echo_error "Check $log for details or run manually: LE_HOSTNAME=$domain box install letsencrypt"
		exit 1
	fi

	echo_info "Let's Encrypt certificate issued for $domain"
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

# Create subdomain nginx vhost
_create_subdomain_vhost() {
	local domain="$1"
	local phpv
	phpv=$(php_service_version)
	local cert_dir="/etc/nginx/ssl/$domain"

	echo_progress_start "Creating subdomain nginx vhost"

	# Backup and remove subfolder config
	if [ -f "$subfolder_conf" ]; then
		_backup_file "$subfolder_conf"
		rm -f "$subfolder_conf"
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

    include /etc/nginx/apps/*.conf;

    root /srv/organizr;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${phpv}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffers 32 32k;
        fastcgi_buffer_size 32k;
    }

    location /api/v2 {
        try_files \$uri /api/v2/index.php\$is_args\$args;
    }

    location ~ /\.ht {
        deny all;
    }
}
VHOST

	# Enable site
	if [ ! -L "$subdomain_enabled" ]; then
		ln -s "$subdomain_vhost" "$subdomain_enabled"
	fi

	echo_progress_done "Subdomain vhost created"
}

# Create organizr auth snippet
_create_auth_snippet() {
	local domain="$1"

	echo_progress_start "Creating Organizr auth snippet"

	cat >"$auth_snippet" <<SNIPPET
# Organizr SSO Authentication
# Include this in app configs and add: auth_request /organizr-auth/auth-0;

location ~ /organizr-auth/auth-([0-9]+) {
    internal;
    proxy_pass https://$domain/api/v2/auth?group=\$1;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URI \$request_uri;
}

# Redirect 401 to Organizr login
error_page 401 = @organizr_login;
location @organizr_login {
    return 302 https://$domain/?error=\$status&return=\$scheme://\$http_host\$request_uri;
}
SNIPPET

	echo_progress_done "Auth snippet created"
}

# Get list of installed apps with nginx configs
_get_available_apps() {
	local apps=()
	for conf in /etc/nginx/apps/*.conf; do
		[ -f "$conf" ] || continue
		local name
		name=$(basename "$conf" .conf)
		# Skip organizr itself and some special configs
		case "$name" in
		organizr | default | ssl) continue ;;
		esac
		apps+=("$name")
	done
	echo "${apps[@]}"
}

# Interactive app selection using whiptail
_select_apps() {
	local available_apps
	read -ra available_apps <<<"$(_get_available_apps)"

	if [ ${#available_apps[@]} -eq 0 ]; then
		echo_warn "No apps found to protect"
		return
	fi

	# Build whiptail options
	local options=()
	for app in "${available_apps[@]}"; do
		# Check if already in config
		if [ -f "$config_file" ] && grep -q "^${app}:" "$config_file"; then
			options+=("$app" "" "ON")
		else
			options+=("$app" "" "OFF")
		fi
	done

	# Show selection dialog
	local selected
	selected=$(whiptail --title "Organizr SSO Setup" \
		--checklist "Select apps to protect with Organizr authentication:\n(Space to toggle, Enter to confirm)" \
		20 60 10 \
		"${options[@]}" \
		3>&1 1>&2 2>&3) || {
		echo_info "App selection cancelled"
		return 1
	}

	# Parse selected apps (whiptail returns "app1" "app2" format)
	selected=$(echo "$selected" | tr -d '"')

	# Update config file
	_update_config "$selected"
}

# Update config file with selected apps
_update_config() {
	local selected_apps="$1"
	local domain
	domain=$(_get_domain)

	mkdir -p "$config_dir"

	# Write config header
	cat >"$config_file" <<CONFIG
# Organizr SSO Configuration
# Format: app_name:auth_level
# Auth levels: 0=Admin, 1=Co-Admin, 2=Super User, 3=Power User, 4=User, 998=Logged In
# Re-run 'bash organizr-subdomain.sh --configure' after editing

ORGANIZR_DOMAIN="$domain"

# Protected apps (default: 0 = Admin only)
CONFIG

	# Add selected apps
	for app in $selected_apps; do
		# Check if app has existing auth level in old config
		local level=0
		if [ -f "$config_file.tmp" ] && grep -q "^${app}:" "$config_file.tmp"; then
			level=$(grep "^${app}:" "$config_file.tmp" | cut -d: -f2)
		fi
		echo "${app}:${level}" >>"$config_file"
	done

	echo_info "Config saved to $config_file"
}

# Get protected apps from config
_get_protected_apps() {
	if [ ! -f "$config_file" ]; then
		return
	fi
	grep -E "^[a-zA-Z0-9_-]+:[0-9]+$" "$config_file" || true
}

# Modify app nginx config to use Organizr auth
_protect_app() {
	local app="$1"
	local auth_level="$2"
	local conf="/etc/nginx/apps/${app}.conf"

	if [ ! -f "$conf" ]; then
		echo_warn "Config not found for $app, skipping"
		return
	fi

	# Skip if already has auth_request
	if grep -q "auth_request /organizr-auth" "$conf"; then
		echo_info "$app already protected, updating auth level"
		sed -i "s|auth_request /organizr-auth/auth-[0-9]*;|auth_request /organizr-auth/auth-${auth_level};|g" "$conf"
		return
	fi

	# Backup original
	_backup_file "$conf"

	echo_progress_start "Protecting $app with Organizr auth"

	# Comment out existing auth_basic
	sed -i 's/^\([[:space:]]*auth_basic\)/#\1/g' "$conf"
	sed -i 's/^\([[:space:]]*auth_basic_user_file\)/#\1/g' "$conf"

	# Find first location block and add auth after it
	# Using a temp file for complex sed
	local temp_conf
	temp_conf=$(mktemp)

	awk -v snippet="$auth_snippet" -v level="$auth_level" '
	/location.*{/ && !added {
		print
		getline
		print
		print "        include /etc/nginx/snippets/organizr-auth.conf;"
		print "        auth_request /organizr-auth/auth-" level ";"
		print ""
		added=1
		next
	}
	{print}
	' "$conf" >"$temp_conf"

	mv "$temp_conf" "$conf"

	echo_progress_done "$app protected"
}

# Remove Organizr auth from app config
_unprotect_app() {
	local app="$1"
	local conf="/etc/nginx/apps/${app}.conf"
	local backup="$backup_dir/${app}.conf.bak"

	if [ ! -f "$conf" ]; then
		return
	fi

	echo_progress_start "Removing Organizr auth from $app"

	# Remove auth_request and include lines
	sed -i '/include \/etc\/nginx\/snippets\/organizr-auth.conf;/d' "$conf"
	sed -i '/auth_request \/organizr-auth\/auth-[0-9]*;/d' "$conf"

	# Uncomment auth_basic
	sed -i 's/^#\([[:space:]]*auth_basic\)/\1/g' "$conf"
	sed -i 's/^#\([[:space:]]*auth_basic_user_file\)/\1/g' "$conf"

	echo_progress_done "$app auth removed"
}

# Apply protection to all configured apps
_apply_protection() {
	local protected_apps
	protected_apps=$(_get_protected_apps)

	if [ -z "$protected_apps" ]; then
		echo_info "No apps configured for protection"
		return
	fi

	echo "$protected_apps" | while IFS=: read -r app level; do
		_protect_app "$app" "$level"
	done
}

# Remove protection from all apps
_remove_all_protection() {
	local available_apps
	read -ra available_apps <<<"$(_get_available_apps)"

	for app in "${available_apps[@]}"; do
		_unprotect_app "$app"
	done
}

# Main install/convert flow
_install() {
	local domain
	domain=$(_get_domain)
	local state
	state=$(_get_install_state)

	echo_info "Organizr Subdomain Setup"
	echo_info "Domain: $domain"
	echo_info "Current state: $state"

	case "$state" in
	"not_installed")
		_install_organizr
		;&  # fallthrough
	"subfolder")
		_request_certificate "$domain"
		_create_subdomain_vhost "$domain"
		_create_auth_snippet "$domain"
		_select_apps
		_apply_protection
		systemctl reload nginx
		reload_php_fpm
		echo_success "Organizr converted to subdomain mode"
		echo_info "Access at: https://$domain"
		;;
	"subdomain")
		echo_info "Already in subdomain mode, running configure..."
		_configure
		;;
	*)
		echo_error "Unknown installation state"
		exit 1
		;;
	esac
}

# Configure mode - just update app selection
_configure() {
	local domain
	domain=$(_get_domain)

	if [ -z "$domain" ]; then
		echo_error "Organizr is not configured in subdomain mode"
		exit 1
	fi

	# Save current config for reference
	if [ -f "$config_file" ]; then
		cp "$config_file" "$config_file.tmp"
	fi

	_select_apps

	# Remove protection from apps no longer in list
	local available_apps
	read -ra available_apps <<<"$(_get_available_apps)"
	local protected_apps
	protected_apps=$(_get_protected_apps)

	for app in "${available_apps[@]}"; do
		if ! echo "$protected_apps" | grep -q "^${app}:"; then
			_unprotect_app "$app"
		fi
	done

	# Apply protection to configured apps
	_apply_protection

	# Cleanup temp file
	rm -f "$config_file.tmp"

	systemctl reload nginx
	echo_success "Organizr SSO configuration updated"
}

# Revert to subfolder mode
_revert() {
	echo_info "Reverting Organizr to subfolder mode..."

	# Remove protection from all apps
	_remove_all_protection

	# Remove subdomain vhost
	if [ -L "$subdomain_enabled" ]; then
		rm -f "$subdomain_enabled"
	fi
	if [ -f "$subdomain_vhost" ]; then
		rm -f "$subdomain_vhost"
	fi

	# Restore subfolder config
	if [ -f "$backup_dir/organizr.conf.bak" ]; then
		cp "$backup_dir/organizr.conf.bak" "$subfolder_conf"
		echo_info "Restored subfolder nginx config"
	else
		# Recreate using swizzin's script
		echo_info "Recreating subfolder config..."
		bash /usr/local/bin/swizzin/nginx/organizr.sh
	fi

	# Keep auth snippet and config for future use
	echo_info "Config preserved at $config_file for future re-enable"

	systemctl reload nginx
	echo_success "Organizr reverted to subfolder mode"
	echo_info "Access at: https://your-server/organizr/"
}

# Complete removal
_remove() {
	echo_info "Removing Organizr subdomain setup..."

	# Ask about purging
	if ask "Would you like to completely remove Organizr?" N; then
		# Revert first
		_revert

		# Remove organizr via box
		echo_info "Removing Organizr via box remove organizr..."
		box remove organizr

		# Remove our files
		rm -f "$auth_snippet"
		rm -f "$config_file"
		rm -rf "$backup_dir"

		echo_success "Organizr completely removed"
		echo_info "Note: Let's Encrypt certificate was not removed"
	else
		echo_info "Removal cancelled"
	fi
}

# Main
_preflight "$1"

case "$1" in
"--configure")
	_configure
	;;
"--revert")
	_revert
	;;
"--remove")
	_remove
	;;
"")
	_install
	;;
*)
	echo "Usage: $0 [--configure|--revert|--remove]"
	echo ""
	echo "  (no args)    Install/convert Organizr to subdomain mode"
	echo "  --configure  Modify which apps are protected"
	echo "  --revert     Revert to subfolder mode"
	echo "  --remove     Completely remove Organizr"
	exit 1
	;;
esac
