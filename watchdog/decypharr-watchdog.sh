#!/bin/bash
# decypharr-watchdog.sh - Decypharr log-based watchdog
# STiXzoOR 2026
#
# Detects "no debrid clients available" errors in Decypharr logs
# and restarts the service when sustained failures are found.
#
# Unlike the HTTP-based media server watchdogs, Decypharr's API returns
# 200 even when debrid connectivity is broken, so this watchdog monitors
# the application log for the specific error pattern instead.
#
# Usage:
#   decypharr-watchdog.sh              # Run the check (called by cron)
#   decypharr-watchdog.sh --install    # Install cron job
#   decypharr-watchdog.sh --remove     # Remove cron job
#   decypharr-watchdog.sh --status     # Show watchdog status
#   decypharr-watchdog.sh --reset      # Clear cooldown state

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

SERVICE_NAME="decypharr"
APP_NAME="Decypharr"
SWIZZIN_USER="${SWIZZIN_USER:-raflix}"
LOG_FILE_APP="/home/${SWIZZIN_USER}/.config/Decypharr/logs/decypharr.log"
ERROR_PATTERN="no debrid clients available"

# How far back to look for errors (seconds)
CHECK_WINDOW=300  # 5 minutes

# Minimum errors within the window to trigger a restart
ERROR_THRESHOLD=5

# Max restarts before entering cooldown
MAX_RESTARTS=3

# Cooldown window in seconds
COOLDOWN_WINDOW=1800  # 30 minutes

# Watchdog paths
LOG_DIR="/var/log/watchdog"
STATE_DIR="/var/lib/watchdog"
LOG_FILE="$LOG_DIR/decypharr.log"
STATE_FILE="$STATE_DIR/decypharr.state"
LOCK_FILE="$STATE_DIR/decypharr.lock"
CRON_FILE="/etc/cron.d/decypharr-watchdog"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Logging
# ==============================================================================

_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() { _log "INFO" "$1"; }
log_warn() { _log "WARN" "$1"; }
log_error() { _log "ERROR" "$1"; }

# ==============================================================================
# Helper Functions
# ==============================================================================

echo_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
echo_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
echo_success() { echo -e "\033[0;32m[OK]\033[0m $1"; }

# ==============================================================================
# Notifications (shared library)
# ==============================================================================

_notify_log_warn() { log_warn "$1"; }

_notifications_lib="/opt/swizzin-extras/lib/notifications.sh"
[[ -f "$_notifications_lib" ]] || _notifications_lib="${SCRIPT_DIR}/../lib/notifications.sh"
if [[ -f "$_notifications_lib" ]]; then
    . "$_notifications_lib"
    NOTIFY_RATE_DIR="$STATE_DIR"

    # Load notification settings from global watchdog config
    _global_config="/opt/swizzin-extras/watchdog.conf"
    if [[ -f "$_global_config" ]]; then
        # shellcheck source=/dev/null
        source "$_global_config"
    fi
    unset _global_config
else
    # Stub if notifications library not available
    _notify() { :; }
    _should_notify() { return 0; }
fi
unset _notifications_lib

# ==============================================================================
# State Management
# ==============================================================================

_init_state() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        cat >"$STATE_FILE" <<EOF
RESTART_COUNT=0
RESTART_TIMESTAMPS=""
COOLDOWN_UNTIL=""
EOF
    fi
}

_load_state() {
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    RESTART_COUNT="${RESTART_COUNT:-0}"
    RESTART_TIMESTAMPS="${RESTART_TIMESTAMPS:-}"
    COOLDOWN_UNTIL="${COOLDOWN_UNTIL:-}"
}

_save_state() {
    cat >"$STATE_FILE" <<EOF
RESTART_COUNT=$RESTART_COUNT
RESTART_TIMESTAMPS="$RESTART_TIMESTAMPS"
COOLDOWN_UNTIL="$COOLDOWN_UNTIL"
EOF
}

_purge_old_timestamps() {
    local now
    now=$(date +%s)
    local cutoff=$((now - COOLDOWN_WINDOW))
    local new_timestamps=""
    local count=0

    IFS=',' read -ra timestamps <<<"$RESTART_TIMESTAMPS"
    for ts in "${timestamps[@]}"; do
        if [[ -n "$ts" && "$ts" -gt "$cutoff" ]]; then
            if [[ -n "$new_timestamps" ]]; then
                new_timestamps="${new_timestamps},${ts}"
            else
                new_timestamps="$ts"
            fi
            ((count++)) || true
        fi
    done

    RESTART_TIMESTAMPS="$new_timestamps"
    RESTART_COUNT="$count"
}

_add_restart_timestamp() {
    local now
    now=$(date +%s)

    if [[ -n "$RESTART_TIMESTAMPS" ]]; then
        RESTART_TIMESTAMPS="${RESTART_TIMESTAMPS},${now}"
    else
        RESTART_TIMESTAMPS="$now"
    fi

    ((RESTART_COUNT++)) || true
}

# ==============================================================================
# Log-Based Health Check
# ==============================================================================

_count_recent_errors() {
    if [[ ! -f "$LOG_FILE_APP" ]]; then
        echo "0"
        return
    fi

    local now
    now=$(date +%s)
    local cutoff=$((now - CHECK_WINDOW))
    local cutoff_time
    cutoff_time=$(date -d "@$cutoff" '+%Y-%m-%d %H:%M')

    # Count error lines with timestamps within the window
    # Decypharr log format: "2026-04-03 12:23:53 | DEBUG | [qbit] Error adding..."
    local count=0
    while IFS= read -r line; do
        # Extract timestamp from log line
        local log_ts
        log_ts=$(echo "$line" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null) || continue
        [[ -z "$log_ts" ]] && continue

        local log_epoch
        log_epoch=$(date -d "$log_ts" +%s 2>/dev/null) || continue

        if [[ "$log_epoch" -ge "$cutoff" ]]; then
            ((count++)) || true
        fi
    done < <(grep "$ERROR_PATTERN" "$LOG_FILE_APP" 2>/dev/null | tail -100)

    echo "$count"
}

_is_debrid_healthy() {
    # First check if the service is running at all
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_warn "Service $SERVICE_NAME is not running"
        return 1
    fi

    # Count recent debrid errors
    local error_count
    error_count=$(_count_recent_errors)

    if [[ "$error_count" -ge "$ERROR_THRESHOLD" ]]; then
        log_warn "Found $error_count '$ERROR_PATTERN' errors in last $((CHECK_WINDOW / 60)) minutes (threshold: $ERROR_THRESHOLD)"
        return 1
    fi

    return 0
}

# ==============================================================================
# Restart Logic
# ==============================================================================

_restart_service() {
    log_info "Restarting $SERVICE_NAME..."

    if ! systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        log_error "Failed to restart $SERVICE_NAME"
        return 1
    fi

    log_info "Restart command issued, waiting 10 seconds for service to stabilize..."
    sleep 10

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "$SERVICE_NAME restarted successfully and is running"
        return 0
    else
        log_error "$SERVICE_NAME restarted but is not running"
        return 1
    fi
}

# ==============================================================================
# Main Watchdog Logic
# ==============================================================================

_run_watchdog() {
    local now
    now=$(date +%s)

    # Check cooldown
    if [[ -n "$COOLDOWN_UNTIL" && "$now" -lt "$COOLDOWN_UNTIL" ]]; then
        # Check if someone manually restarted the service
        local uptime_secs
        uptime_secs=$(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp --value 2>/dev/null)
        if [[ -n "$uptime_secs" && "$uptime_secs" != "n/a" ]]; then
            local active_epoch
            active_epoch=$(date -d "$uptime_secs" +%s 2>/dev/null) || active_epoch=0
            local svc_uptime=$((now - active_epoch))

            if [[ "$svc_uptime" -lt "$COOLDOWN_WINDOW" && "$svc_uptime" -gt 0 ]]; then
                log_info "Manual restart detected, clearing cooldown state"
                COOLDOWN_UNTIL=""
                RESTART_COUNT=0
                RESTART_TIMESTAMPS=""
                _save_state
                _notify "$APP_NAME Watchdog" "Watchdog resumed after manual restart detected" "info"
            else
                log_info "In cooldown until $(date -d "@$COOLDOWN_UNTIL" '+%Y-%m-%d %H:%M:%S'), skipping"
                return 0
            fi
        else
            log_info "In cooldown until $(date -d "@$COOLDOWN_UNTIL" '+%Y-%m-%d %H:%M:%S'), skipping"
            return 0
        fi
    fi

    # Run health check
    if _is_debrid_healthy; then
        log_info "$APP_NAME debrid connectivity is healthy"
        return 0
    fi

    # Unhealthy — check restart budget
    _purge_old_timestamps
    local window_minutes=$((COOLDOWN_WINDOW / 60))

    if [[ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]]; then
        log_error "Max restarts ($MAX_RESTARTS in ${window_minutes}min) reached, entering cooldown"
        COOLDOWN_UNTIL=$((now + COOLDOWN_WINDOW))
        _save_state
        if _should_notify "$SERVICE_NAME"; then
            _notify "$APP_NAME Watchdog" "Max restarts ($MAX_RESTARTS in ${window_minutes}min) reached. Giving up until manual intervention." "error"
        fi
        return 1
    fi

    # Attempt restart
    local attempt=$((RESTART_COUNT + 1))
    if _should_notify "$SERVICE_NAME"; then
        _notify "$APP_NAME Watchdog" "Debrid connectivity lost, restarting (attempt $attempt/$MAX_RESTARTS)" "warning"
    fi

    if _restart_service; then
        _add_restart_timestamp
        _save_state
        _notify "$APP_NAME Watchdog" "Restarted successfully, debrid connectivity restored" "info"
        return 0
    else
        _add_restart_timestamp
        _save_state
        _notify "$APP_NAME Watchdog" "Restart failed, service did not come up" "error"
        return 1
    fi
}

# ==============================================================================
# Install / Remove / Status / Reset
# ==============================================================================

_install() {
    echo_info "Installing Decypharr watchdog..."

    mkdir -p "$LOG_DIR" "$STATE_DIR"
    chmod 755 "$LOG_DIR"
    chmod 750 "$STATE_DIR"

    cat >"$CRON_FILE" <<EOF
# Decypharr watchdog - checks debrid connectivity every 5 minutes
*/5 * * * * root $(readlink -f "$0") >> $LOG_FILE 2>&1
EOF
    chmod 644 "$CRON_FILE"

    echo_success "Cron job installed: $CRON_FILE"
    echo_info "Watchdog will check Decypharr every 5 minutes"
    echo_info "Logs: $LOG_FILE"
}

_remove() {
    echo_info "Removing Decypharr watchdog..."

    rm -f "$CRON_FILE"
    echo_success "Removed cron job"

    rm -f "$STATE_FILE" "$LOCK_FILE"
    echo_success "Removed state files"
}

_status() {
    echo ""
    echo "Decypharr Watchdog Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Service status
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "Service:     $SERVICE_NAME (\033[0;32mactive\033[0m)"
    else
        echo -e "Service:     $SERVICE_NAME (\033[0;31minactive\033[0m)"
    fi

    # Debrid health
    local error_count
    error_count=$(_count_recent_errors)
    if [[ "$error_count" -lt "$ERROR_THRESHOLD" ]]; then
        echo -e "Debrid:      \033[0;32mhealthy\033[0m ($error_count errors in last $((CHECK_WINDOW / 60))min)"
    else
        echo -e "Debrid:      \033[0;31munhealthy\033[0m ($error_count errors in last $((CHECK_WINDOW / 60))min)"
    fi

    # State info
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        local now
        now=$(date +%s)
        local window_restarts=0

        if [[ -n "${RESTART_TIMESTAMPS:-}" ]]; then
            local cutoff=$((now - COOLDOWN_WINDOW))
            IFS=',' read -ra timestamps <<<"$RESTART_TIMESTAMPS"
            for ts in "${timestamps[@]}"; do
                if [[ -n "$ts" && "$ts" -gt "$cutoff" ]]; then
                    ((window_restarts++)) || true
                fi
            done
        fi

        echo "Restarts:    $window_restarts/$MAX_RESTARTS in current window"

        if [[ -n "${COOLDOWN_UNTIL:-}" && "$now" -lt "${COOLDOWN_UNTIL:-0}" ]]; then
            echo -e "State:       \033[0;31mcooldown until $(date -d "@$COOLDOWN_UNTIL" '+%H:%M:%S')\033[0m"
        else
            echo -e "State:       \033[0;32mmonitoring\033[0m"
        fi
    else
        echo "Restarts:    0/$MAX_RESTARTS in current window"
        echo -e "State:       \033[0;32mmonitoring\033[0m"
    fi

    # Cron status
    if [[ -f "$CRON_FILE" ]]; then
        echo -e "Cron:        \033[0;32menabled\033[0m (every 5 min)"
    else
        echo -e "Cron:        \033[0;31mdisabled\033[0m"
    fi

    echo ""
}

_reset() {
    echo_info "Resetting Decypharr watchdog state..."

    if [[ -f "$STATE_FILE" ]]; then
        cat >"$STATE_FILE" <<EOF
RESTART_COUNT=0
RESTART_TIMESTAMPS=""
COOLDOWN_UNTIL=""
EOF
        echo_success "State reset - watchdog will resume monitoring"
    else
        echo_info "No state file found, nothing to reset"
    fi
}

# ==============================================================================
# Entry Point
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

case "${1:-}" in
    --install)
        _install
        ;;
    --remove)
        _remove
        ;;
    --status)
        _status
        ;;
    --reset)
        _reset
        ;;
    -h | --help)
        echo "Decypharr Watchdog - monitors debrid connectivity"
        echo ""
        echo "Usage: $0 [OPTION]"
        echo ""
        echo "Options:"
        echo "  --install   Install cron job"
        echo "  --remove    Remove cron job"
        echo "  --status    Show watchdog status"
        echo "  --reset     Clear cooldown state"
        echo "  -h, --help  Show this help message"
        echo ""
        echo "Without options, runs the watchdog check (called by cron)."
        ;;
    "")
        # Normal watchdog run (cron mode)
        _init_state

        # Acquire lock
        exec 200>"$LOCK_FILE"
        if ! flock -n 200; then
            echo "Another instance is already running for $SERVICE_NAME"
            exit 0
        fi

        _load_state
        _run_watchdog
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
esac
