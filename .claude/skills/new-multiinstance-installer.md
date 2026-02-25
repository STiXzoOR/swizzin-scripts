---
name: new-multiinstance-installer
description: Use when creating a multi-instance manager for an existing Swizzin app. Triggers on "add multi-instance", "multiple instances of <app>", "sonarr 4k instance", "radarr anime", sonarr-style, radarr-style instance managers.
---

# New Multi-Instance Manager

Manage named instances of an existing Swizzin app (e.g., Sonarr-4K, Radarr-Anime).

## Quick Reference

| What to set | Where | Example |
|---|---|---|
| App identity | `app_name`, `app_pretty`, `app_lockname` | `sonarr`, `Sonarr` |
| Binary path | `app_binary` | `/opt/Sonarr/Sonarr` |
| Base port | `app_base_port` | `8989` |
| Config branch | `app_branch` | `main` |
| Config format | heredoc in `_add_instance()` | XML with `<Port>`, `<UrlBase>` |
| Binary flags | `ExecStart` in `_add_instance()` | `-nobrowser -data=<dir>` |

## CLI Pattern

```bash
bash <app>.sh                     # Install base + add instances interactively
bash <app>.sh --add [name]        # Add a named instance
bash <app>.sh --remove [name]     # Remove instance(s) (whiptail if no name)
bash <app>.sh --remove name --force  # Remove without prompts
bash <app>.sh --list              # List all instances with ports
bash <app>.sh --register-panel    # Re-register all instances
```

## Naming Conventions

| Item | Pattern | Example |
|---|---|---|
| Instance name | Alphanumeric, lowercase | `4k`, `anime`, `kids` |
| Service name | `<app>-<instance>` | `sonarr-4k` |
| Lock file | `/install/.<app>_<instance>.lock` | `.sonarr_4k.lock` (underscore for panel) |
| Config dir | `/home/<user>/.config/<app>-<instance>/` | `.config/sonarr-4k/` |
| Nginx | `/etc/nginx/apps/<app>-<instance>.conf` | `sonarr-4k.conf` |

## Steps

1. **Copy template**: `cp templates/template-multiinstance.sh <app>.sh`
2. **Find-and-replace**: `myapp`->`name`, `Myapp`->`Name`
3. **Customize**: Binary path, config XML/JSON format, systemd ExecStart flags, nginx proxy
4. **Test**: `--add`, `--remove` (interactive + named + `--force`), `--list`, `--register-panel`

## Template Structure

The template at `templates/template-multiinstance.sh` provides:

- **`_validate_instance_name()`**: Alphanumeric check, reserved word check, duplicate check
- **`_get_instances()`**: Discovers instances from lock files
- **`_get_instance_port()`**: Reads port from instance config
- **`_add_instance()`**: Creates config + systemd service + nginx + panel entry
- **`_remove_instance()`**: Full removal with optional config purge
- **`_remove_interactive()`**: Whiptail checklist for multi-select removal
- **`_list_instances()`**: Shows base + all instances with ports
- **`_ensure_base_installed()`**: Installs base via `box install` if missing
- **`_ensure_base_panel_meta()`**: Adds `check_theD = False` to base app panel class

## Key Details

- **Lock files use underscore** (`sonarr_4k`) not hyphen - panel compatibility
- **Each instance gets unique port** via `port 10000 12000`
- **Base app panel override**: Adds `check_theD = False` so panel doesn't conflict
- **Whiptail removal**: Interactive checklist when `--remove` is called without a name
- **Config overwrite guard**: Won't clobber existing `config.xml` on re-add

## Coding Standards

- `set -euo pipefail` + `[[ ]]` + quoted variables + `${1:-}` / `${2:-}`
- Instance names validated before use (prevents injection)
- `_reload_nginx` from `lib/nginx-utils.sh`

## Post-Creation Checklist

- [ ] `docs/apps/multi-instance.md` - add new app
- [ ] `README.md`, `docs/architecture.md`
- [ ] Test: add, remove (all modes), list, panel registration
