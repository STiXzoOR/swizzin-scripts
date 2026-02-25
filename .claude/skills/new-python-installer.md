---
name: new-python-installer
description: Use when creating a Swizzin installer for a Python app using uv for dependency management, cloned from git to /opt/. Triggers on "add python app", "new uv-based installer", byparr-style, huntarr-style, subgen-style scripts.
---

# New Python/UV Installer

Create a Swizzin installer for a Python app using `uv` (git clone to `/opt/<app>`, `uv sync` for deps).

## Quick Reference

| What to set | Where | Example |
|---|---|---|
| App identity | `app_name`, `app_pretty` | `huntarr`, `Huntarr` |
| Git repo URL | `github_repo` in `_install_*()` | `https://github.com/plexguide/Huntarr.io.git` |
| Port | `app_port` | `$(port 10000 12000)` or fixed `8191` |
| Entrypoint | `ExecStart` in `_systemd_*()` | `uv run python main.py` |
| Nginx toggle | `app_needs_nginx` | `true` or `false` |
| Env config | heredoc in `_install_*()` | `HOST=127.0.0.1`, `PORT=...` |
| Icon | `app_icon_url` | `https://cdn.jsdelivr.net/...` |

## Steps

1. **Copy template**: `cp templates/template-python.sh <app>.sh`
2. **Find-and-replace**: `myapp`->`name`, `Myapp`->`Name`
3. **Customize** all `# CUSTOMIZE:` sections (4 locations: variables, repo URL, env config, systemd)
4. **Test**: install, `--update`, `--update --full`, `--remove`, `--remove --force`

## Key Differences from Binary Template

- **uv**: `_install_uv()` installs per-user via `curl | sh`
- **Git clone**: Repo cloned to `/opt/<app>`, user-owned
- **Deps**: `su - "$user" -c "cd '$app_dir' && uv sync"`
- **Systemd**: `EnvironmentFile=${app_configdir}/env.conf`, runs `uv run python`
- **Update default**: `git pull` + `uv sync` (not binary replacement)
- **Rollback**: Copies entire `/opt/<app>` directory
- **Nginx optional**: `app_needs_nginx=false` skips nginx, panel uses `urloverride`

## Template Structure

The template at `templates/template-python.sh` provides:

- **`_install_uv()`**: Installs uv for the app user if missing
- **`_install_*()`**: Clone repo, `uv sync`, create env.conf (with overwrite guard)
- **`_backup_*()`** / **`_rollback_*()`**: Full app dir backup/restore
- **`_update_*()`**: Smart update (git pull + uv sync) or `--full` reinstall
- **`_systemd_*()`**: EnvironmentFile-based, `uv run python <entry>.py`
- **`_nginx_*()`**: Optional reverse proxy (controlled by `app_needs_nginx`)
- **Panel registration**: Handles both nginx (baseurl) and no-nginx (urloverride) modes

## Coding Standards

- `set -euo pipefail` + `[[ ]]` + quoted variables + `${1:-}`
- `su - "$user" -c '...'` for user-context commands (uv, git)
- `_reload_nginx` from `lib/nginx-utils.sh`
- Config overwrite guard before writing env.conf
- `chmod 600` for config files with credentials

## Post-Creation Checklist

Per `docs/maintenance-checklist.md`:

- [ ] `swizzin-app-info` APP_CONFIGS entry
- [ ] `backup/swizzin-backup.sh` arrays
- [ ] `backup/swizzin-restore.sh` APP_PATHS
- [ ] `backup/swizzin-excludes.txt`, `backup/README.md`
- [ ] `README.md`, `docs/architecture.md`
