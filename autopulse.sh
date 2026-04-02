#!/bin/bash
set -euo pipefail
# autopulse installer
# STiXzoOR 2026
# Usage: bash autopulse.sh [--update [--verbose]|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# shellcheck source=lib/utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true

# shellcheck source=lib/nginx-utils.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/nginx-utils.sh" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HELPER_CACHE="/opt/swizzin-extras/panel_helpers.sh"

_load_panel_helper() {
	if [[ -f "${SCRIPT_DIR}/panel_helpers.sh" ]]; then
		. "${SCRIPT_DIR}/panel_helpers.sh"
		return
	fi
	if [[ -f "$PANEL_HELPER_CACHE" ]]; then
		. "$PANEL_HELPER_CACHE"
		return
	fi
	echo_info "panel_helpers.sh not found; skipping panel integration"
}

# Log to Swizzin.log
export log=/root/logs/swizzin.log
touch "$log"

# ==============================================================================
# Cleanup Trap (rollback partial install on failure)
# ==============================================================================
_cleanup_needed=false
_nginx_config_written=""
_systemd_unit_written=""
_lock_file_created=""

cleanup() {
	local exit_code=$?
	if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
		echo_error "Installation failed (exit $exit_code). Cleaning up..."
		[[ -n "$_nginx_config_written" ]] && rm -f "$_nginx_config_written"
		[[ -n "$_systemd_unit_written" ]] && {
			systemctl stop "${_systemd_unit_written}" 2>/dev/null || true
			systemctl disable "${_systemd_unit_written}" 2>/dev/null || true
			rm -f "/etc/systemd/system/${_systemd_unit_written}"
		}
		[[ -n "$_lock_file_created" ]] && rm -f "$_lock_file_created"
		_reload_nginx 2>/dev/null || true
	fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Verbose Mode
# ==============================================================================
verbose=false

_verbose() {
	if [[ "$verbose" == "true" ]]; then
		echo_info "  $*"
	fi
}

# ==============================================================================
# App Configuration
# ==============================================================================

app_name="autopulse"
app_pretty="Autopulse"
app_lockname="${app_name}"
app_baseurl="${app_name}"
app_image_api="ghcr.io/dan-online/autopulse:latest"
app_image_ui="ghcr.io/dan-online/autopulse:ui-dynamic"

app_dir="/opt/${app_name}"
app_servicefile="${app_name}.service"

app_icon_name="${app_name}"
app_icon_url="https://raw.githubusercontent.com/dan-online/autopulse/main/ui/static/favicon.png"

# ==============================================================================
# User/Owner Setup
# ==============================================================================

if ! app_owner="$(swizdb get "${app_name}/owner" 2>/dev/null)"; then
	app_owner="$(_get_master_username)"
fi
user="${app_owner}"
app_group="${user}"

# Port persistence — API port
if _existing_port="$(swizdb get "${app_name}/port" 2>/dev/null)" && [[ -n "$_existing_port" ]]; then
	app_port="$_existing_port"
elif [[ -n "${AUTOPULSE_PORT:-}" ]]; then
	app_port="$AUTOPULSE_PORT"
else
	app_port=$(port 10000 12000)
fi

# Port persistence — UI port
if _existing_ui_port="$(swizdb get "${app_name}/ui_port" 2>/dev/null)" && [[ -n "$_existing_ui_port" ]]; then
	app_ui_port="$_existing_ui_port"
elif [[ -n "${AUTOPULSE_UI_PORT:-}" ]]; then
	app_ui_port="$AUTOPULSE_UI_PORT"
else
	app_ui_port=$(port 10000 12000)
fi
