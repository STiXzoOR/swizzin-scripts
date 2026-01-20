# Script Standards and Templates Design

## Overview

Establish consistent coding conventions across all Swizzin scripts and create reusable templates for common script categories to help contributors and ensure consistency.

## Coding Standards

### Panel Helper Loading

Use Pattern A - download and cache permanently:

```bash
PANEL_HELPER_LOCAL="/opt/swizzin-extras/panel_helpers.sh"
PANEL_HELPER_URL="https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/panel_helpers.sh"

_load_panel_helper() {
    if [[ -f "$PANEL_HELPER_LOCAL" ]]; then
        # shellcheck source=panel_helpers.sh
        . "$PANEL_HELPER_LOCAL"
        return
    fi

    mkdir -p "$(dirname "$PANEL_HELPER_LOCAL")"
    if curl -fsSL "$PANEL_HELPER_URL" -o "$PANEL_HELPER_LOCAL" >>"$log" 2>&1; then
        chmod +x "$PANEL_HELPER_LOCAL"
        . "$PANEL_HELPER_LOCAL"
    else
        echo_info "Could not fetch panel helper; skipping panel integration"
    fi
}
```

### Bracket Style

Use Bash `[[ ]]` throughout (not POSIX `[ ]`):

```bash
# Correct
if [[ -f "$file" ]]; then
if [[ "$var" == "value" ]]; then
if [[ "$name" =~ ^[a-zA-Z0-9]+$ ]]; then

# Incorrect
if [ -f "$file" ]; then
```

### Confirmations

Use Swizzin's `ask` function for all user confirmations:

```bash
# Correct
if ask "Would you like to purge the configuration?" N; then
    rm -rf "$config_dir"
fi

# Incorrect
echo -n "Purge configuration? (y/n) "
read -r response
```

### Variable Quoting

Always quote variables and use braces for clarity:

```bash
# Correct
touch "$log"
chown "${user}:${user}" "$config_dir"
echo "Installing ${app_name}..."
mkdir -p "${app_dir}/${app_name}"

# Incorrect
touch $log
chown "$user":"$user" $config_dir
```

### Function Naming

Use underscore prefix for internal functions, `_<action>_<appname>` pattern:

```bash
_install_myapp()
_remove_myapp()
_systemd_myapp()
_nginx_myapp()
```

### Script Header

Standard header format:

```bash
#!/bin/bash
# <appname> installer
# STiXzoOR 2025
# Usage: bash <appname>.sh [--remove [--force]]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
```

## Templates

### 1. Binary Installer (`templates/template-binary.sh`)

For apps distributed as single binaries (e.g., decypharr, notifiarr).

**Characteristics:**
- Download binary from GitHub releases
- Install to `/usr/bin/<appname>`
- Config at `/home/<user>/.config/<Appname>/`
- Systemd service
- Nginx subfolder config
- Panel registration

### 2. Python/uv App (`templates/template-python.sh`)

For Python apps using uv for dependency management (e.g., byparr, huntarr, subgen).

**Characteristics:**
- Clone repo to `/opt/<appname>`
- Install uv for user if not present
- Use `uv sync` for dependencies
- Config at `/home/<user>/.config/<Appname>/`
- Systemd runs via `uv run python main.py`
- Optional nginx config

### 3. Subdomain Converter (`templates/template-subdomain.sh`)

For converting existing Swizzin apps from subfolder to subdomain (e.g., plex-subdomain, emby-subdomain).

**Characteristics:**
- Requires base app already installed
- Request Let's Encrypt certificate
- Create dedicated nginx vhost
- Update panel meta with `urloverride`
- Backup original config
- Support `--revert` and `--remove` flags

### 4. Multi-Instance Manager (`templates/template-multiinstance.sh`)

For managing multiple instances of a base app (e.g., sonarr, radarr).

**Characteristics:**
- Install base app via `box install` if needed
- Add named instances with validation
- Dynamic port allocation
- Per-instance: config dir, systemd service, nginx config, panel entry
- Support `--add`, `--remove`, `--list` flags
- Base app panel meta override for `check_theD = False`

## Template Structure

Each template includes:

1. **Header** - Description, usage, customization points
2. **Configuration section** - Variables to customize (marked with `# CUSTOMIZE:`)
3. **Standard functions** - Following naming conventions
4. **Main logic** - Argument handling, install/remove flow
5. **Inline comments** - Explaining each section

## Immediate Work

### Scripts to Update

1. **sonarr.sh** - Update to follow all standards
2. **radarr.sh** - Update to follow all standards

### Changes Required

- Replace inline panel helper loading with `_load_panel_helper()` function
- Ensure all `[[ ]]` usage (already done)
- Replace any manual prompts with `ask` function
- Verify consistent quoting throughout

## Future Work

Update remaining scripts to follow standards:
- decypharr.sh
- notifiarr.sh
- byparr.sh
- huntarr.sh
- subgen.sh
- zurg.sh
- seerr.sh
- plex.sh
- plex-subdomain.sh
- emby-subdomain.sh
- jellyfin-subdomain.sh
- organizr-subdomain.sh

## Documentation Updates

### CLAUDE.md

Add new section documenting:
- Coding standards reference
- Template locations and purposes
- Contribution workflow

### README.md

Update Contributing section to:
- Reference templates directory
- Link to coding standards
