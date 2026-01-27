#!/bin/bash
#
# Arr Symlink Import Script
#
# Use this with Sonarr/Radarr's "Import Using Script" feature in Media Management.
# Instead of moving/copying files, creates symlinks to the zurg mount.
#
# This prevents "Permission denied" errors caused by FUSE mount transient
# unavailability when Sonarr/Radarr tries to move/copy files through symlinks.
#
# Setup:
#   1. Deploy with: bash arr-symlink-import-setup.sh --install
#      Or manually copy to: /opt/swizzin-extras/arr-symlink-import.sh
#   2. Make it executable: chmod +x /opt/swizzin-extras/arr-symlink-import.sh
#   3. In Sonarr/Radarr: Settings > Media Management > Importing
#   4. Enable "Use Script Import"
#   5. Set Script Path to: /opt/swizzin-extras/arr-symlink-import.sh
#   6. Disable Recycle Bin (Settings > Media Management > File Management)
#
# Sonarr/Radarr call this script with:
#   Positional args: $1 = source path, $2 = destination path
#   Environment vars: Sonarr_SourcePath / Radarr_SourcePath (PascalCase)
#
# The script communicates back via stdout:
#   [MoveStatus]MoveComplete  - signals that the file transfer is handled
#

# ==============================================================================
# Configuration
# ==============================================================================

# Load optional config file
CONF_FILE="/opt/swizzin-extras/arr-symlink-import.conf"
if [[ -f "$CONF_FILE" ]]; then
	# shellcheck source=/dev/null
	. "$CONF_FILE"
fi

# Mount health check settings (can be overridden via config)
MOUNT_CHECK_RETRIES="${MOUNT_CHECK_RETRIES:-5}"
MOUNT_CHECK_DELAY="${MOUNT_CHECK_DELAY:-3}"
MOUNT_CHECK_TIMEOUT="${MOUNT_CHECK_TIMEOUT:-5}"

# Log settings
LOG_FILE="${ARR_IMPORT_LOG:-/var/log/arr-symlink-import.log}"
LOG_MAX_SIZE="${ARR_IMPORT_LOG_MAX_SIZE:-10485760}" # 10MB default

# ==============================================================================
# Auto-detect Zurg mount base path
# ==============================================================================

_detect_zurg_base() {
	# Priority 1: Environment variable (from config or caller)
	if [[ -n "${ARR_ZURG_BASE:-}" ]]; then
		echo "$ARR_ZURG_BASE"
		return 0
	fi

	# Priority 2: swizdb (set by zurg.sh installer)
	if command -v swizdb &>/dev/null; then
		local swizdb_mount
		swizdb_mount=$(swizdb get "zurg/mount_point" 2>/dev/null) || true
		if [[ -n "$swizdb_mount" ]]; then
			echo "$swizdb_mount"
			return 0
		fi
	fi

	# Priority 3: Decypharr config.json (parses realdebrid folder path)
	local decypharr_config
	for decypharr_config in /home/*/.config/Decypharr/config.json; do
		if [[ -f "$decypharr_config" ]]; then
			if command -v jq &>/dev/null; then
				local folder
				folder=$(jq -r '.debrids[]? | select(.name == "realdebrid") | .folder // empty' "$decypharr_config" 2>/dev/null) || true
				if [[ -n "$folder" ]]; then
					# Strip trailing /__all__/ to get mount base
					local base="${folder%/__all__/}"
					base="${base%/__all__}"
					if [[ -n "$base" ]]; then
						echo "$base"
						return 0
					fi
				fi
			fi
		fi
	done

	# Priority 4: Default
	echo "/mnt/zurg"
	return 0
}

ZURG_BASE="$(_detect_zurg_base)"

# ==============================================================================
# Logging
# ==============================================================================

_rotate_log() {
	if [[ -f "$LOG_FILE" ]]; then
		local size
		size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
		if [[ "$size" -gt "$LOG_MAX_SIZE" ]]; then
			mv "$LOG_FILE" "${LOG_FILE}.1"
		fi
	fi
}

log() {
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	# Ensure log directory exists
	local log_dir
	log_dir=$(dirname "$LOG_FILE")
	if [[ ! -d "$log_dir" ]]; then
		mkdir -p "$log_dir" 2>/dev/null || true
	fi

	echo "[$timestamp] $*" >>"$LOG_FILE"
}

# Rotate on each invocation
_rotate_log

# ==============================================================================
# Mount health check
# ==============================================================================

_check_mount() {
	local mount_path="$1"
	local attempt

	for ((attempt = 1; attempt <= MOUNT_CHECK_RETRIES; attempt++)); do
		# Check if mount point exists
		if [[ ! -d "$mount_path" ]]; then
			log "WARN: Mount path does not exist: $mount_path (attempt $attempt/$MOUNT_CHECK_RETRIES)"
			if [[ "$attempt" -lt "$MOUNT_CHECK_RETRIES" ]]; then
				sleep "$MOUNT_CHECK_DELAY"
				continue
			fi
			return 1
		fi

		# Check if it's actually a mount point
		if ! mountpoint -q "$mount_path" 2>/dev/null; then
			log "WARN: Not a mount point: $mount_path (attempt $attempt/$MOUNT_CHECK_RETRIES)"
			if [[ "$attempt" -lt "$MOUNT_CHECK_RETRIES" ]]; then
				sleep "$MOUNT_CHECK_DELAY"
				continue
			fi
			return 1
		fi

		# Check if mount is responsive (ls with timeout)
		if timeout "$MOUNT_CHECK_TIMEOUT" ls "$mount_path" &>/dev/null; then
			if [[ "$attempt" -gt 1 ]]; then
				log "INFO: Mount recovered after $attempt attempts"
			fi
			return 0
		fi

		log "WARN: Mount not responding: $mount_path (attempt $attempt/$MOUNT_CHECK_RETRIES)"
		if [[ "$attempt" -lt "$MOUNT_CHECK_RETRIES" ]]; then
			sleep "$MOUNT_CHECK_DELAY"
		fi
	done

	log "ERROR: Mount health check failed after $MOUNT_CHECK_RETRIES attempts: $mount_path"
	return 1
}

# ==============================================================================
# Detect calling app and resolve source/destination paths
#
# Sonarr/Radarr pass paths two ways:
#   1. Positional args: $1 = source, $2 = destination
#   2. Environment vars: Sonarr_SourcePath / Radarr_SourcePath (PascalCase)
#
# We prefer positional args (most reliable), fall back to env vars.
# ==============================================================================

APP=""
SOURCE_PATH=""
DEST_PATH=""

# Method 1: Positional arguments (always passed by Sonarr/Radarr)
if [[ -n "${1:-}" ]] && [[ -n "${2:-}" ]]; then
	SOURCE_PATH="$1"
	DEST_PATH="$2"
	# Determine which app from env vars (for logging only)
	if [[ -n "${Sonarr_SourcePath:-}" ]]; then
		APP="Sonarr"
	elif [[ -n "${Radarr_SourcePath:-}" ]]; then
		APP="Radarr"
	else
		APP="Unknown"
	fi
# Method 2: Environment variables (PascalCase - actual Sonarr/Radarr casing)
elif [[ -n "${Sonarr_SourcePath:-}" ]]; then
	SOURCE_PATH="$Sonarr_SourcePath"
	DEST_PATH="$Sonarr_DestinationPath"
	APP="Sonarr"
elif [[ -n "${Radarr_SourcePath:-}" ]]; then
	SOURCE_PATH="$Radarr_SourcePath"
	DEST_PATH="$Radarr_DestinationPath"
	APP="Radarr"
else
	log "ERROR: No source path provided. Not called by Sonarr/Radarr?"
	log "ERROR: Expected positional args (\$1/\$2) or Sonarr_SourcePath/Radarr_SourcePath env vars"
	exit 1
fi

log "=== $APP Import Request ==="
log "Source: $SOURCE_PATH"
log "Destination: $DEST_PATH"
log "Zurg base: $ZURG_BASE"

# ==============================================================================
# Validate source
# ==============================================================================

if [[ ! -e "$SOURCE_PATH" ]] && [[ ! -L "$SOURCE_PATH" ]]; then
	log "ERROR: Source does not exist: $SOURCE_PATH"
	exit 1
fi

# ==============================================================================
# Resolve source to real target
# ==============================================================================

if [[ -L "$SOURCE_PATH" ]]; then
	# Source is a symlink - get the target
	REAL_TARGET=$(readlink -f "$SOURCE_PATH")
	log "Source is symlink, target: $REAL_TARGET"

	# Check if symlink target is accessible
	if [[ ! -e "$REAL_TARGET" ]]; then
		log "WARN: Symlink target not accessible (possibly stale mount): $REAL_TARGET"
		# Still proceed - the target path is on the zurg mount, we just need to
		# create a new symlink pointing to the same target
		if [[ "$REAL_TARGET" == "$ZURG_BASE"* ]]; then
			log "INFO: Target is on zurg mount, will create symlink even though target is currently inaccessible"
		else
			log "ERROR: Symlink target is inaccessible and not on zurg mount"
			exit 1
		fi
	fi
else
	# Source is a regular file - use it directly
	REAL_TARGET="$SOURCE_PATH"
	log "Source is regular file"
fi

# ==============================================================================
# Handle import
# ==============================================================================

if [[ "$REAL_TARGET" == "$ZURG_BASE"* ]]; then
	log "Target is on zurg mount - creating symlink"

	# Verify mount health before proceeding
	if ! _check_mount "$ZURG_BASE"; then
		log "ERROR: Zurg mount is not healthy, cannot proceed"
		exit 1
	fi

	# Ensure destination directory exists
	DEST_DIR=$(dirname "$DEST_PATH")
	if [[ ! -d "$DEST_DIR" ]]; then
		log "Creating destination directory: $DEST_DIR"
		if ! mkdir -p "$DEST_DIR"; then
			log "ERROR: Failed to create directory: $DEST_DIR"
			exit 1
		fi
	fi

	# Handle existing destination (upgrade scenario)
	if [[ -L "$DEST_PATH" ]]; then
		# Existing symlink - remove it (even if stale/broken)
		existing_target=$(readlink "$DEST_PATH" 2>/dev/null) || existing_target="(broken)"
		log "Removing existing symlink: $DEST_PATH -> $existing_target"
		rm -f "$DEST_PATH"
	elif [[ -e "$DEST_PATH" ]]; then
		# Regular file exists at destination
		log "Removing existing file: $DEST_PATH"
		rm -f "$DEST_PATH"
	fi

	# Create symlink
	if ln -s "$REAL_TARGET" "$DEST_PATH"; then
		log "SUCCESS: Created symlink: $DEST_PATH -> $REAL_TARGET"
		# Signal to Sonarr/Radarr that the import is complete
		echo "[MoveStatus]MoveComplete"
		exit 0
	else
		log "ERROR: Failed to create symlink"
		exit 1
	fi
else
	# Not on zurg mount - do a regular move
	log "Target not on zurg mount - performing regular move"

	# Ensure destination directory exists
	DEST_DIR=$(dirname "$DEST_PATH")
	if [[ ! -d "$DEST_DIR" ]]; then
		log "Creating destination directory: $DEST_DIR"
		mkdir -p "$DEST_DIR"
	fi

	# Try to move
	if mv "$SOURCE_PATH" "$DEST_PATH"; then
		log "SUCCESS: Moved file to destination"
		echo "[MoveStatus]MoveComplete"
		exit 0
	else
		log "ERROR: Failed to move file"
		exit 1
	fi
fi
