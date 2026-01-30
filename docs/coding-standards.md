# Coding Standards

## Bracket Style

Always use Bash `[[ ]]` for conditionals:

```bash
# Correct
if [[ -f "$file" ]]; then
if [[ -n "$var" ]]; then

# Incorrect - do not use single brackets
if [ -f "$file" ]; then
```

## Variable Quoting

Always quote variables and use braces for clarity:

```bash
# Correct
touch "$log"
chown "${user}:${user}" "$config_dir"
mkdir -p "${app_dir}/${app_name}"

# Incorrect
touch $log
chown $user:$user $config_dir
```

## Confirmations

Use Swizzin's `ask` function for yes/no prompts:

```bash
if ask "Would you like to purge the configuration?" N; then
    rm -rf "$config_dir"
fi
```

## Script Header

Every script starts with:

```bash
#!/bin/bash
# <appname> installer
# STiXzoOR 2025
# Usage: bash <appname>.sh [--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
```

## Panel Helper Loading

Use the download-and-cache pattern:

```bash
PANEL_HELPER_LOCAL="/opt/swizzin-extras/panel_helpers.sh"
PANEL_HELPER_URL="https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/panel_helpers.sh"

_load_panel_helper() {
    if [[ -f "$PANEL_HELPER_LOCAL" ]]; then
        . "$PANEL_HELPER_LOCAL"
        return
    fi
    mkdir -p "$(dirname "$PANEL_HELPER_LOCAL")"
    if curl -fsSL "$PANEL_HELPER_URL" -o "$PANEL_HELPER_LOCAL" >>"$log" 2>&1; then
        chmod +x "$PANEL_HELPER_LOCAL"
        . "$PANEL_HELPER_LOCAL"
    fi
}
```

## Lock File Handling

Check before install, create after success:

```bash
# At start of install
if [[ -f "/install/.${app_lockname}.lock" ]]; then
    echo_error "${app_name} is already installed"
    exit 1
fi

# At end of successful install
touch "/install/.${app_lockname}.lock"
```
