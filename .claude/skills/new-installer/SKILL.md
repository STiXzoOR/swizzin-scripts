---
name: new-installer
description: "This skill should be used when creating a new Swizzin installer script from one of the five standard templates (binary, python/uv, docker, subdomain, multi-instance). It guides through template selection, app-specific customization, and post-creation checklist items. Triggers on requests like 'create a new installer', 'add a binary app', 'scaffold a docker installer', 'new python app', 'add multi-instance support', or 'create subdomain script'."
---

# New Installer

Scaffold a production-ready Swizzin installer script from the project's
standard templates, ensuring all coding standards and conventions are followed.

## Template Types

| Template | Use Case | Reference File |
| --- | --- | --- |
| **binary** | Single binary from GitHub releases to `/usr/bin` | `references/template-binary.sh` |
| **python** | Python app using uv for dependency management | `references/template-python.sh` |
| **docker** | Docker Compose app with systemd wrapper | `references/template-docker.sh` |
| **subdomain** | Extended installer with subdomain/subfolder toggle | `references/template-subdomain.sh` |
| **multiinstance** | Named instances of an existing Swizzin base app | `references/template-multiinstance.sh` |

## Workflow

### 1. Gather Requirements

Ask the user for the following (skip items not applicable to the chosen
template type):

**All templates:**
- App name (lowercase, no hyphens preferred for lock files)
- Pretty name (capitalized display name)
- Brief description (for systemd unit and comments)

**Binary template:**
- GitHub `owner/repo`
- Architecture mapping (what the release calls amd64/arm64/armhf)
- Archive format (tar.gz, zip, etc.)
- Config file format and location
- Default port (or use `port 10000 12000`)

**Python template:**
- GitHub repo URL (for `git clone`)
- Python entry point (e.g., `main.py`, `app.py`)
- Whether it needs nginx (some are internal-only services)
- Default port or fixed port (e.g., 8191 for FlareSolverr compat)
- Environment variables for `env.conf`

**Docker template:**
- Docker image (e.g., `myapp/myapp:latest`)
- Container port (what the app listens on inside the container)
- Environment variables for `docker-compose.yml`
- Volume mounts beyond the config directory
- Resource limits (or accept defaults: 4 CPU, 4G RAM)

**Subdomain template:**
- App port and protocol (http/https backend)
- Environment variable prefix (e.g., `MYAPP_`)
- Whether the app is installed via `box install` or custom
- Subfolder nginx config specifics
- Subdomain vhost specifics (additional location blocks, headers)

**Multi-instance template:**
- Base app binary path
- Base app default port
- Config file format (XML, JSON, etc.)
- Config branch (main/master)
- ExecStart command format

**All templates also need:**
- Panel icon URL (or "placeholder" for apps without logos)
- Any app-specific dependencies (`app_reqs` array)

### 2. Read the Template

Read the appropriate reference file to load the full template into context:

- `references/template-binary.sh`
- `references/template-python.sh`
- `references/template-docker.sh`
- `references/template-subdomain.sh`
- `references/template-multiinstance.sh`

Also read `references/coding-standards.md` to ensure compliance.

### 3. Generate the Script

Create the new script file at the project root (e.g., `/opt/swizzin-scripts/myapp.sh`).

**Replacement rules** — apply throughout the generated file:
- `myapp` → app name (lowercase)
- `Myapp` → pretty name (capitalized)
- `MYAPP` → environment variable prefix (uppercase, subdomain template only)
- `owner/repo` → actual GitHub owner/repo
- All `# CUSTOMIZE:` comments → replace with actual values or remove the
  comment once the section is fully resolved

**Critical conventions to follow** (full details in
`references/coding-standards.md`):
- `set -euo pipefail` at the top
- `${1:-}` / `${2:-}` for all positional parameters (never bare `$1`)
- `[[ ]]` for all conditionals (never `[ ]`)
- All variables quoted: `"$var"`, `"${var}"`
- `mktemp` for temporary files (no hardcoded `/tmp` paths)
- Config overwrite guards (don't clobber existing configs on re-run)
- `_reload_nginx` from `lib/nginx-utils.sh` (never bare `systemctl reload nginx`)
- Local-first panel helper loading (no GitHub download fallback)
- Lock file check before install, create after success
- `chmod 600` for credential files
- `curl --config <(printf ...)` for API keys (hides from `ps`)

**Function naming pattern:** `_<action>_<appname>()` (e.g., `_install_seerr`,
`_systemd_notifiarr`)

### 4. Walk Through Customization Points

After generating the base script, review each section that was marked
`# CUSTOMIZE:` in the original template and confirm the values are correct:

1. **App variables** — name, port, binary URL, icon
2. **Architecture mapping** — verify release naming conventions match the
   GitHub release assets
3. **Config file format** — JSON, XML, YAML, env, dotenv, etc.
4. **Systemd service** — ExecStart, WorkingDirectory, EnvironmentFile
5. **Nginx config** — proxy_pass, auth_basic, WebSocket headers, sub_filter
   (for apps without base_url support)

### 5. Post-Creation Checklist

After the script is created, read `references/maintenance-checklist.md` and
present the required follow-up tasks:

- [ ] **Update `swizzin-app-info`** — Add entry to `APP_CONFIGS` dict with
  config_paths, format, and keys. Then copy to installed location:
  `cp swizzin-app-info /usr/local/bin/swizzin-app-info`
- [ ] **Update backup system** — Add to all three files:
  - `backup/swizzin-backup.sh`: `SERVICE_TYPES`, `SERVICE_STOP_ORDER`,
    `SERVICE_STOP_CRITICAL` (if SQLite), header comment
  - `backup/swizzin-restore.sh`: `APP_PATHS`, `SERVICE_TYPES`
  - `backup/swizzin-excludes.txt`: exclusion patterns for logs, caches,
    docker-compose.yml (recreated by installer), reinstallable code
  - Then copy all three to installed locations:
    `cp backup/swizzin-backup.sh /usr/local/bin/swizzin-backup.sh`
    `cp backup/swizzin-restore.sh /usr/local/bin/swizzin-restore.sh`
    `cp backup/swizzin-excludes.txt /etc/swizzin-excludes.txt`
- [ ] **Update `backup/README.md`** — Add to Supported Applications table
- [ ] **Update `README.md`** — Add to Available Scripts table
- [ ] **Update `docs/architecture.md`** — Add to Files Overview table
- [ ] **Update `docs/apps/docker-apps.md`** — If Docker-based, add file
  layout and features section
- [ ] **Test the script** — Verify install, `--update`, `--remove`, and
  rollback behavior

Offer to help with each item.

## Reference Notes

- **Port allocation:** Most apps use `port 10000 12000`; some need fixed ports
  for compatibility (Byparr=8191, Zurg=9999)
- **Panel icons:** Use
  `https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/<app>.png` when
  available, or `"placeholder"` for apps without logos
- **Python apps:** uv installed per-user at `~/.local/bin/uv`, run via
  `uv run python <entry>.py`
- **Docker apps:** Systemd uses `Type=oneshot` + `RemainAfterExit=yes`
  wrapping `docker compose up -d` / `docker compose down`
- **Multi-instance:** Lock files use underscore (`app_name`) not hyphen
  (`app-name`) for panel compatibility
- **Subdomain scripts:** Use `[ ]` single brackets (POSIX style) since they
  invoke `box install` which may source POSIX-only scripts — this is the ONE
  exception to the `[[ ]]` rule
