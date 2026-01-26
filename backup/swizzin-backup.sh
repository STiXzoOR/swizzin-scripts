#!/bin/bash
# ============================================
# SWIZZIN BACKUP SCRIPT
# ============================================
# Main backup script with dynamic app discovery.
#
# Usage:
#   swizzin-backup.sh <command> [options]
#
# Commands:
#   run             Run backup now
#   run --gdrive    Backup to Google Drive only
#   run --sftp      Backup to SFTP only
#   status          Show backup status
#   list            List available snapshots
#   discover        Show what would be backed up
#   verify          Verify backup integrity
#   stats           Show repository statistics
#   init            Initialize repositories
#   test            Test connectivity

set -euo pipefail

# === CONFIGURATION ===
BACKUP_DIR="/opt/swizzin-extras/backup"
CONFIG_FILE="${BACKUP_DIR}/backup.conf"
REGISTRY_FILE="${BACKUP_DIR}/app-registry.conf"
EXCLUDES_FILE="${BACKUP_DIR}/excludes.conf"
LOCK_DIR="/install"

# === LOAD CONFIG ===
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE" >&2
    echo "Run swizzin-backup-install.sh first" >&2
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

# === LOGGING ===
log() {
    local level="${1:-INFO}"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "${LOG_FILE:-/var/log/swizzin-backup.log}"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# === NOTIFICATIONS ===
send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"

    # Pushover
    if [[ "${PUSHOVER_ENABLED:-no}" == "yes" ]]; then
        curl -s --form-string "token=${PUSHOVER_API_TOKEN}" \
            --form-string "user=${PUSHOVER_USER_KEY}" \
            --form-string "message=${message}" \
            --form-string "title=${title}" \
            --form-string "priority=${priority}" \
            https://api.pushover.net/1/messages.json >/dev/null || true
    fi

    # Discord
    if [[ "${DISCORD_ENABLED:-no}" == "yes" && -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
        local color=3066993  # green
        [[ "$priority" -ge 1 ]] && color=15158332  # red
        local json
        json=$(jq -n --arg title "$title" --arg desc "$message" --argjson color "$color" \
            '{embeds: [{title: $title, description: $desc, color: $color}]}')
        curl -s -H "Content-Type: application/json" -d "$json" \
            "${DISCORD_WEBHOOK_URL}" >/dev/null || true
    fi

    # Notifiarr
    if [[ "${NOTIFIARR_ENABLED:-no}" == "yes" && -n "${NOTIFIARR_API_KEY:-}" ]]; then
        local event_type="success"
        [[ "$priority" -ge 1 ]] && event_type="failure"
        local json
        json=$(jq -n --arg title "$title" --arg msg "$message" --arg evt "$event_type" \
            '{notification: {name: $title, event: $evt}, message: {title: $title, body: $msg}}')
        curl -s -H "x-api-key: ${NOTIFIARR_API_KEY}" \
            -H "Content-Type: application/json" -d "$json" \
            "https://notifiarr.com/api/v1/notification/passthrough" >/dev/null || true
    fi
}

# === UTILITY FUNCTIONS ===
get_swizdb() {
    local key="$1"
    local db_file="/opt/swizzin/db/${key//\//_}"
    if [[ -f "$db_file" ]]; then
        cat "$db_file"
    fi
}

get_users() {
    # Get Swizzin users from htpasswd or fall back to home directories
    if [[ -f /etc/htpasswd ]]; then
        cut -d: -f1 /etc/htpasswd
    else
        ls /home 2>/dev/null | grep -v lost+found || true
    fi
}

get_master_user() {
    # Get the first/primary Swizzin user
    get_users | head -1
}

# === SFTP HELPERS ===
build_sftp_args() {
    SFTP_REPO="sftp:${SFTP_USER}@${SFTP_HOST}:${SFTP_PATH}"
    SFTP_ARGS=(-o "sftp.command=ssh -i ${SFTP_KEY} -p ${SFTP_PORT} ${SFTP_USER}@${SFTP_HOST} -s sftp")
}

# === RETRY HELPER ===
retry() {
    local attempts="${1:-3}" delay="${2:-30}"
    shift 2
    local i
    for ((i=1; i<=attempts; i++)); do
        if "$@"; then return 0; fi
        [[ $i -lt $attempts ]] && { log_warn "Attempt $i/$attempts failed, retrying in ${delay}s..."; sleep "$delay"; }
    done
    return 1
}

# === APP DISCOVERY ===
discover_installed_apps() {
    local apps=()

    for lock_file in "${LOCK_DIR}"/.*.lock; do
        [[ -f "$lock_file" ]] || continue
        local app
        app=$(basename "$lock_file" | sed 's/^\.//; s/\.lock$//')
        apps+=("$app")
    done

    printf '%s\n' "${apps[@]}"
}

get_app_paths() {
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
        local config_paths data_paths excludes app_type
        IFS='|' read -r _ config_paths data_paths excludes app_type <<< "$registry_entry"

        # Handle multi-instance path adjustment
        if [[ -n "$instance" ]]; then
            # Convert sonarr_4k to /home/*/.config/sonarr-4k/
            local instance_path="/home/*/.config/${base_app}-${instance}/"
            paths+=("$instance_path")
        else
            # Expand config paths
            IFS=',' read -ra config_arr <<< "$config_paths"
            for p in "${config_arr[@]}"; do
                p=$(echo "$p" | xargs)  # Trim whitespace
                [[ -n "$p" ]] && paths+=("$p")
            done
        fi

        # Add data paths (shared for multi-instance)
        if [[ -n "$data_paths" && -z "$instance" ]]; then
            IFS=',' read -ra data_arr <<< "$data_paths"
            for p in "${data_arr[@]}"; do
                p=$(echo "$p" | xargs)
                [[ -n "$p" ]] && paths+=("$p")
            done
        fi
    fi

    # Always include systemd and nginx for the app
    if [[ -n "$instance" ]]; then
        paths+=("/etc/systemd/system/${base_app}-${instance}.service")
        paths+=("/etc/nginx/apps/${base_app}-${instance}.conf")
    else
        paths+=("/etc/systemd/system/${app}.service")
        paths+=("/etc/systemd/system/${app}@.service")
        paths+=("/etc/nginx/apps/${app}.conf")
        paths+=("/etc/nginx/sites-available/${app}")
    fi

    printf '%s\n' "${paths[@]}"
}

get_app_excludes() {
    local app="$1"
    local base_app="${app%%_*}"

    local registry_entry
    registry_entry=$(grep "^${base_app}|" "$REGISTRY_FILE" 2>/dev/null | head -1 || true)

    if [[ -n "$registry_entry" ]]; then
        local excludes
        excludes=$(echo "$registry_entry" | cut -d'|' -f4)
        echo "$excludes"
    fi
}

# === DYNAMIC PATH RESOLUTION ===
resolve_dynamic_path() {
    local path_spec="$1"

    case "$path_spec" in
        DYNAMIC:decypharr_downloads)
            for config in /home/*/.config/Decypharr/config.json; do
                if [[ -f "$config" ]]; then
                    jq -r '.downloads_path // .download_path // empty' "$config" 2>/dev/null || true
                fi
            done
            ;;
        DYNAMIC:arr_root_folders)
            # Query all *arr databases for root folders
            for db in /home/*/.config/{Sonarr,Radarr,sonarr-*,radarr-*,Lidarr,Readarr}/*.db; do
                if [[ -f "$db" ]]; then
                    sqlite3 "$db" "SELECT Path FROM RootFolders;" 2>/dev/null || true
                fi
            done
            ;;
        SWIZDB:*)
            local key="${path_spec#SWIZDB:}"
            get_swizdb "$key"
            ;;
        *)
            echo "$path_spec"
            ;;
    esac
}

# === BUILD BACKUP PATHS ===
build_include_file() {
    local include_file="$1"
    local discovered_apps
    discovered_apps=$(discover_installed_apps)

    : > "$include_file"

    # Core paths (always included)
    log_info "Adding core Swizzin paths..."
    grep "^_" "$REGISTRY_FILE" | while IFS='|' read -r app config_paths _ _ _; do
        IFS=',' read -ra paths <<< "$config_paths"
        for p in "${paths[@]}"; do
            p=$(echo "$p" | xargs)
            if [[ "$p" == DYNAMIC:* ]]; then
                resolve_dynamic_path "$p" >> "$include_file"
            elif [[ -n "$p" ]]; then
                echo "$p" >> "$include_file"
            fi
        done
    done

    # App-specific paths
    log_info "Discovering installed apps..."
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue

        # Skip excluded apps
        if [[ " ${EXCLUDE_APPS:-} " == *" $app "* ]]; then
            log_info "Skipping excluded app: $app"
            continue
        fi

        log_info "Adding paths for: $app"
        get_app_paths "$app" >> "$include_file"
    done <<< "$discovered_apps"

    # Dynamic paths (root folders with symlinks, decypharr downloads)
    log_info "Resolving dynamic paths..."

    # Decypharr downloads
    local dl_path
    dl_path=$(resolve_dynamic_path "DYNAMIC:decypharr_downloads")
    if [[ -n "$dl_path" && -d "$dl_path" ]]; then
        echo "$dl_path" >> "$include_file"
    fi

    # *arr root folders (symlinks)
    resolve_dynamic_path "DYNAMIC:arr_root_folders" | while read -r root; do
        if [[ -n "$root" && -d "$root" ]]; then
            echo "$root" >> "$include_file"
        fi
    done

    # Extra user-defined paths
    if [[ -n "${EXTRA_PATHS:-}" ]]; then
        for p in $EXTRA_PATHS; do
            echo "$p" >> "$include_file"
        done
    fi

    # Remove duplicates and non-existent paths, expand globs
    local temp_file
    temp_file=$(mktemp)
    sort -u "$include_file" | while read -r path; do
        [[ -z "$path" ]] && continue
        # Expand globs
        for expanded in $path; do
            if [[ -e "$expanded" ]]; then
                echo "$expanded"
            fi
        done
    done > "$temp_file"
    mv "$temp_file" "$include_file"
}

build_exclude_file() {
    local exclude_file="$1"

    # Start with global excludes
    if [[ -f "$EXCLUDES_FILE" ]]; then
        grep -v '^#' "$EXCLUDES_FILE" | grep -v '^$' > "$exclude_file"
    fi

    # Add app-specific excludes
    local discovered_apps
    discovered_apps=$(discover_installed_apps)

    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        local app_excludes
        app_excludes=$(get_app_excludes "$app")
        if [[ -n "$app_excludes" ]]; then
            IFS=',' read -ra excl_arr <<< "$app_excludes"
            for e in "${excl_arr[@]}"; do
                e=$(echo "$e" | xargs)
                [[ -n "$e" ]] && echo "$e" >> "$exclude_file"
            done
        fi
    done <<< "$discovered_apps"

    sort -u -o "$exclude_file" "$exclude_file"
}

# === MANIFEST GENERATION ===
generate_manifests() {
    local manifest_dir="${MANIFEST_DIR:-${BACKUP_DIR}/manifests}"
    mkdir -p "$manifest_dir"

    local date_stamp
    date_stamp=$(date '+%Y%m%d')

    # Symlink manifest
    log_info "Generating symlink manifest..."
    local symlink_manifest="${manifest_dir}/symlinks-${date_stamp}.json"
    local tmp_roots
    tmp_roots=$(mktemp)

    resolve_dynamic_path "DYNAMIC:arr_root_folders" | sort -u | while read -r root; do
        [[ -z "$root" || ! -d "$root" ]] && continue

        local tmp_links
        tmp_links=$(mktemp)
        find "$root" -type l 2>/dev/null | head -1000 | while read -r link; do
            local target
            target=$(readlink -f "$link" 2>/dev/null || echo "")
            jq -n --arg path "$link" --arg target "$target" '{path: $path, target: $target}'
        done | jq -s '.' > "$tmp_links"

        jq -n --arg root "$root" --slurpfile links "$tmp_links" \
            '{($root): {symlinks: $links[0]}}' >> "$tmp_roots"
        rm -f "$tmp_links"
    done

    # Merge all root folder objects into one JSON document
    if [[ -s "$tmp_roots" ]]; then
        jq -n --arg generated "$(date -Iseconds)" --slurpfile roots "$tmp_roots" \
            '{generated: $generated, root_folders: ($roots | add // {})}' \
            > "$symlink_manifest"
    else
        jq -n --arg generated "$(date -Iseconds)" \
            '{generated: $generated, root_folders: {}}' > "$symlink_manifest"
    fi
    rm -f "$tmp_roots"

    # Swizdb export
    log_info "Exporting swizdb..."
    local swizdb_manifest="${manifest_dir}/swizdb-${date_stamp}.json"
    local tmp_swizdb
    tmp_swizdb=$(mktemp)

    for key_file in /opt/swizzin/db/*; do
        [[ -f "$key_file" ]] || continue
        local key
        key=$(basename "$key_file")
        jq -n --arg key "$key" --rawfile val "$key_file" '{($key): $val}' >> "$tmp_swizdb"
    done

    if [[ -s "$tmp_swizdb" ]]; then
        jq -s 'add // {}' "$tmp_swizdb" > "$swizdb_manifest"
    else
        echo '{}' > "$swizdb_manifest"
    fi
    rm -f "$tmp_swizdb"

    # Paths manifest
    log_info "Generating paths manifest..."
    local paths_manifest="${manifest_dir}/paths-${date_stamp}.json"

    local zurg_mount zurg_version decypharr_mount decypharr_downloads
    zurg_mount=$(get_swizdb "zurg_mount_point" || echo "/mnt/zurg")
    zurg_version=$(get_swizdb "zurg_version" || echo "unknown")
    decypharr_mount=$(get_swizdb "decypharr_mount_path" || echo "/mnt")
    decypharr_downloads=$(resolve_dynamic_path "DYNAMIC:decypharr_downloads" | head -1)

    jq -n \
        --arg generated "$(date -Iseconds)" \
        --arg zurg_mount "$zurg_mount" \
        --arg zurg_version "$zurg_version" \
        --arg decypharr_mount "$decypharr_mount" \
        --arg decypharr_downloads "${decypharr_downloads:-}" \
        '{
            generated: $generated,
            custom_paths: {
                zurg: {mount_point: $zurg_mount, version: $zurg_version},
                decypharr: {mount_path: $decypharr_mount, downloads_path: $decypharr_downloads}
            }
        }' > "$paths_manifest"

    # Cleanup old manifests (older than 7 days)
    find "$manifest_dir" -name "*.json" -mtime +7 -delete 2>/dev/null || true
}

# === BACKUP EXECUTION ===
run_backup() {
    local target="${1:-all}"

    # Concurrent backup protection
    local LOCKFILE="/var/run/swizzin-backup.lock"
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        log_error "Another backup is already running"
        exit 1
    fi

    local start_time
    start_time=$(date +%s)

    log_info "Starting backup (target: $target)"

    # Create temp files for includes/excludes
    local include_file exclude_file
    include_file=$(mktemp)
    exclude_file=$(mktemp)

    trap "rm -f '$include_file' '$exclude_file'" EXIT

    # Build file lists
    build_include_file "$include_file"
    build_exclude_file "$exclude_file"

    local include_count
    include_count=$(wc -l < "$include_file")
    log_info "Backing up $include_count paths"

    # Generate manifests
    generate_manifests

    # Include manifest dir in backup
    echo "${MANIFEST_DIR:-${BACKUP_DIR}/manifests}" >> "$include_file"

    # Run pre-backup hooks
    if [[ -x "${BACKUP_DIR}/hooks/pre-backup.sh" ]]; then
        log_info "Running pre-backup hook..."
        "${BACKUP_DIR}/hooks/pre-backup.sh" || log_warn "Pre-backup hook failed"
    fi

    local backup_failed=false
    local gdrive_status="skipped"
    local sftp_status="skipped"

    # Backup to Google Drive
    if [[ "$target" == "all" || "$target" == "gdrive" ]] && [[ "${GDRIVE_ENABLED:-no}" == "yes" ]]; then
        log_info "Backing up to Google Drive..."
        local gdrive_repo="rclone:${GDRIVE_REMOTE}"

        if retry 3 30 restic -r "$gdrive_repo" backup \
            --files-from "$include_file" \
            --exclude-file "$exclude_file" \
            --tag "swizzin" \
            --tag "$(date +%Y%m%d)" \
            --verbose 2>&1 | tee -a "${LOG_FILE:-/var/log/swizzin-backup.log}"; then
            gdrive_status="success"
            log_info "Google Drive backup completed"

            # Prune old snapshots
            log_info "Pruning Google Drive snapshots..."
            retry 3 30 restic -r "$gdrive_repo" forget \
                --keep-daily "${KEEP_DAILY:-7}" \
                --keep-weekly "${KEEP_WEEKLY:-4}" \
                --keep-monthly "${KEEP_MONTHLY:-3}" \
                --prune || log_warn "Prune failed"
        else
            gdrive_status="failed"
            backup_failed=true
            log_error "Google Drive backup failed"
        fi
    fi

    # Backup to SFTP
    if [[ "$target" == "all" || "$target" == "sftp" ]] && [[ "${SFTP_ENABLED:-no}" == "yes" ]]; then
        log_info "Backing up to SFTP..."
        build_sftp_args

        if retry 3 30 restic -r "$SFTP_REPO" "${SFTP_ARGS[@]}" backup \
            --files-from "$include_file" \
            --exclude-file "$exclude_file" \
            --tag "swizzin" \
            --tag "$(date +%Y%m%d)" \
            --verbose 2>&1 | tee -a "${LOG_FILE:-/var/log/swizzin-backup.log}"; then
            sftp_status="success"
            log_info "SFTP backup completed"

            # Prune old snapshots
            log_info "Pruning SFTP snapshots..."
            retry 3 30 restic -r "$SFTP_REPO" "${SFTP_ARGS[@]}" forget \
                --keep-daily "${KEEP_DAILY:-7}" \
                --keep-weekly "${KEEP_WEEKLY:-4}" \
                --keep-monthly "${KEEP_MONTHLY:-3}" \
                --prune || log_warn "Prune failed"
        else
            sftp_status="failed"
            backup_failed=true
            log_error "SFTP backup failed"
        fi
    fi

    # Run post-backup hooks
    if [[ -x "${BACKUP_DIR}/hooks/post-backup.sh" ]]; then
        log_info "Running post-backup hook..."
        local hook_status="success"
        [[ "$backup_failed" == "true" ]] && hook_status="failure"
        "${BACKUP_DIR}/hooks/post-backup.sh" "$hook_status" || log_warn "Post-backup hook failed"
    fi

    # Calculate duration
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    local duration_human
    duration_human=$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))

    # Send notification
    local notify_title notify_msg notify_priority
    if [[ "$backup_failed" == "true" ]]; then
        notify_title="Swizzin Backup FAILED"
        notify_msg="Backup failed after ${duration_human}\nGDrive: ${gdrive_status}\nSFTP: ${sftp_status}"
        notify_priority="1"
        log_error "Backup completed with errors in ${duration_human}"
    else
        notify_title="Swizzin Backup Complete"
        notify_msg="Backup completed in ${duration_human}\nGDrive: ${gdrive_status}\nSFTP: ${sftp_status}"
        notify_priority="0"
        log_info "Backup completed successfully in ${duration_human}"
    fi

    send_notification "$notify_title" "$notify_msg" "$notify_priority"

    [[ "$backup_failed" == "true" ]] && return 1
    return 0
}

# === COMMANDS ===
cmd_discover() {
    echo "=== Swizzin Backup Discovery ==="
    echo ""

    echo "Installed apps:"
    discover_installed_apps | while read -r app; do
        echo "  - $app"
    done
    echo ""

    echo "Building path list..."
    local include_file
    include_file=$(mktemp)
    trap "rm -f '$include_file'" EXIT

    build_include_file "$include_file"

    echo ""
    echo "Paths to backup:"
    cat "$include_file" | while read -r path; do
        local size
        size=$(du -sh "$path" 2>/dev/null | cut -f1 || echo "?")
        echo "  [$size] $path"
    done

    echo ""
    local total_size
    total_size=$(cat "$include_file" | xargs du -sc 2>/dev/null | tail -1 | cut -f1 || echo "unknown")
    echo "Estimated total size: $(numfmt --to=iec "$total_size" 2>/dev/null || echo "$total_size bytes")"
}

cmd_status() {
    echo "=== Swizzin Backup Status ==="
    echo ""

    echo "Configuration:"
    echo "  Google Drive: ${GDRIVE_ENABLED:-no}"
    echo "  SFTP: ${SFTP_ENABLED:-no}"
    echo "  Pushover: ${PUSHOVER_ENABLED:-no}"
    echo "  Schedule: ${BACKUP_HOUR:-03}:${BACKUP_MINUTE:-00} daily"
    echo ""

    if [[ "${GDRIVE_ENABLED:-no}" == "yes" ]]; then
        echo "Google Drive latest snapshot:"
        restic -r "rclone:${GDRIVE_REMOTE}" snapshots --latest 1 2>/dev/null || echo "  (none or error)"
        echo ""
    fi

    if [[ "${SFTP_ENABLED:-no}" == "yes" ]]; then
        echo "SFTP latest snapshot:"
        build_sftp_args
        restic -r "$SFTP_REPO" "${SFTP_ARGS[@]}" snapshots --latest 1 2>/dev/null || echo "  (none or error)"
    fi
}

cmd_list() {
    local target="${1:-all}"

    if [[ "$target" == "all" || "$target" == "gdrive" ]] && [[ "${GDRIVE_ENABLED:-no}" == "yes" ]]; then
        echo "=== Google Drive Snapshots ==="
        restic -r "rclone:${GDRIVE_REMOTE}" snapshots 2>/dev/null || echo "Error listing snapshots"
        echo ""
    fi

    if [[ "$target" == "all" || "$target" == "sftp" ]] && [[ "${SFTP_ENABLED:-no}" == "yes" ]]; then
        echo "=== SFTP Snapshots ==="
        build_sftp_args
        restic -r "$SFTP_REPO" "${SFTP_ARGS[@]}" snapshots 2>/dev/null || echo "Error listing snapshots"
    fi
}

cmd_verify() {
    echo "=== Verifying Backup Integrity ==="

    if [[ "${GDRIVE_ENABLED:-no}" == "yes" ]]; then
        echo "Checking Google Drive repository..."
        restic -r "rclone:${GDRIVE_REMOTE}" check 2>&1 || echo "Verification failed"
        echo ""
    fi

    if [[ "${SFTP_ENABLED:-no}" == "yes" ]]; then
        echo "Checking SFTP repository..."
        build_sftp_args
        restic -r "$SFTP_REPO" "${SFTP_ARGS[@]}" check 2>&1 || echo "Verification failed"
    fi
}

cmd_stats() {
    echo "=== Repository Statistics ==="

    if [[ "${GDRIVE_ENABLED:-no}" == "yes" ]]; then
        echo "Google Drive:"
        restic -r "rclone:${GDRIVE_REMOTE}" stats 2>/dev/null || echo "Error getting stats"
        echo ""
    fi

    if [[ "${SFTP_ENABLED:-no}" == "yes" ]]; then
        echo "SFTP:"
        build_sftp_args
        restic -r "$SFTP_REPO" "${SFTP_ARGS[@]}" stats 2>/dev/null || echo "Error getting stats"
    fi
}

cmd_init() {
    echo "=== Initializing Repositories ==="

    if [[ "${GDRIVE_ENABLED:-no}" == "yes" ]]; then
        echo "Initializing Google Drive repository..."
        restic -r "rclone:${GDRIVE_REMOTE}" init 2>&1 || echo "Already initialized or error"
        echo ""
    fi

    if [[ "${SFTP_ENABLED:-no}" == "yes" ]]; then
        echo "Initializing SFTP repository..."
        build_sftp_args
        restic -r "$SFTP_REPO" "${SFTP_ARGS[@]}" init 2>&1 || echo "Already initialized or error"
    fi
}

cmd_test() {
    echo "=== Testing Connectivity ==="

    if [[ "${GDRIVE_ENABLED:-no}" == "yes" ]]; then
        echo -n "Google Drive: "
        if restic -r "rclone:${GDRIVE_REMOTE}" snapshots &>/dev/null; then
            echo "OK"
        else
            echo "FAILED"
        fi
    fi

    if [[ "${SFTP_ENABLED:-no}" == "yes" ]]; then
        echo -n "SFTP: "
        if ssh -i "${SFTP_KEY}" -o BatchMode=yes -o ConnectTimeout=5 -p "${SFTP_PORT}" "${SFTP_USER}@${SFTP_HOST}" "echo ok" &>/dev/null; then
            echo "OK"
        else
            echo "FAILED"
        fi
    fi

    if [[ "${PUSHOVER_ENABLED:-no}" == "yes" ]]; then
        echo -n "Pushover: "
        local response
        response=$(curl -s --form-string "token=${PUSHOVER_API_TOKEN}" \
            --form-string "user=${PUSHOVER_USER_KEY}" \
            --form-string "message=Connectivity test" \
            --form-string "title=Swizzin Backup Test" \
            https://api.pushover.net/1/messages.json)
        if echo "$response" | grep -q '"status":1'; then
            echo "OK"
        else
            echo "FAILED"
        fi
    fi

    if [[ "${DISCORD_ENABLED:-no}" == "yes" ]]; then
        echo -n "Discord: "
        local json
        json=$(jq -n '{embeds: [{title: "Swizzin Backup Test", description: "Connectivity test", color: 3066993}]}')
        if curl -sf -H "Content-Type: application/json" -d "$json" \
            "${DISCORD_WEBHOOK_URL}" >/dev/null; then
            echo "OK"
        else
            echo "FAILED"
        fi
    fi

    if [[ "${NOTIFIARR_ENABLED:-no}" == "yes" ]]; then
        echo -n "Notifiarr: "
        local json
        json=$(jq -n '{notification: {name: "Swizzin Backup Test", event: "test"}, message: {title: "Swizzin Backup Test", body: "Connectivity test"}}')
        if curl -sf -H "x-api-key: ${NOTIFIARR_API_KEY}" \
            -H "Content-Type: application/json" -d "$json" \
            "https://notifiarr.com/api/v1/notification/passthrough" >/dev/null; then
            echo "OK"
        else
            echo "FAILED"
        fi
    fi
}

# === MAIN ===
usage() {
    cat << EOF
swizzin-backup.sh - Swizzin Backup Manager

USAGE:
    swizzin-backup.sh <command> [options]

COMMANDS:
    run             Run backup now (both destinations)
    run --gdrive    Run backup to Google Drive only
    run --sftp      Run backup to SFTP only

    status          Show backup status and last run info
    list            List available snapshots
    list --gdrive   List Google Drive snapshots only
    list --sftp     List SFTP snapshots only

    verify          Verify backup integrity
    stats           Show repository statistics
    init            Initialize restic repositories
    test            Test connectivity to destinations
    discover        Show what would be backed up (dry run)

EXAMPLES:
    swizzin-backup.sh run
    swizzin-backup.sh list
    swizzin-backup.sh discover
EOF
}

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        run)
            local target="all"
            [[ "${1:-}" == "--gdrive" ]] && target="gdrive"
            [[ "${1:-}" == "--sftp" ]] && target="sftp"
            run_backup "$target"
            ;;
        status)
            cmd_status
            ;;
        list)
            local target="all"
            [[ "${1:-}" == "--gdrive" ]] && target="gdrive"
            [[ "${1:-}" == "--sftp" ]] && target="sftp"
            cmd_list "$target"
            ;;
        verify)
            cmd_verify
            ;;
        stats)
            cmd_stats
            ;;
        init)
            cmd_init
            ;;
        test)
            cmd_test
            ;;
        discover)
            cmd_discover
            ;;
        help|--help|-h)
            usage
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            echo "Unknown command: $cmd" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
