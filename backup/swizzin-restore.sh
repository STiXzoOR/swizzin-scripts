#!/bin/bash
# ============================================
# SWIZZIN RESTORE SCRIPT
# ============================================
# Restore from Swizzin backups.
#
# Usage:
#   swizzin-restore.sh [options]
#
# Options:
#   --source <gdrive|sftp>    Backup source
#   --snapshot <id|latest>    Snapshot to restore
#   --app <name>              Restore single app only
#   --config-only             Restore configs, skip databases
#   --dry-run                 Show what would be restored
#   --target <path>           Restore to alternate path

set -euo pipefail

# === CONFIGURATION ===
BACKUP_DIR="/opt/swizzin-extras/backup"
CONFIG_FILE="${BACKUP_DIR}/backup.conf"
REGISTRY_FILE="${BACKUP_DIR}/app-registry.conf"

# === LOAD CONFIG ===
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

# Set restic password
if [[ -n "${RESTIC_PASSWORD_FILE:-}" && -f "$RESTIC_PASSWORD_FILE" ]]; then
    export RESTIC_PASSWORD_FILE
elif [[ -n "${RESTIC_PASSWORD:-}" ]]; then
    export RESTIC_PASSWORD
else
    echo "Error: No restic password configured" >&2
    exit 1
fi

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# === UTILITIES ===
log() {
    echo -e "${GREEN}[+]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

error() {
    echo -e "${RED}[x]${NC} $*" >&2
}

info() {
    echo -e "${BLUE}[i]${NC} $*"
}

header() {
    echo ""
    echo -e "${CYAN}${BOLD}=== $* ===${NC}"
    echo ""
}

ask() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer

    if [[ "$default" == "Y" ]]; then
        read -rp "$(echo -e "${CYAN}$prompt [Y/n]:${NC} ")" answer
        [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
    else
        read -rp "$(echo -e "${CYAN}$prompt [y/N]:${NC} ")" answer
        [[ "$answer" =~ ^[Yy] ]]
    fi
}

prompt() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${CYAN}$prompt [$default]:${NC} ")" answer
        echo "${answer:-$default}"
    else
        read -rp "$(echo -e "${CYAN}$prompt:${NC} ")" answer
        echo "$answer"
    fi
}

get_repo() {
    local source="$1"

    case "$source" in
        gdrive)
            echo "rclone:${GDRIVE_REMOTE}"
            ;;
        sftp)
            echo "sftp:${SFTP_USER}@${SFTP_HOST}:${SFTP_PATH}"
            ;;
        *)
            error "Unknown source: $source"
            return 1
            ;;
    esac
}

get_restic_opts() {
    local source="$1"

    case "$source" in
        sftp)
            echo "-o sftp.command=ssh -i ${SFTP_KEY} -p ${SFTP_PORT} ${SFTP_USER}@${SFTP_HOST} -s sftp"
            ;;
        *)
            echo ""
            ;;
    esac
}

# === SNAPSHOT FUNCTIONS ===
list_snapshots() {
    local source="$1"
    local repo
    repo=$(get_repo "$source")
    local opts
    opts=$(get_restic_opts "$source")

    restic -r "$repo" $opts snapshots --json 2>/dev/null
}

get_latest_snapshot() {
    local source="$1"
    local repo
    repo=$(get_repo "$source")
    local opts
    opts=$(get_restic_opts "$source")

    restic -r "$repo" $opts snapshots --latest 1 --json 2>/dev/null | jq -r '.[0].id // empty'
}

# === APP PATH FUNCTIONS ===
get_app_paths_for_restore() {
    local app="$1"
    local paths=()

    # Check if it's a multi-instance app
    local base_app="$app"
    local instance=""
    if [[ "$app" == *_* ]]; then
        base_app="${app%%_*}"
        instance="${app#*_}"
    fi

    # Look up in registry
    local registry_entry
    registry_entry=$(grep "^${base_app}|" "$REGISTRY_FILE" 2>/dev/null | head -1 || true)

    if [[ -n "$registry_entry" ]]; then
        local config_paths data_paths
        IFS='|' read -r _ config_paths data_paths _ _ <<< "$registry_entry"

        # Handle multi-instance path adjustment
        if [[ -n "$instance" ]]; then
            paths+=("/home/*/.config/${base_app}-${instance}/")
        else
            IFS=',' read -ra config_arr <<< "$config_paths"
            for p in "${config_arr[@]}"; do
                p=$(echo "$p" | xargs)
                [[ -n "$p" && "$p" != DYNAMIC:* ]] && paths+=("$p")
            done
        fi

        # Add data paths
        if [[ -n "$data_paths" && -z "$instance" ]]; then
            IFS=',' read -ra data_arr <<< "$data_paths"
            for p in "${data_arr[@]}"; do
                p=$(echo "$p" | xargs)
                [[ -n "$p" ]] && paths+=("$p")
            done
        fi
    fi

    # Add systemd and nginx
    if [[ -n "$instance" ]]; then
        paths+=("/etc/systemd/system/${base_app}-${instance}.service")
        paths+=("/etc/nginx/apps/${base_app}-${instance}.conf")
    else
        paths+=("/etc/systemd/system/${app}.service")
        paths+=("/etc/nginx/apps/${app}.conf")
        paths+=("/etc/nginx/sites-available/${app}")
    fi

    printf '%s\n' "${paths[@]}"
}

# === PERMISSION FIXING ===
fix_permissions() {
    header "Fixing Permissions"

    # Get Swizzin users
    local users
    if [[ -f /etc/htpasswd ]]; then
        users=$(cut -d: -f1 /etc/htpasswd)
    else
        users=$(ls /home 2>/dev/null | grep -v lost+found || true)
    fi

    # Fix user config directories
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        log "Fixing permissions for user: $user"

        if [[ -d "/home/$user/.config" ]]; then
            chown -R "${user}:${user}" "/home/$user/.config/" 2>/dev/null || true
        fi

        if [[ -d "/home/$user/.ssl" ]]; then
            chown -R "${user}:${user}" "/home/$user/.ssl/" 2>/dev/null || true
            chmod 600 "/home/$user/.ssl/"* 2>/dev/null || true
        fi
    done <<< "$users"

    # Fix media server directories
    if [[ -d /var/lib/plexmediaserver ]]; then
        log "Fixing Plex permissions"
        chown -R plex:plex /var/lib/plexmediaserver/ 2>/dev/null || true
    fi

    if [[ -d /var/lib/emby ]]; then
        log "Fixing Emby permissions"
        chown -R emby:emby /var/lib/emby/ 2>/dev/null || true
    fi

    if [[ -d /var/lib/jellyfin ]]; then
        log "Fixing Jellyfin permissions"
        chown -R jellyfin:jellyfin /var/lib/jellyfin/ 2>/dev/null || true
    fi

    # Fix nginx ssl
    if [[ -d /etc/nginx/ssl ]]; then
        chmod -R 600 /etc/nginx/ssl/ 2>/dev/null || true
        chmod 700 /etc/nginx/ssl/ 2>/dev/null || true
    fi

    # Fix swizzin directories
    chown -R root:root /opt/swizzin/ 2>/dev/null || true
}

# === SERVICE MANAGEMENT ===
get_all_services() {
    # Get all Swizzin-managed services
    local services=()

    for lock in /install/.*.lock; do
        [[ -f "$lock" ]] || continue
        local app
        app=$(basename "$lock" | sed 's/^\.//; s/\.lock$//')

        # Check if service exists
        if systemctl list-unit-files "${app}.service" &>/dev/null; then
            services+=("$app")
        fi

        # Check for multi-instance
        local base_app="${app%%_*}"
        local instance="${app#*_}"
        if [[ "$base_app" != "$instance" ]]; then
            local svc_name="${base_app}-${instance}"
            if systemctl list-unit-files "${svc_name}.service" &>/dev/null; then
                services+=("$svc_name")
            fi
        fi
    done

    printf '%s\n' "${services[@]}" | sort -u
}

stop_services() {
    header "Stopping Services"

    local services
    services=$(get_all_services)

    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "Stopping $svc"
            systemctl stop "$svc" || warn "Failed to stop $svc"
        fi
    done <<< "$services"

    # Stop nginx
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log "Stopping nginx"
        systemctl stop nginx || true
    fi
}

start_services() {
    header "Starting Services"

    # Reload systemd
    log "Reloading systemd"
    systemctl daemon-reload

    # Start nginx first
    if [[ -f /etc/nginx/nginx.conf ]]; then
        log "Starting nginx"
        systemctl start nginx || warn "Failed to start nginx"
    fi

    local services
    services=$(get_all_services)

    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        log "Starting $svc"
        systemctl start "$svc" || warn "Failed to start $svc"
    done <<< "$services"
}

# === RESTORE FUNCTIONS ===
restore_full() {
    local source="$1"
    local snapshot="$2"
    local dry_run="${3:-false}"
    local target="${4:-/}"

    header "Full Restore"

    local repo
    repo=$(get_repo "$source")
    local opts
    opts=$(get_restic_opts "$source")

    info "Source: $source"
    info "Snapshot: $snapshot"
    info "Target: $target"
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        log "Dry run - showing what would be restored:"
        restic -r "$repo" $opts ls "$snapshot" 2>/dev/null | head -100
        echo "... (truncated)"
        return 0
    fi

    if ! ask "This will restore ALL files to $target. Continue?" N; then
        echo "Cancelled"
        return 1
    fi

    # Stop services
    if [[ "$target" == "/" ]]; then
        stop_services
    fi

    # Restore
    log "Restoring files..."
    if restic -r "$repo" $opts restore "$snapshot" --target "$target" --verbose; then
        log "Restore completed"
    else
        error "Restore failed"
        return 1
    fi

    # Fix permissions
    if [[ "$target" == "/" ]]; then
        fix_permissions
        start_services
    fi

    log "Full restore completed!"
}

restore_app() {
    local source="$1"
    local snapshot="$2"
    local app="$3"
    local dry_run="${4:-false}"
    local target="${5:-/}"

    header "App Restore: $app"

    local repo
    repo=$(get_repo "$source")
    local opts
    opts=$(get_restic_opts "$source")

    # Get app paths
    local paths
    paths=$(get_app_paths_for_restore "$app")

    if [[ -z "$paths" ]]; then
        error "No paths found for app: $app"
        return 1
    fi

    info "Paths to restore:"
    echo "$paths" | while read -r p; do
        [[ -n "$p" ]] && echo "  - $p"
    done
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        log "Dry run - would restore above paths"
        return 0
    fi

    if ! ask "Restore $app?" Y; then
        echo "Cancelled"
        return 1
    fi

    # Stop specific service
    local base_app="${app%%_*}"
    local instance="${app#*_}"
    local svc_name="$app"
    [[ "$base_app" != "$instance" ]] && svc_name="${base_app}-${instance}"

    if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
        log "Stopping $svc_name"
        systemctl stop "$svc_name" || true
    fi

    # Build include args
    local include_args=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && include_args+=(--include "$p")
    done <<< "$paths"

    # Restore
    log "Restoring $app..."
    if restic -r "$repo" $opts restore "$snapshot" --target "$target" "${include_args[@]}" --verbose; then
        log "Restore completed"
    else
        error "Restore failed"
        return 1
    fi

    # Fix permissions and restart
    fix_permissions

    log "Reloading systemd"
    systemctl daemon-reload

    log "Starting $svc_name"
    systemctl start "$svc_name" || warn "Failed to start $svc_name"

    # Reload nginx if needed
    systemctl reload nginx 2>/dev/null || true

    log "App restore completed!"
}

restore_configs_only() {
    local source="$1"
    local snapshot="$2"
    local dry_run="${3:-false}"
    local target="${4:-/}"

    header "Config-Only Restore"

    local repo
    repo=$(get_repo "$source")
    local opts
    opts=$(get_restic_opts "$source")

    # Config patterns (exclude databases)
    local include_patterns=(
        "/etc/nginx/**"
        "/etc/systemd/system/*.service"
        "/etc/cron.d/**"
        "/opt/swizzin/**"
        "/etc/swizzin/**"
        "/etc/letsencrypt/**"
        "/etc/hosts"
        "/etc/fuse.conf"
    )

    local exclude_patterns=(
        "*.db"
        "*.db-shm"
        "*.db-wal"
        "*.sqlite"
        "*.sqlite3"
    )

    if [[ "$dry_run" == "true" ]]; then
        log "Dry run - would restore config files only"
        return 0
    fi

    if ! ask "Restore configs only (excluding databases)?" Y; then
        echo "Cancelled"
        return 1
    fi

    # Build args
    local include_args=()
    for p in "${include_patterns[@]}"; do
        include_args+=(--include "$p")
    done

    local exclude_args=()
    for p in "${exclude_patterns[@]}"; do
        exclude_args+=(--exclude "$p")
    done

    # Stop services
    if [[ "$target" == "/" ]]; then
        stop_services
    fi

    # Restore
    log "Restoring config files..."
    if restic -r "$repo" $opts restore "$snapshot" --target "$target" "${include_args[@]}" "${exclude_args[@]}" --verbose; then
        log "Restore completed"
    else
        error "Restore failed"
        return 1
    fi

    # Fix permissions
    if [[ "$target" == "/" ]]; then
        fix_permissions
        start_services
    fi

    log "Config restore completed!"
}

browse_files() {
    local source="$1"
    local snapshot="$2"

    header "Browse Backup Files"

    local repo
    repo=$(get_repo "$source")
    local opts
    opts=$(get_restic_opts "$source")

    log "Listing files in snapshot $snapshot..."
    echo ""
    echo "Use arrow keys to scroll, 'q' to quit"
    echo ""

    restic -r "$repo" $opts ls "$snapshot" 2>/dev/null | less
}

# === INTERACTIVE MODE ===
interactive_mode() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║         SWIZZIN RESTORE WIZARD            ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"

    # Select source
    header "Select Backup Source"

    local sources=()
    [[ "${GDRIVE_ENABLED:-no}" == "yes" ]] && sources+=("gdrive")
    [[ "${SFTP_ENABLED:-no}" == "yes" ]] && sources+=("sftp")

    if [[ ${#sources[@]} -eq 0 ]]; then
        error "No backup destinations configured"
        exit 1
    fi

    local source
    if [[ ${#sources[@]} -eq 1 ]]; then
        source="${sources[0]}"
        info "Using source: $source"
    else
        echo "Available sources:"
        local i=1
        for s in "${sources[@]}"; do
            echo "  $i) $s"
            ((i++))
        done
        echo ""
        local choice
        choice=$(prompt "Select source" "1")
        source="${sources[$((choice-1))]}"
    fi

    # List snapshots
    header "Select Snapshot"

    local repo
    repo=$(get_repo "$source")
    local opts
    opts=$(get_restic_opts "$source")

    log "Fetching snapshots from $source..."
    restic -r "$repo" $opts snapshots 2>/dev/null || {
        error "Failed to list snapshots"
        exit 1
    }

    echo ""
    local snapshot
    snapshot=$(prompt "Snapshot ID (or 'latest')" "latest")

    if [[ "$snapshot" == "latest" ]]; then
        snapshot=$(get_latest_snapshot "$source")
        if [[ -z "$snapshot" ]]; then
            error "No snapshots found"
            exit 1
        fi
        info "Using latest snapshot: $snapshot"
    fi

    # Select restore mode
    header "Select Restore Mode"

    echo "  1) Full restore - Restore everything"
    echo "  2) App restore - Restore single app"
    echo "  3) Config restore - Configs only, preserve databases"
    echo "  4) Browse files - View backup contents"
    echo "  5) Cancel"
    echo ""

    local mode
    mode=$(prompt "Selection" "1")

    case "$mode" in
        1)
            restore_full "$source" "$snapshot"
            ;;
        2)
            echo ""
            echo "Installed apps:"
            for lock in /install/.*.lock; do
                [[ -f "$lock" ]] || continue
                local app
                app=$(basename "$lock" | sed 's/^\.//; s/\.lock$//')
                echo "  - $app"
            done
            echo ""
            local app
            app=$(prompt "App name")
            restore_app "$source" "$snapshot" "$app"
            ;;
        3)
            restore_configs_only "$source" "$snapshot"
            ;;
        4)
            browse_files "$source" "$snapshot"
            ;;
        5)
            echo "Cancelled"
            exit 0
            ;;
        *)
            error "Invalid selection"
            exit 1
            ;;
    esac
}

# === MAIN ===
usage() {
    cat << EOF
swizzin-restore.sh - Swizzin Restore Manager

USAGE:
    swizzin-restore.sh [options]

OPTIONS:
    --source <gdrive|sftp>    Backup source (default: interactive)
    --snapshot <id|latest>    Snapshot to restore (default: interactive)
    --app <name>              Restore single app only
    --config-only             Restore configs, skip databases
    --dry-run                 Show what would be restored
    --target <path>           Restore to alternate path

MODES:
    (no options)              Interactive mode
    --app <name>              App-specific restore
    --config-only             Config files only

EXAMPLES:
    swizzin-restore.sh
    swizzin-restore.sh --source gdrive --app sonarr
    swizzin-restore.sh --snapshot latest --dry-run
    swizzin-restore.sh --source sftp --snapshot abc123 --target /tmp/restore
EOF
}

main() {
    # Parse arguments
    local source=""
    local snapshot=""
    local app=""
    local config_only=false
    local dry_run=false
    local target="/"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                source="$2"
                shift 2
                ;;
            --snapshot)
                snapshot="$2"
                shift 2
                ;;
            --app)
                app="$2"
                shift 2
                ;;
            --config-only)
                config_only=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --target)
                target="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # If no arguments, run interactive mode
    if [[ -z "$source" && -z "$snapshot" && -z "$app" && "$config_only" == "false" ]]; then
        interactive_mode
        exit 0
    fi

    # Validate required arguments
    if [[ -z "$source" ]]; then
        # Default to first available
        [[ "${GDRIVE_ENABLED:-no}" == "yes" ]] && source="gdrive"
        [[ -z "$source" && "${SFTP_ENABLED:-no}" == "yes" ]] && source="sftp"

        if [[ -z "$source" ]]; then
            error "No backup source available"
            exit 1
        fi
        info "Using source: $source"
    fi

    if [[ -z "$snapshot" ]]; then
        snapshot="latest"
    fi

    if [[ "$snapshot" == "latest" ]]; then
        snapshot=$(get_latest_snapshot "$source")
        if [[ -z "$snapshot" ]]; then
            error "No snapshots found"
            exit 1
        fi
        info "Using latest snapshot: $snapshot"
    fi

    # Execute restore
    if [[ -n "$app" ]]; then
        restore_app "$source" "$snapshot" "$app" "$dry_run" "$target"
    elif [[ "$config_only" == "true" ]]; then
        restore_configs_only "$source" "$snapshot" "$dry_run" "$target"
    else
        restore_full "$source" "$snapshot" "$dry_run" "$target"
    fi
}

main "$@"
