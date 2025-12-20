#!/bin/bash
# plex nginx subfolder installer
# Extends Swizzin's Plex install with nginx subfolder config
# STiXzoOR 2025
# Usage: bash plex.sh [--remove [--force]]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

app_name="plex"
app_port="32400"
app_lockname="plex"

# Pre-flight checks
_preflight() {
	if [ ! -f /install/.nginx.lock ]; then
		echo_error "nginx is not installed. Please install nginx first."
		exit 1
	fi
}

# Install Plex via box if not installed
_install_plex() {
	if [ ! -f "/install/.plex.lock" ]; then
		echo_info "Installing Plex via box install plex..."
		box install plex || {
			echo_error "Failed to install Plex"
			exit 1
		}
	else
		echo_info "Plex already installed"
	fi
}

# Create nginx subfolder config
_nginx_plex() {
	if [ -f "/etc/nginx/apps/$app_name.conf" ]; then
		echo_info "nginx config already exists at /etc/nginx/apps/$app_name.conf"
		return
	fi

	echo_progress_start "Creating nginx subfolder config"

	cat >"/etc/nginx/apps/$app_name.conf" <<-'NGX'
		location /plex/ {
		    rewrite /plex/(.*) /$1 break;
		    include /etc/nginx/snippets/proxy.conf;
		    proxy_pass http://127.0.0.1:32400/;
		}
	NGX

	systemctl reload nginx
	echo_progress_done "nginx configured for /plex/"
}

# Remove plex nginx config and uninstall
_remove_plex() {
	local force="$1"
	if [ "$force" != "--force" ] && [ ! -f "/install/.$app_lockname.lock" ]; then
		echo_error "${app_name^} is not installed (use --force to override)"
		exit 1
	fi

	echo_info "Removing ${app_name^}..."

	# Remove nginx config
	if [ -f "/etc/nginx/apps/$app_name.conf" ]; then
		echo_progress_start "Removing nginx configuration"
		rm -f "/etc/nginx/apps/$app_name.conf"
		systemctl reload nginx 2>/dev/null || true
		echo_progress_done "nginx configuration removed"
	fi

	# Remove plex via box
	echo_info "Removing Plex via box remove plex..."
	box remove plex

	echo_success "${app_name^} has been removed"
	exit 0
}

# Handle --remove flag
if [ "$1" = "--remove" ]; then
	_remove_plex "$2"
fi

_preflight
_install_plex
_nginx_plex

echo_success "${app_name^} nginx subfolder configured"
echo_info "Access at: https://your-server/plex/"
