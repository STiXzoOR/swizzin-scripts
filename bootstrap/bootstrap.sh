#!/bin/bash
# bootstrap.sh - Main entry point for server bootstrapping
# Part of swizzin-scripts
#
# Usage:
#   bash bootstrap.sh              # Interactive full bootstrap
#   bash bootstrap.sh --hardening  # Run hardening only
#   bash bootstrap.sh --tuning     # Run kernel tuning only
#   bash bootstrap.sh --apps       # Run app installation only
#   bash bootstrap.sh --restore    # Restore menu
#   bash bootstrap.sh --help       # Show help

set -euo pipefail

# ==============================================================================
# Script Location
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"

# ==============================================================================
# Load Libraries
# ==============================================================================

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/hardening.sh"
source "$SCRIPT_DIR/lib/tuning.sh"
source "$SCRIPT_DIR/lib/restore.sh"
source "$SCRIPT_DIR/lib/apps.sh"
source "$SCRIPT_DIR/lib/notifications.sh"

# ==============================================================================
# Configuration
# ==============================================================================

LOG_FILE="/root/logs/bootstrap.log"
BOOTSTRAP_MARKER="/opt/swizzin/bootstrap.done"
VERSION="1.0.0"

# ==============================================================================
# Help
# ==============================================================================

show_help() {
    cat <<EOF
Swizzin Server Bootstrap v${VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
  --full              Run full bootstrap (default if no options)
  --hardening         Run security hardening only (SSH, fail2ban, UFW)
  --tuning            Run kernel tuning only (sysctl, limits)
  --apps              Run app installation only
  --notifications     Run notification setup only
  --restore           Show restore menu
  --restore-ssh       Restore SSH to defaults
  --restore-fail2ban  Restore fail2ban to defaults
  --restore-ufw       Restore UFW to defaults
  --restore-tuning    Restore kernel tuning to defaults
  --restore-all       Restore all settings to defaults
  --list-backups      List available backups
  --clean-backups     Remove all backups
  --status            Show current bootstrap status
  --help              Show this help message

Environment Variables:
  SSH_PORT            SSH port (default: 22)
  SSH_KEY             SSH public key or path to key file
  REBOOT_TIME         Auto-reboot time for updates (default: 04:00)
  PUSHOVER_USER       Pushover user key
  PUSHOVER_TOKEN      Pushover API token
  RD_TOKEN            Real-Debrid API token
  ZURG_VERSION        Zurg version (free/paid)
  GITHUB_TOKEN        GitHub token for paid Zurg

Examples:
  # Full interactive bootstrap
  sudo bash bootstrap.sh

  # Hardening only with custom SSH port
  SSH_PORT=2222 sudo bash bootstrap.sh --hardening

  # Non-interactive with pre-set values
  SSH_PORT=2222 SSH_KEY="ssh-ed25519 AAAA..." sudo bash bootstrap.sh --hardening

EOF
}

# ==============================================================================
# Status
# ==============================================================================

show_status() {
    echo_header "Bootstrap Status"

    # Check marker
    if [[ -f "$BOOTSTRAP_MARKER" ]]; then
        echo_success "Bootstrap has been run"
        echo_info "Date: $(cat "$BOOTSTRAP_MARKER")"
    else
        echo_warn "Bootstrap has NOT been run"
    fi

    echo ""

    # Check components
    echo "Component Status:"
    echo ""

    # Swizzin
    if [[ -f /install/.swizzin.lock ]]; then
        echo -e "  ${GREEN}✓${NC} Swizzin installed"
    else
        echo -e "  ${RED}✗${NC} Swizzin not installed"
    fi

    # SSH hardening
    if [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
        local ssh_port
        ssh_port=$(grep -E "^Port" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null | awk '{print $2}')
        echo -e "  ${GREEN}✓${NC} SSH hardened (port ${ssh_port:-unknown})"
    else
        echo -e "  ${YELLOW}○${NC} SSH using defaults"
    fi

    # fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} fail2ban active"
    else
        echo -e "  ${RED}✗${NC} fail2ban not active"
    fi

    # UFW
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "  ${GREEN}✓${NC} UFW active"
    else
        echo -e "  ${YELLOW}○${NC} UFW not active"
    fi

    # Kernel tuning
    if [[ -f /etc/sysctl.d/99-streaming.conf ]]; then
        echo -e "  ${GREEN}✓${NC} Kernel tuning applied"
    else
        echo -e "  ${YELLOW}○${NC} Kernel tuning not applied"
    fi

    # Unattended upgrades
    if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
        echo -e "  ${GREEN}✓${NC} Unattended upgrades configured"
    else
        echo -e "  ${YELLOW}○${NC} Unattended upgrades not configured"
    fi

    # Pushover
    if [[ -f /opt/swizzin/bootstrap.conf ]] && grep -q "PUSHOVER_USER=" /opt/swizzin/bootstrap.conf; then
        echo -e "  ${GREEN}✓${NC} Notifications configured"
    else
        echo -e "  ${YELLOW}○${NC} Notifications not configured"
    fi

    echo ""

    # List installed apps
    echo "Installed Apps:"
    echo ""
    local app_count=0
    for lock_file in /install/.*.lock; do
        if [[ -f "$lock_file" ]]; then
            local app_name
            app_name=$(basename "$lock_file" | sed 's/^\.\(.*\)\.lock$/\1/')
            echo "  - $app_name"
            ((app_count++))
        fi
    done

    if [[ $app_count -eq 0 ]]; then
        echo "  (none)"
    fi
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================

preflight_checks() {
    echo_header "Pre-flight Checks"

    validate_root
    validate_os
    validate_architecture
    validate_network
    validate_disk_space
    validate_memory

    echo ""
    echo_success "All pre-flight checks passed"
}

# ==============================================================================
# Collect Configuration
# ==============================================================================

collect_configuration() {
    echo_header "Configuration"

    # SSH Configuration
    echo_info "SSH Configuration"
    echo ""

    if [[ -z "${SSH_PORT:-}" ]]; then
        SSH_PORT=$(prompt_value "SSH port" "22")
    fi

    if ! validate_port_range "$SSH_PORT"; then
        echo_error "Invalid SSH port: $SSH_PORT"
        exit 1
    fi

    if [[ -z "${SSH_KEY:-}" ]]; then
        echo_info "SSH public key (paste key or path to file, or press Enter to skip)"
        read -rp "> " SSH_KEY </dev/tty
    fi

    # Reboot time
    if [[ -z "${REBOOT_TIME:-}" ]]; then
        REBOOT_TIME=$(prompt_value "Auto-reboot time for updates (HH:MM)" "04:00")
    fi

    echo ""
    echo_info "Configuration Summary:"
    echo "  SSH Port: $SSH_PORT"
    echo "  SSH Key: ${SSH_KEY:+configured}"
    echo "  Reboot Time: $REBOOT_TIME"
    echo ""

    if ! ask "Proceed with these settings?" Y; then
        echo_info "Aborting"
        exit 0
    fi
}

# ==============================================================================
# Full Bootstrap
# ==============================================================================

run_full_bootstrap() {
    echo_header "Swizzin Server Bootstrap v${VERSION}"
    echo ""
    echo "This script will:"
    echo "  1. Harden SSH security"
    echo "  2. Configure fail2ban"
    echo "  3. Set up UFW firewall"
    echo "  4. Tune kernel for streaming"
    echo "  5. Configure unattended upgrades"
    echo "  6. Install Swizzin and applications"
    echo "  7. Set up notifications"
    echo ""

    if [[ -f "$BOOTSTRAP_MARKER" ]]; then
        echo_warn "Bootstrap has already been run on this system"
        echo_info "Previous run: $(cat "$BOOTSTRAP_MARKER")"
        echo ""
        if ! ask "Run bootstrap again?" N; then
            echo_info "Aborting"
            exit 0
        fi
    fi

    if ! ask "Ready to begin?" Y; then
        echo_info "Aborting"
        exit 0
    fi

    # Setup logging
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo ""
    echo "=============================================="
    echo "Bootstrap started: $(date)"
    echo "=============================================="
    echo ""

    # Pre-flight
    preflight_checks

    # Collect configuration
    collect_configuration

    # Run hardening
    run_hardening "$SSH_PORT" "$SSH_KEY" "$REBOOT_TIME"

    # Run tuning
    run_tuning

    # App selection and installation
    select_apps
    collect_app_config
    run_app_installation

    # Notifications
    run_notification_setup

    # Mark as complete
    mkdir -p "$(dirname "$BOOTSTRAP_MARKER")"
    date > "$BOOTSTRAP_MARKER"

    echo ""
    echo "=============================================="
    echo "Bootstrap completed: $(date)"
    echo "=============================================="
    echo ""

    echo_header "Bootstrap Complete!"
    echo ""
    echo_success "Your server has been bootstrapped successfully"
    echo ""
    echo_info "Next steps:"
    echo "  1. Test SSH access in a new terminal: ssh -p $SSH_PORT root@<server-ip>"
    echo "  2. Access Swizzin panel at: https://<server-ip>/panel"
    echo "  3. Configure your applications"
    echo ""
    echo_info "Logs saved to: $LOG_FILE"
    echo ""

    if ask "Reboot now to apply all changes?" Y; then
        echo_info "Rebooting in 5 seconds..."
        sleep 5
        reboot
    fi
}

# ==============================================================================
# Restore Menu
# ==============================================================================

restore_menu() {
    echo_header "Restore Menu"
    echo ""
    echo "Select what to restore:"
    echo ""
    echo "  1) SSH configuration"
    echo "  2) fail2ban configuration"
    echo "  3) UFW firewall rules"
    echo "  4) Kernel tuning"
    echo "  5) Unattended upgrades"
    echo "  6) All of the above"
    echo "  7) List available backups"
    echo "  8) Clean all backups"
    echo "  9) Exit"
    echo ""

    local choice
    read -rp "Choice [1-9]: " choice </dev/tty

    case "$choice" in
        1) restore_ssh ;;
        2) restore_fail2ban ;;
        3) restore_ufw ;;
        4) restore_tuning ;;
        5) restore_unattended_upgrades ;;
        6) restore_all ;;
        7) list_backups ;;
        8) clean_backups ;;
        9) exit 0 ;;
        *) echo_error "Invalid choice" ;;
    esac
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    # Parse arguments
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --full|"")
            require_root
            run_full_bootstrap
            ;;
        --hardening)
            require_root
            preflight_checks
            collect_configuration
            run_hardening "$SSH_PORT" "${SSH_KEY:-}" "${REBOOT_TIME:-04:00}"
            ;;
        --tuning)
            require_root
            preflight_checks
            run_tuning
            ;;
        --apps)
            require_root
            preflight_checks
            select_apps
            collect_app_config
            run_app_installation
            ;;
        --notifications)
            require_root
            run_notification_setup
            ;;
        --restore)
            require_root
            restore_menu
            ;;
        --restore-ssh)
            require_root
            restore_ssh
            ;;
        --restore-fail2ban)
            require_root
            restore_fail2ban
            ;;
        --restore-ufw)
            require_root
            restore_ufw
            ;;
        --restore-tuning)
            require_root
            restore_tuning
            ;;
        --restore-all)
            require_root
            restore_all
            ;;
        --list-backups)
            list_backups
            ;;
        --clean-backups)
            require_root
            clean_backups
            ;;
        *)
            echo_error "Unknown option: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
