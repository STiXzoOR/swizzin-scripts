---
name: new-docker-installer
description: Use when creating a Swizzin installer for a Docker Compose app with systemd wrapper. Triggers on "add docker app", "new docker-compose installer", "containerized app", lingarr-style, libretranslate-style scripts.
---

# New Docker Installer

Create a Swizzin installer for a Docker Compose app (`/opt/<app>/docker-compose.yml` + systemd oneshot).

## Quick Reference

| What to set | Where | Example |
|---|---|---|
| App identity | `app_name`, `app_pretty` | `lingarr`, `Lingarr` |
| Docker image | `app_image` | `lingarr/lingarr:latest` |
| Container port | `app_container_port` | `8080` |
| Host port | `app_port` (auto-persisted in swizdb) | `$(port 10000 12000)` |
| Env vars | compose generation in `_install_*()` | `TZ`, API keys |
| Volumes | compose generation in `_install_*()` | config dir, media dirs |
| Resource limits | env vars or defaults | `DOCKER_CPU_LIMIT=4` |
| Icon | `app_icon_url` | `https://cdn.jsdelivr.net/...` |

## Steps

1. **Copy template**: `cp templates/template-docker.sh <app>.sh`
2. **Find-and-replace**: `myapp`->`name`, `Myapp`->`Name`
3. **Customize** all `# CUSTOMIZE:` sections (5 locations: image, env vars, volumes, nginx, discovery)
4. **Test**: install, `--update`, `--remove`, re-install (port persistence)

## Key Differences from Other Templates

- **Docker auto-install**: `_install_docker()` handles Docker Engine + Compose plugin
- **Port persistence**: `swizdb set/get "${app_name}/port"` keeps port across re-runs
- **Systemd oneshot**: `Type=oneshot`, `RemainAfterExit=yes`, wraps `docker compose up/down`
- **Resource limits**: Both Docker deploy limits and systemd limits (configurable via env vars)
- **No rollback**: `docker compose pull` + `up -d` is already atomic per image tag
- **Update**: Pull latest + recreate + `docker image prune -f`
- **Bind to localhost**: `127.0.0.1:$port:$container_port` (never `0.0.0.0`)
- **Docker apt-get**: Uses `apt-get` directly (not `apt_install`) because Docker post-install triggers confuse Swizzin

## When App Lacks Base URL Support

Use nginx `sub_filter` to rewrite paths:

```nginx
sub_filter_once off;
sub_filter_types text/html text/css text/javascript application/javascript;
sub_filter 'href="/' 'href="/${app_baseurl}/';
sub_filter 'src="/' 'src="/${app_baseurl}/';
proxy_set_header Accept-Encoding "";
```

See `lingarr.sh` or `zurg.sh` for working examples.

## Template Structure

The template at `templates/template-docker.sh` provides:

- **`_install_docker()`**: Docker Engine + Compose from official repo
- **`_install_*()`**: Generate docker-compose.yml, pull image, start container
- **`_update_*()`**: Pull latest, recreate, prune dangling images
- **`_systemd_*()`**: Oneshot wrapper with resource limits (MemoryMax, CPUQuota, TasksMax)
- **`_nginx_*()`**: Reverse proxy with WebSocket support + API bypass
- **`_remove_*()`**: Compose down, rmi, clean up systemd/nginx/panel

## Coding Standards

- `set -euo pipefail` + `[[ ]]` + quoted variables + `${1:-}`
- Port persisted: `swizdb set "${app_name}/port" "$app_port"`
- `_reload_nginx` from `lib/nginx-utils.sh`
- Containers bind to `127.0.0.1` only

## Post-Creation Checklist

Per `docs/maintenance-checklist.md`:

- [ ] `swizzin-app-info` APP_CONFIGS entry
- [ ] `backup/swizzin-backup.sh` arrays
- [ ] `backup/swizzin-restore.sh` APP_PATHS
- [ ] `backup/swizzin-excludes.txt`, `backup/README.md`
- [ ] `README.md`, `docs/architecture.md`
