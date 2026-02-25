---
name: new-subdomain-installer
description: Use when adding subdomain/vhost conversion to an existing Swizzin app. Triggers on "add subdomain support", "subdomain mode for <app>", "dedicated domain", "SSL vhost", plex-style, emby-style, jellyfin-style extended installers.
---

# New Subdomain/Extended Installer

Add subdomain conversion to an existing Swizzin app (subfolder -> dedicated SSL vhost).

## Quick Reference

| What to set | Where | Example |
|---|---|---|
| App identity | `app_name`, `app_port`, `app_protocol` | `plex`, `32400`, `https` |
| Env prefix | Find-and-replace `MYAPP` | `PLEX` |
| swizdb keys | `_get_domain()`, `_prompt_domain()` | `plex/domain` |
| Subfolder config | `_create_subfolder_config()` | `location /plex { ... }` |
| Vhost config | `_create_subdomain_vhost()` | Full SSL server block |

## CLI Pattern

```bash
bash <app>.sh                       # Interactive setup
bash <app>.sh --subdomain           # Convert to subdomain mode
bash <app>.sh --subdomain --revert  # Revert to subfolder mode
bash <app>.sh --register-panel      # Re-register panel urloverride
bash <app>.sh --remove [--force]    # Complete removal
```

## Environment Variables (for automation)

```bash
<APP>_DOMAIN="app.example.com"       # Skip domain prompt
<APP>_LE_HOSTNAME="app.example.com"  # LE hostname (defaults to domain)
<APP>_LE_INTERACTIVE="yes"           # Interactive LE (DNS challenges)
```

## Steps

1. **Copy template**: `cp templates/template-subdomain.sh <app>.sh`
2. **Find-and-replace**: `myapp`->`name`, `Myapp`->`Name`, `MYAPP`->`PREFIX`
3. **Customize**: App variables, domain functions, subfolder config, vhost config, removal cleanup
4. **Test**: interactive, `--subdomain`, `--subdomain --revert`, `--remove`, Organizr integration

## Template Structure

The template at `templates/template-subdomain.sh` provides:

- **`_get_domain()` / `_prompt_domain()`**: Domain management (swizdb + env var)
- **`_prompt_le_mode()`**: Let's Encrypt mode selection
- **`_get_install_state()`**: Returns `not_installed`, `subfolder`, `subdomain`, `unknown`
- **`_install_app()`**: Installs base app via `box install <app>`
- **`_create_subfolder_config()`**: Standard subfolder nginx config (for revert)
- **`_request_certificate()`**: LE cert via `box install letsencrypt`
- **`_create_subdomain_vhost()`**: Full SSL vhost with CSP frame-ancestors for Organizr
- **`_add_panel_meta()` / `_remove_panel_meta()`**: `profiles.py` urloverride
- **`_exclude_from_organizr()` / `_include_in_organizr()`**: SSO integration
- **`_install_subdomain()` / `_revert_subdomain()`**: Conversion flows
- **`_interactive()`**: Interactive mode entry point

## Key Details

- **Organizr CSP**: Vhost includes `frame-ancestors 'self' https://$organizr_domain` when Organizr is configured
- **Backup**: Existing subfolder config backed up to `/opt/swizzin-extras/<app>-backups/`
- **Panel meta**: Creates Python class in `/opt/swizzin/core/custom/profiles.py` with `urloverride`
- **Domain validation**: Must contain `.`, no spaces
- **LE modes**: Non-interactive (HTTP challenge) or interactive (DNS/CloudFlare)

## Coding Standards

- `set -euo pipefail` + `[[ ]]` + quoted variables + `${1:-}` / `${2:-}`
- `_reload_nginx` from `lib/nginx-utils.sh`
- `include snippets/ssl-params.conf` and `include snippets/proxy.conf` in vhosts
- Domain validated before use (prevents injection)

## Post-Creation Checklist

- [ ] `docs/environment-variables.md` - add new env var prefix
- [ ] `README.md`, `docs/architecture.md`
- [ ] Test with and without Organizr
- [ ] Test LE certificate request (both modes)
