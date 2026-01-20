#!/bin/bash
# ============================================
# SWIZZIN BACKUP INSTALLER
# ============================================
# Installs and configures the Swizzin backup system.
#
# Usage:
#   bash swizzin-backup-install.sh [options]
#
# Options:
#   --uninstall     Remove backup system completely
#   --upgrade       Upgrade to latest version
#   --reconfigure   Re-run configuration wizard

set -euo pipefail

# === CONFIGURATION ===
BACKUP_DIR="/opt/swizzin-extras/backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/swizzin-backup-install.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# === LOGGING ===
log() {
    echo -e "${GREEN}[+]${NC} $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[x]${NC} $*" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >> "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[i]${NC} $*"
}

header() {
    echo ""
    echo -e "${CYAN}${BOLD}=== $* ===${NC}"
    echo ""
}

# === UTILITIES ===
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

get_latest_github_release() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf) echo "arm" ;;
        *) echo "$arch" ;;
    esac
}

# === DEPENDENCY INSTALLATION ===
install_restic() {
    header "Installing Restic"

    if command_exists restic; then
        local current_version
        current_version=$(restic version | head -1 | awk '{print $2}')
        info "Restic already installed: $current_version"

        if ask "Update to latest version?" N; then
            log "Updating restic..."
        else
            return 0
        fi
    fi

    local arch
    arch=$(get_arch)
    local version
    version=$(get_latest_github_release "restic/restic")
    version="${version#v}"  # Remove 'v' prefix

    log "Installing restic ${version} for ${arch}..."

    local url="https://github.com/restic/restic/releases/download/v${version}/restic_${version}_linux_${arch}.bz2"
    local tmp_file="/tmp/restic.bz2"

    if curl -fsSL "$url" -o "$tmp_file"; then
        bunzip2 -f "$tmp_file"
        mv /tmp/restic /usr/local/bin/restic
        chmod +x /usr/local/bin/restic
        log "Restic ${version} installed successfully"
    else
        error "Failed to download restic"
        return 1
    fi
}

install_rclone() {
    header "Installing Rclone"

    if command_exists rclone; then
        local current_version
        current_version=$(rclone version | head -1 | awk '{print $2}')
        info "Rclone already installed: $current_version"

        if ask "Update to latest version?" N; then
            log "Updating rclone..."
        else
            return 0
        fi
    fi

    log "Installing latest rclone..."

    # Use official rclone install script
    if curl -fsSL https://rclone.org/install.sh | bash; then
        log "Rclone installed successfully"
    else
        error "Failed to install rclone"
        return 1
    fi
}

install_dependencies() {
    header "Installing Dependencies"

    local packages=()

    # Check for required packages
    command_exists jq || packages+=("jq")
    command_exists sqlite3 || packages+=("sqlite3")
    command_exists bzip2 || packages+=("bzip2")
    command_exists curl || packages+=("curl")

    if [[ ${#packages[@]} -gt 0 ]]; then
        log "Installing: ${packages[*]}"
        apt-get update -qq
        apt-get install -y -qq "${packages[@]}"
    else
        info "All apt dependencies already installed"
    fi

    install_restic
    install_rclone
}

# === INTERACTIVE HELPERS ===
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

prompt_password() {
    local prompt="$1"
    local password

    read -rsp "$(echo -e "${CYAN}$prompt:${NC} ")" password
    echo ""
    echo "$password"
}

generate_password() {
    openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

# === CONFIGURATION WIZARD ===
configure_encryption() {
    header "Encryption Setup"

    echo "Restic encrypts all backups with a password."
    echo -e "${RED}${BOLD}WARNING: If you lose this password, your backups are UNRECOVERABLE!${NC}"
    echo ""

    local password
    local password_file="/root/.swizzin-backup-password"

    echo "Choose password method:"
    echo "  1) Generate secure password (recommended)"
    echo "  2) Enter your own password"
    echo ""

    local choice
    choice=$(prompt "Selection" "1")

    case "$choice" in
        1)
            password=$(generate_password)
            echo ""
            echo -e "${GREEN}Generated password:${NC} ${BOLD}${password}${NC}"
            echo ""
            echo -e "${YELLOW}SAVE THIS PASSWORD SECURELY! You will need it to restore backups.${NC}"
            ;;
        2)
            password=$(prompt_password "Enter backup password")
            local confirm
            confirm=$(prompt_password "Confirm password")
            if [[ "$password" != "$confirm" ]]; then
                error "Passwords do not match"
                return 1
            fi
            ;;
        *)
            error "Invalid choice"
            return 1
            ;;
    esac

    echo "$password" > "$password_file"
    chmod 600 "$password_file"
    log "Password saved to $password_file"

    CONFIG_RESTIC_PASSWORD_FILE="$password_file"
}

configure_gdrive() {
    header "Google Drive Setup"

    if ! ask "Configure Google Drive backup?" Y; then
        CONFIG_GDRIVE_ENABLED="no"
        return 0
    fi

    CONFIG_GDRIVE_ENABLED="yes"

    # Check for existing rclone remote
    if rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
        info "Found existing 'gdrive' rclone remote"
        if ! ask "Use existing 'gdrive' remote?" Y; then
            log "Running rclone config..."
            rclone config
        fi
    else
        log "No 'gdrive' remote found. Running rclone config..."
        echo ""
        echo "Follow the prompts to configure Google Drive access."
        echo "When asked for remote name, use: gdrive"
        echo ""
        rclone config
    fi

    CONFIG_GDRIVE_REMOTE=$(prompt "Remote path for backups" "gdrive:swizzin-backups")

    # Test connection
    log "Testing Google Drive connection..."
    if rclone mkdir "${CONFIG_GDRIVE_REMOTE}" 2>/dev/null; then
        log "Google Drive connection successful"
    else
        warn "Could not connect to Google Drive. Check rclone config."
    fi
}

configure_sftp() {
    header "Windows Server (SFTP) Setup"

    if ! ask "Configure Windows Server backup?" Y; then
        CONFIG_SFTP_ENABLED="no"
        return 0
    fi

    CONFIG_SFTP_ENABLED="yes"

    CONFIG_SFTP_HOST=$(prompt "Windows Server hostname/IP")
    CONFIG_SFTP_PORT=$(prompt "SSH port" "22")
    CONFIG_SFTP_USER=$(prompt "SSH username" "backup")
    CONFIG_SFTP_PATH=$(prompt "Remote path (e.g., /C:/Backups/swizzin)")

    # Check for SSH key
    local ssh_key="/root/.ssh/id_rsa"
    if [[ ! -f "$ssh_key" ]]; then
        if ask "No SSH key found. Generate one?" Y; then
            ssh-keygen -t rsa -b 4096 -f "$ssh_key" -N ""
            log "SSH key generated at $ssh_key"
        fi
    fi
    CONFIG_SFTP_KEY="$ssh_key"

    # Offer to copy key
    if [[ -f "${ssh_key}.pub" ]]; then
        echo ""
        echo "Public key to add to Windows Server authorized_keys:"
        echo -e "${CYAN}$(cat "${ssh_key}.pub")${NC}"
        echo ""
        info "Add this to: C:\\Users\\${CONFIG_SFTP_USER}\\.ssh\\authorized_keys"
    fi

    if ask "Test SFTP connection now?" Y; then
        log "Testing SFTP connection..."
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "${CONFIG_SFTP_PORT}" "${CONFIG_SFTP_USER}@${CONFIG_SFTP_HOST}" "echo ok" &>/dev/null; then
            log "SFTP connection successful"
        else
            warn "SFTP connection failed. Ensure OpenSSH is enabled on Windows and key is authorized."
        fi
    fi
}

configure_pushover() {
    header "Pushover Notifications"

    if ! ask "Configure Pushover notifications?" Y; then
        CONFIG_PUSHOVER_ENABLED="no"
        return 0
    fi

    CONFIG_PUSHOVER_ENABLED="yes"

    echo "Get your keys from https://pushover.net"
    echo ""

    CONFIG_PUSHOVER_USER_KEY=$(prompt "User Key")
    CONFIG_PUSHOVER_API_TOKEN=$(prompt "API Token")
    CONFIG_PUSHOVER_PRIORITY=$(prompt "Priority (-2 to 2)" "0")

    if ask "Send test notification?" Y; then
        log "Sending test notification..."
        local response
        response=$(curl -s --form-string "token=${CONFIG_PUSHOVER_API_TOKEN}" \
            --form-string "user=${CONFIG_PUSHOVER_USER_KEY}" \
            --form-string "message=Swizzin Backup test notification" \
            --form-string "title=Swizzin Backup" \
            https://api.pushover.net/1/messages.json)

        if echo "$response" | grep -q '"status":1'; then
            log "Test notification sent successfully"
        else
            warn "Failed to send notification: $response"
        fi
    fi
}

configure_schedule() {
    header "Backup Schedule"

    CONFIG_BACKUP_HOUR=$(prompt "Backup hour (0-23)" "03")
    CONFIG_BACKUP_MINUTE=$(prompt "Backup minute (0-59)" "00")

    log "Backups will run daily at ${CONFIG_BACKUP_HOUR}:${CONFIG_BACKUP_MINUTE}"
}

configure_retention() {
    header "Retention Policy"

    echo "GFS (Grandfather-Father-Son) retention:"
    echo ""

    CONFIG_KEEP_DAILY=$(prompt "Keep daily backups" "7")
    CONFIG_KEEP_WEEKLY=$(prompt "Keep weekly backups" "4")
    CONFIG_KEEP_MONTHLY=$(prompt "Keep monthly backups" "3")

    local total=$((CONFIG_KEEP_DAILY + CONFIG_KEEP_WEEKLY + CONFIG_KEEP_MONTHLY))
    info "Will keep approximately ${total} snapshots"
}

write_config() {
    header "Writing Configuration"

    local config_file="${BACKUP_DIR}/backup.conf"

    cat > "$config_file" << EOF
# Swizzin Backup Configuration
# Generated: $(date)

# Encryption
RESTIC_PASSWORD_FILE="${CONFIG_RESTIC_PASSWORD_FILE:-/root/.swizzin-backup-password}"

# Google Drive
GDRIVE_ENABLED="${CONFIG_GDRIVE_ENABLED:-no}"
GDRIVE_REMOTE="${CONFIG_GDRIVE_REMOTE:-gdrive:swizzin-backups}"

# SFTP (Windows Server)
SFTP_ENABLED="${CONFIG_SFTP_ENABLED:-no}"
SFTP_HOST="${CONFIG_SFTP_HOST:-}"
SFTP_USER="${CONFIG_SFTP_USER:-backup}"
SFTP_PORT="${CONFIG_SFTP_PORT:-22}"
SFTP_PATH="${CONFIG_SFTP_PATH:-/C:/Backups/swizzin}"
SFTP_KEY="${CONFIG_SFTP_KEY:-/root/.ssh/id_rsa}"

# Retention (GFS)
KEEP_DAILY=${CONFIG_KEEP_DAILY:-7}
KEEP_WEEKLY=${CONFIG_KEEP_WEEKLY:-4}
KEEP_MONTHLY=${CONFIG_KEEP_MONTHLY:-3}

# Pushover
PUSHOVER_ENABLED="${CONFIG_PUSHOVER_ENABLED:-no}"
PUSHOVER_USER_KEY="${CONFIG_PUSHOVER_USER_KEY:-}"
PUSHOVER_API_TOKEN="${CONFIG_PUSHOVER_API_TOKEN:-}"
PUSHOVER_PRIORITY="${CONFIG_PUSHOVER_PRIORITY:-0}"

# Schedule
BACKUP_HOUR="${CONFIG_BACKUP_HOUR:-03}"
BACKUP_MINUTE="${CONFIG_BACKUP_MINUTE:-00}"

# App handling
EXCLUDE_APPS=""
MEDIASERVER_MODE="config_only"
EXTRA_PATHS=""

# Advanced
PARALLEL_UPLOADS=4
LOG_FILE="/var/log/swizzin-backup.log"
MANIFEST_DIR="${BACKUP_DIR}/manifests"
EOF

    chmod 600 "$config_file"
    log "Configuration written to $config_file"
}

# === REPOSITORY INITIALIZATION ===
init_repositories() {
    header "Initializing Restic Repositories"

    source "${BACKUP_DIR}/backup.conf"

    export RESTIC_PASSWORD_FILE

    if [[ "$GDRIVE_ENABLED" == "yes" ]]; then
        log "Initializing Google Drive repository..."
        local gdrive_repo="rclone:${GDRIVE_REMOTE}"

        if restic -r "$gdrive_repo" snapshots &>/dev/null; then
            info "Google Drive repository already initialized"
        else
            if restic -r "$gdrive_repo" init; then
                log "Google Drive repository initialized"
            else
                warn "Failed to initialize Google Drive repository"
            fi
        fi
    fi

    if [[ "$SFTP_ENABLED" == "yes" ]]; then
        log "Initializing SFTP repository..."
        local sftp_repo="sftp:${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}${SFTP_PATH}"

        if restic -r "$sftp_repo" -o sftp.command="ssh -i ${SFTP_KEY} -p ${SFTP_PORT} ${SFTP_USER}@${SFTP_HOST} -s sftp" snapshots &>/dev/null; then
            info "SFTP repository already initialized"
        else
            if restic -r "$sftp_repo" -o sftp.command="ssh -i ${SFTP_KEY} -p ${SFTP_PORT} ${SFTP_USER}@${SFTP_HOST} -s sftp" init; then
                log "SFTP repository initialized"
            else
                warn "Failed to initialize SFTP repository"
            fi
        fi
    fi
}

# === CRON SETUP ===
setup_cron() {
    header "Setting Up Cron Job"

    source "${BACKUP_DIR}/backup.conf"

    local cron_file="/etc/cron.d/swizzin-backup"

    cat > "$cron_file" << EOF
# Swizzin Backup - runs daily at ${BACKUP_HOUR}:${BACKUP_MINUTE}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

${BACKUP_MINUTE} ${BACKUP_HOUR} * * * root ${BACKUP_DIR}/swizzin-backup.sh run >> /var/log/swizzin-backup.log 2>&1
EOF

    chmod 644 "$cron_file"
    log "Cron job created at $cron_file"
}

# === INSTALLATION ===
install_files() {
    header "Installing Backup Scripts"

    # Create directory structure
    mkdir -p "${BACKUP_DIR}"/{hooks,manifests,logs}

    # Copy scripts
    if [[ -f "${SCRIPT_DIR}/swizzin-backup.sh" ]]; then
        cp "${SCRIPT_DIR}/swizzin-backup.sh" "${BACKUP_DIR}/"
        chmod +x "${BACKUP_DIR}/swizzin-backup.sh"
        log "Installed swizzin-backup.sh"
    else
        warn "swizzin-backup.sh not found in ${SCRIPT_DIR}"
    fi

    if [[ -f "${SCRIPT_DIR}/swizzin-restore.sh" ]]; then
        cp "${SCRIPT_DIR}/swizzin-restore.sh" "${BACKUP_DIR}/"
        chmod +x "${BACKUP_DIR}/swizzin-restore.sh"
        log "Installed swizzin-restore.sh"
    else
        warn "swizzin-restore.sh not found in ${SCRIPT_DIR}"
    fi

    # Copy config files
    if [[ -f "${SCRIPT_DIR}/configs/app-registry.conf" ]]; then
        cp "${SCRIPT_DIR}/configs/app-registry.conf" "${BACKUP_DIR}/"
        log "Installed app-registry.conf"
    fi

    if [[ -f "${SCRIPT_DIR}/configs/excludes.conf" ]]; then
        cp "${SCRIPT_DIR}/configs/excludes.conf" "${BACKUP_DIR}/"
        log "Installed excludes.conf"
    fi

    # Copy hook examples
    if [[ -f "${SCRIPT_DIR}/hooks/pre-backup.sh.example" ]]; then
        cp "${SCRIPT_DIR}/hooks/pre-backup.sh.example" "${BACKUP_DIR}/hooks/"
    fi

    if [[ -f "${SCRIPT_DIR}/hooks/post-backup.sh.example" ]]; then
        cp "${SCRIPT_DIR}/hooks/post-backup.sh.example" "${BACKUP_DIR}/hooks/"
    fi

    # Create symlinks for easy access
    ln -sf "${BACKUP_DIR}/swizzin-backup.sh" /usr/local/bin/swizzin-backup
    ln -sf "${BACKUP_DIR}/swizzin-restore.sh" /usr/local/bin/swizzin-restore

    log "Created symlinks: swizzin-backup, swizzin-restore"
}

# === UNINSTALL ===
uninstall() {
    header "Uninstalling Swizzin Backup"

    if ! ask "Are you sure you want to remove Swizzin Backup?" N; then
        echo "Cancelled"
        exit 0
    fi

    # Remove cron
    rm -f /etc/cron.d/swizzin-backup
    log "Removed cron job"

    # Remove symlinks
    rm -f /usr/local/bin/swizzin-backup
    rm -f /usr/local/bin/swizzin-restore
    log "Removed symlinks"

    if ask "Remove backup configuration and scripts?" N; then
        rm -rf "${BACKUP_DIR}"
        log "Removed ${BACKUP_DIR}"
    fi

    if ask "Remove password file?" N; then
        rm -f /root/.swizzin-backup-password
        log "Removed password file"
    fi

    # Note: We don't remove restic/rclone as they may be used by other things

    log "Uninstallation complete"
    echo ""
    echo -e "${YELLOW}Note: restic and rclone were NOT removed.${NC}"
    echo -e "${YELLOW}Remote backup repositories were NOT deleted.${NC}"
}

# === MAIN ===
main() {
    check_root

    mkdir -p "$(dirname "$LOG_FILE")"

    case "${1:-}" in
        --uninstall)
            uninstall
            exit 0
            ;;
        --upgrade)
            header "Upgrading Swizzin Backup"
            install_restic
            install_rclone
            install_files
            log "Upgrade complete"
            exit 0
            ;;
        --reconfigure)
            if [[ ! -d "$BACKUP_DIR" ]]; then
                error "Swizzin Backup not installed. Run without --reconfigure first."
                exit 1
            fi
            ;;
        --help|-h)
            echo "Swizzin Backup Installer"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --uninstall     Remove backup system"
            echo "  --upgrade       Upgrade to latest version"
            echo "  --reconfigure   Re-run configuration wizard"
            echo "  --help          Show this help"
            exit 0
            ;;
    esac

    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║       SWIZZIN BACKUP INSTALLER            ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"

    # Install dependencies
    install_dependencies

    # Create directory structure
    install_files

    # Run configuration wizard
    configure_encryption
    configure_gdrive
    configure_sftp
    configure_pushover
    configure_schedule
    configure_retention

    # Write config
    write_config

    # Initialize repositories
    init_repositories

    # Setup cron
    setup_cron

    # Summary
    header "Installation Complete"

    echo -e "${GREEN}Swizzin Backup has been installed!${NC}"
    echo ""
    echo "Configuration: ${BACKUP_DIR}/backup.conf"
    echo "Cron job: /etc/cron.d/swizzin-backup"
    echo ""
    echo "Commands:"
    echo "  swizzin-backup run       - Run backup now"
    echo "  swizzin-backup status    - Check backup status"
    echo "  swizzin-backup list      - List available snapshots"
    echo "  swizzin-backup discover  - Preview what will be backed up"
    echo "  swizzin-restore          - Restore from backup"
    echo ""

    if ask "Run a test backup now?" Y; then
        log "Running discovery to show what will be backed up..."
        "${BACKUP_DIR}/swizzin-backup.sh" discover || true

        if ask "Proceed with actual backup?" Y; then
            "${BACKUP_DIR}/swizzin-backup.sh" run
        fi
    fi

    log "Installation completed successfully"
}

main "$@"
