---
name: new-binary-installer
description: Use when creating a Swizzin installer for a single-binary app downloaded from GitHub releases to /usr/bin. Triggers on "add binary app", "new installer for <app> that ships as a binary", decypharr-style, notifiarr-style scripts.
---

# New Binary Installer

Create a Swizzin installer for a single-binary application (GitHub releases -> `/usr/bin`).

## Quick Reference

| What to set | Where | Example |
|---|---|---|
| App identity | `app_name`, `app_pretty`, `app_lockname` | `decypharr`, `Decypharr` |
| GitHub repo | `github_repo` in `_install_*()` and `_update_*()` | `cy4n/decypharr` |
| Arch mapping | `case "$(_os_arch)"` blocks | `amd64->x86_64` |
| Port | `app_port` | `$(port 10000 12000)` |
| Config format | heredoc in `_install_*()` | JSON, YAML, TOML |
| Systemd | `ExecStart` in `_systemd_*()` | `${app_dir}/${app_binary} --config=...` |
| Nginx | `proxy_pass` in `_nginx_*()` | `http://127.0.0.1:${app_port}/` |
| Icon | `app_icon_url` | `https://cdn.jsdelivr.net/...` |

## Steps

1. **Copy template**: `cp templates/template-binary.sh <app>.sh`
2. **Find-and-replace**: `myapp`->`name`, `Myapp`->`Name`, `MYAPP`->`NAME`
3. **Customize** all `# CUSTOMIZE:` sections (6 locations: variables, arch x2, config, systemd, nginx)
4. **Test**: install, `--update`, `--update --full`, `--update --verbose`, `--remove`, `--remove --force`

## Template Structure

The template at `templates/template-binary.sh` provides:

- **Cleanup trap**: Rolls back nginx, systemd, lock file on failure
- **`_install_*()`**: GitHub API -> download -> extract -> create config (with overwrite guard)
- **`_backup_*()`** / **`_rollback_*()`**: Pre-update backup, auto-restore on failure
- **`_update_*()`**: Binary-only (default) or `--full` reinstall, with `--verbose`
- **`_systemd_*()`**: Type=simple, KillMode=control-group, Restart=on-failure
- **`_nginx_*()`**: Reverse proxy with auth_basic + API bypass (auth_basic off)
- **`_remove_*()`**: Service + binary + nginx + panel + optional config purge
- **Main**: Parses `--remove`, `--update`, `--register-panel`, checks lock file

## Coding Standards

- `set -euo pipefail` + `[[ ]]` conditionals + quoted variables
- `${1:-}` for positional params (never bare `$1`)
- `mktemp` for temp files, `chmod 600` for credential configs
- `_reload_nginx` from `lib/nginx-utils.sh` (never bare `systemctl reload nginx`)
- `curl --config <(printf ...)` for API keys (hides from `ps aux`)
- Config overwrite guard: `[[ ! -f "$config_file" ]]` before writing
- `((count++)) || true` for arithmetic under `set -e`

## Post-Creation Checklist

Per `docs/maintenance-checklist.md`:

- [ ] `swizzin-app-info` APP_CONFIGS entry
- [ ] `backup/swizzin-backup.sh` arrays (SERVICE_TYPES, SERVICE_NAME_MAP, SERVICE_STOP_ORDER)
- [ ] `backup/swizzin-restore.sh` APP_PATHS
- [ ] `backup/swizzin-excludes.txt`
- [ ] `backup/README.md` supported apps table
- [ ] `README.md` available scripts table
- [ ] `docs/architecture.md` files overview
