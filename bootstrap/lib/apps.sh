#!/bin/bash
# apps.sh - App bundles, script runner, order enforcement
# Part of swizzin-scripts bootstrap

# ==============================================================================
# Script Repository Location
# ==============================================================================

# Where the swizzin-scripts repo is cloned/downloaded
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ==============================================================================
# App Bundles
# ==============================================================================

declare -A APP_BUNDLES

# Core: Just Swizzin base
APP_BUNDLES[core]="nginx panel"

# Streaming: Media servers
APP_BUNDLES[streaming]="plex emby jellyfin"

# Arr Stack: Media management
APP_BUNDLES[arr]="sonarr radarr bazarr prowlarr"

# Debrid: Real-Debrid integration
APP_BUNDLES[debrid]="zurg decypharr"

# Helpers: Additional tools
APP_BUNDLES[helpers]="huntarr cleanuparr byparr notifiarr"

# Full Stack: Everything
APP_BUNDLES[full]="plex emby jellyfin sonarr radarr bazarr prowlarr zurg decypharr huntarr cleanuparr byparr notifiarr organizr"

# ==============================================================================
# Installation Order
# ==============================================================================

# Order matters! Dependencies and conflicts handled here
INSTALL_ORDER=(
    # Phase 1: Swizzin base (handled separately)

    # Phase 2: Media servers (emby before jellyfin for port conflict)
    "plex"
    "emby"
    "jellyfin"

    # Phase 3: Arr stack (multi-instance capable)
    "sonarr"
    "radarr"
    "bazarr"
    "prowlarr"

    # Phase 4: Debrid (zurg before decypharr)
    "zurg"
    "decypharr"

    # Phase 5: Helpers
    "huntarr"
    "cleanuparr"
    "byparr"
    "notifiarr"
    "subgen"

    # Phase 6: Watchdog (after media servers)
    "emby-watchdog"

    # Phase 7: SSO Gateway (ALWAYS LAST)
    "organizr"
)

# ==============================================================================
# App Configuration
# ==============================================================================

# Which apps are from this repo vs Swizzin
declare -A APP_SOURCE
APP_SOURCE[plex]="repo"        # Uses plex.sh from this repo
APP_SOURCE[emby]="repo"        # Uses emby.sh from this repo
APP_SOURCE[jellyfin]="repo"    # Uses jellyfin.sh from this repo
APP_SOURCE[sonarr]="repo"      # Uses sonarr.sh (multi-instance)
APP_SOURCE[radarr]="repo"      # Uses radarr.sh (multi-instance)
APP_SOURCE[bazarr]="repo"      # Uses bazarr.sh (multi-instance)
APP_SOURCE[prowlarr]="swizzin" # Uses box install prowlarr
APP_SOURCE[zurg]="repo"
APP_SOURCE[decypharr]="repo"
APP_SOURCE[huntarr]="repo"
APP_SOURCE[cleanuparr]="repo"
APP_SOURCE[byparr]="repo"
APP_SOURCE[notifiarr]="repo"
APP_SOURCE[subgen]="repo"
APP_SOURCE[organizr]="repo"
APP_SOURCE[emby-watchdog]="repo"
APP_SOURCE[nginx]="swizzin"
APP_SOURCE[panel]="swizzin"

# Script files for repo apps
declare -A APP_SCRIPT
APP_SCRIPT[plex]="plex.sh"
APP_SCRIPT[emby]="emby.sh"
APP_SCRIPT[jellyfin]="jellyfin.sh"
APP_SCRIPT[sonarr]="sonarr.sh"
APP_SCRIPT[radarr]="radarr.sh"
APP_SCRIPT[bazarr]="bazarr.sh"
APP_SCRIPT[zurg]="zurg.sh"
APP_SCRIPT[decypharr]="decypharr.sh"
APP_SCRIPT[huntarr]="huntarr.sh"
APP_SCRIPT[cleanuparr]="cleanuparr.sh"
APP_SCRIPT[byparr]="byparr.sh"
APP_SCRIPT[notifiarr]="notifiarr.sh"
APP_SCRIPT[subgen]="subgen.sh"
APP_SCRIPT[organizr]="organizr.sh"
APP_SCRIPT[emby-watchdog]="emby-watchdog.sh"

# ==============================================================================
# App Selection
# ==============================================================================

select_apps() {
    echo_header "App Selection"

    echo "Select installation bundle:"
    echo ""
    echo "  1) Core only      - nginx + panel"
    echo "  2) Streaming      - Core + Plex + Emby + Jellyfin"
    echo "  3) Arr Stack      - Core + Sonarr + Radarr + Bazarr + Prowlarr"
    echo "  4) Debrid         - Core + Zurg + Decypharr"
    echo "  5) Full Stack     - Everything (recommended)"
    echo "  6) Custom         - Choose individual apps"
    echo ""

    local choice
    read -rp "Choice [1-6]: " choice </dev/tty

    case "$choice" in
        1) SELECTED_APPS=(${APP_BUNDLES[core]}) ;;
        2) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[streaming]}) ;;
        3) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[arr]}) ;;
        4) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[debrid]}) ;;
        5) SELECTED_APPS=(${APP_BUNDLES[core]} ${APP_BUNDLES[full]}) ;;
        6) select_custom_apps ;;
        *) echo_error "Invalid choice"; exit 1 ;;
    esac

    # Remove duplicates while preserving order
    SELECTED_APPS=($(echo "${SELECTED_APPS[@]}" | tr ' ' '\n' | awk '!seen[$0]++'))

    echo ""
    echo_info "Selected apps: ${SELECTED_APPS[*]}"

    # Ask about subdomain for media servers
    for app in plex emby jellyfin organizr seerr; do
        if [[ " ${SELECTED_APPS[*]} " =~ " ${app} " ]]; then
            if ask "Configure $app with subdomain?" N; then
                SUBDOMAIN_APPS+=("$app")
            fi
        fi
    done

    # Ask about multi-instance for arr apps
    for app in sonarr radarr bazarr; do
        if [[ " ${SELECTED_APPS[*]} " =~ " ${app} " ]]; then
            if ask "Add additional $app instances (e.g., 4k, anime)?" N; then
                echo_info "Enter instance names (comma-separated, e.g., 4k,anime):"
                read -rp "> " instances </dev/tty
                MULTI_INSTANCES[$app]="$instances"
            fi
        fi
    done
}

select_custom_apps() {
    echo_header "Custom App Selection"

    local all_apps=(
        "plex:Plex Media Server"
        "emby:Emby Media Server"
        "jellyfin:Jellyfin Media Server"
        "sonarr:Sonarr (TV Shows)"
        "radarr:Radarr (Movies)"
        "bazarr:Bazarr (Subtitles)"
        "prowlarr:Prowlarr (Indexer Manager)"
        "zurg:Zurg (Real-Debrid WebDAV)"
        "decypharr:Decypharr (Debrid Manager)"
        "huntarr:Huntarr (Media Discovery)"
        "cleanuparr:Cleanuparr (Queue Cleanup)"
        "byparr:Byparr (FlareSolverr Alternative)"
        "notifiarr:Notifiarr (Notifications)"
        "subgen:Subgen (Subtitle Generation)"
        "organizr:Organizr (SSO Dashboard)"
    )

    SELECTED_APPS=("nginx" "panel")  # Always include core

    echo "Select apps to install (space to toggle, enter to confirm):"
    echo "(nginx and panel are always installed)"
    echo ""

    for app_info in "${all_apps[@]}"; do
        local app="${app_info%%:*}"
        local desc="${app_info#*:}"

        if ask "  Install $desc?" N; then
            SELECTED_APPS+=("$app")
        fi
    done
}

# ==============================================================================
# Environment Variable Collection
# ==============================================================================

declare -A APP_ENV

collect_app_config() {
    echo_header "App Configuration"

    # Collect Zurg config if selected
    if [[ " ${SELECTED_APPS[*]} " =~ " zurg " ]]; then
        echo_info "Zurg requires Real-Debrid API token"

        if [[ -z "${APP_ENV[RD_TOKEN]}" ]]; then
            APP_ENV[RD_TOKEN]=$(prompt_secret "Real-Debrid API token (from https://real-debrid.com/apitoken)")
        fi

        echo ""
        if ask "Do you have the paid/sponsor version of Zurg?" N; then
            APP_ENV[ZURG_VERSION]="paid"
            APP_ENV[GITHUB_TOKEN]=$(prompt_secret "GitHub Personal Access Token (for paid Zurg)")
        else
            APP_ENV[ZURG_VERSION]="free"
        fi

        APP_ENV[ZURG_MOUNT_POINT]=$(prompt_value "Zurg mount point" "/mnt/zurg")
    fi

    # Collect Notifiarr config if selected
    if [[ " ${SELECTED_APPS[*]} " =~ " notifiarr " ]]; then
        if [[ -z "${APP_ENV[DN_API_KEY]}" ]]; then
            APP_ENV[DN_API_KEY]=$(prompt_secret "Notifiarr API key (from notifiarr.com)")
        fi
    fi

    # Collect domain for subdomain apps
    if [[ ${#SUBDOMAIN_APPS[@]} -gt 0 ]]; then
        echo ""
        echo_info "Subdomain configuration"
        local base_domain
        base_domain=$(prompt_value "Base domain (e.g., example.com)")

        for app in "${SUBDOMAIN_APPS[@]}"; do
            local suggested="${app}.${base_domain}"
            local domain
            domain=$(prompt_value "Domain for $app" "$suggested")

            local var_name="${app^^}_DOMAIN"
            APP_ENV[$var_name]="$domain"
            APP_ENV["${app^^}_LE_INTERACTIVE"]="no"
        done
    fi
}

# ==============================================================================
# Installation Functions
# ==============================================================================

install_swizzin_base() {
    echo_header "Swizzin Installation"

    if [[ -f /install/.swizzin.lock ]]; then
        echo_info "Swizzin already installed"

        # Check for nginx and panel
        if [[ ! -f /install/.nginx.lock ]]; then
            echo_info "Installing nginx..."
            box install nginx
        fi
        if [[ ! -f /install/.panel.lock ]]; then
            echo_info "Installing panel..."
            box install panel
        fi
        return 0
    fi

    echo_info "Running Swizzin installer..."
    echo_warn "You will be prompted for username and password"
    echo_info "Make sure to select at least: nginx, panel"
    echo ""

    if ask "Ready to run Swizzin installer?" Y; then
        curl -sL https://swizzin.ltd/setup.sh | bash
    else
        echo_error "Swizzin installation required"
        exit 1
    fi

    # Verify installation
    if [[ ! -f /install/.swizzin.lock ]]; then
        echo_error "Swizzin installation failed"
        exit 1
    fi

    echo_success "Swizzin installed"
}

install_app() {
    local app="$1"
    local source="${APP_SOURCE[$app]:-swizzin}"

    # Skip if already installed
    local lock_file="/install/.${app}.lock"
    if [[ -f "$lock_file" ]]; then
        echo_info "$app already installed"
        return 0
    fi

    echo_progress_start "Installing $app"

    if [[ "$source" == "swizzin" ]]; then
        # Install via box
        box install "$app" >>"$LOG_FILE" 2>&1
    else
        # Install via repo script
        local script="${APP_SCRIPT[$app]}"
        local script_path="$SCRIPTS_DIR/$script"

        if [[ ! -f "$script_path" ]]; then
            echo_progress_fail "Script not found: $script_path"
            return 1
        fi

        # Export environment variables for this app
        _export_app_env "$app"

        # Run the script
        bash "$script_path" >>"$LOG_FILE" 2>&1
    fi

    local result=$?

    if [[ $result -eq 0 ]]; then
        echo_progress_done "$app installed"
    else
        echo_progress_fail "$app installation failed"
        echo_warn "Check $LOG_FILE for details"
    fi

    return $result
}

_export_app_env() {
    local app="$1"

    # Export relevant environment variables
    case "$app" in
        zurg)
            [[ -n "${APP_ENV[RD_TOKEN]}" ]] && export RD_TOKEN="${APP_ENV[RD_TOKEN]}"
            [[ -n "${APP_ENV[ZURG_VERSION]}" ]] && export ZURG_VERSION="${APP_ENV[ZURG_VERSION]}"
            [[ -n "${APP_ENV[GITHUB_TOKEN]}" ]] && export GITHUB_TOKEN="${APP_ENV[GITHUB_TOKEN]}"
            [[ -n "${APP_ENV[ZURG_MOUNT_POINT]}" ]] && export ZURG_MOUNT_POINT="${APP_ENV[ZURG_MOUNT_POINT]}"
            ;;
        decypharr)
            [[ -n "${APP_ENV[ZURG_MOUNT_POINT]}" ]] && export DECYPHARR_MOUNT_PATH="${APP_ENV[ZURG_MOUNT_POINT]}"
            ;;
        notifiarr)
            [[ -n "${APP_ENV[DN_API_KEY]}" ]] && export DN_API_KEY="${APP_ENV[DN_API_KEY]}"
            ;;
        plex)
            [[ -n "${APP_ENV[PLEX_DOMAIN]}" ]] && export PLEX_DOMAIN="${APP_ENV[PLEX_DOMAIN]}"
            [[ -n "${APP_ENV[PLEX_LE_INTERACTIVE]}" ]] && export PLEX_LE_INTERACTIVE="${APP_ENV[PLEX_LE_INTERACTIVE]}"
            ;;
        emby)
            [[ -n "${APP_ENV[EMBY_DOMAIN]}" ]] && export EMBY_DOMAIN="${APP_ENV[EMBY_DOMAIN]}"
            [[ -n "${APP_ENV[EMBY_LE_INTERACTIVE]}" ]] && export EMBY_LE_INTERACTIVE="${APP_ENV[EMBY_LE_INTERACTIVE]}"
            ;;
        jellyfin)
            [[ -n "${APP_ENV[JELLYFIN_DOMAIN]}" ]] && export JELLYFIN_DOMAIN="${APP_ENV[JELLYFIN_DOMAIN]}"
            [[ -n "${APP_ENV[JELLYFIN_LE_INTERACTIVE]}" ]] && export JELLYFIN_LE_INTERACTIVE="${APP_ENV[JELLYFIN_LE_INTERACTIVE]}"
            ;;
        organizr)
            [[ -n "${APP_ENV[ORGANIZR_DOMAIN]}" ]] && export ORGANIZR_DOMAIN="${APP_ENV[ORGANIZR_DOMAIN]}"
            [[ -n "${APP_ENV[ORGANIZR_LE_INTERACTIVE]}" ]] && export ORGANIZR_LE_INTERACTIVE="${APP_ENV[ORGANIZR_LE_INTERACTIVE]}"
            ;;
    esac
}

install_subdomain() {
    local app="$1"

    if [[ ! " ${SUBDOMAIN_APPS[*]} " =~ " ${app} " ]]; then
        return 0
    fi

    echo_progress_start "Configuring $app subdomain"

    local script="${APP_SCRIPT[$app]}"
    local script_path="$SCRIPTS_DIR/$script"

    _export_app_env "$app"

    bash "$script_path" --subdomain >>"$LOG_FILE" 2>&1

    if [[ $? -eq 0 ]]; then
        echo_progress_done "$app subdomain configured"
    else
        echo_progress_fail "$app subdomain configuration failed"
    fi
}

install_multi_instances() {
    local app="$1"
    local instances="${MULTI_INSTANCES[$app]:-}"

    if [[ -z "$instances" ]]; then
        return 0
    fi

    local script="${APP_SCRIPT[$app]}"
    local script_path="$SCRIPTS_DIR/$script"

    IFS=',' read -ra instance_array <<< "$instances"
    for instance in "${instance_array[@]}"; do
        instance=$(echo "$instance" | tr -d ' ')
        echo_progress_start "Adding $app instance: $instance"

        bash "$script_path" --add "$instance" >>"$LOG_FILE" 2>&1

        if [[ $? -eq 0 ]]; then
            echo_progress_done "$app-$instance added"
        else
            echo_progress_fail "$app-$instance failed"
        fi
    done
}

# ==============================================================================
# Main Installation Runner
# ==============================================================================

run_app_installation() {
    echo_header "Installing Applications"

    # Ensure log file exists
    LOG_FILE="${LOG_FILE:-/root/logs/bootstrap.log}"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    # Install Swizzin base first
    install_swizzin_base

    # Install apps in order
    for app in "${INSTALL_ORDER[@]}"; do
        # Skip if not selected
        if [[ ! " ${SELECTED_APPS[*]} " =~ " ${app} " ]]; then
            continue
        fi

        # Skip special cases
        if [[ "$app" == "emby-watchdog" ]]; then
            # Only install if emby is selected
            if [[ " ${SELECTED_APPS[*]} " =~ " emby " ]]; then
                echo_progress_start "Installing Emby watchdog"
                bash "$SCRIPTS_DIR/emby-watchdog.sh" --install >>"$LOG_FILE" 2>&1
                echo_progress_done "Emby watchdog installed"
            fi
            continue
        fi

        # Install the app
        install_app "$app"

        # Configure subdomain if requested
        install_subdomain "$app"

        # Add multi-instances if requested
        install_multi_instances "$app"
    done

    echo ""
    echo_success "All applications installed"
}

# ==============================================================================
# Global Variables
# ==============================================================================

SELECTED_APPS=()
SUBDOMAIN_APPS=()
declare -A MULTI_INSTANCES
