# Hetzner Server Bootstrap Design

**Date:** 2026-01-19
**Status:** Approved

## Overview

A bootstrapping script that prepares a fresh Hetzner dedicated server (Ubuntu) for streaming and media management by:

1. Hardening security (SSH, firewall, fail2ban)
2. Tuning kernel for streaming workloads
3. Installing Swizzin
4. Running custom scripts from this repo
5. Configuring notifications

## Target Environment

- **Server:** Hetzner dedicated (Intel Core Ultra 7 265, 64GB DDR5, 2x1TB NVMe RAID1)
- **OS:** Ubuntu 22.04/24.04 LTS
- **Bandwidth:** 1 Gbit/s
- **Use case:** Real-Debrid streaming via Zurg + \*arr apps + Plex/Emby/Jellyfin

## Script Structure

```
bootstrap/
├── bootstrap.sh              # Main entry point
├── lib/
│   ├── common.sh             # Colors, logging, prompts, Pushover helper
│   ├── validation.sh         # OS checks, root check, network
│   ├── hardening.sh          # SSH, fail2ban, UFW
│   ├── tuning.sh             # Kernel/sysctl, limits
│   ├── restore.sh            # Restore defaults
│   ├── apps.sh               # App bundles, script runner, order enforcement
│   └── notifications.sh      # Pushover setup + test
├── configs/
│   ├── sshd-hardening.conf.template
│   ├── sysctl-streaming.conf.template
│   ├── limits-streaming.conf.template
│   ├── fail2ban-jail.local.template
│   └── unattended-upgrades.template
└── README.md                 # Usage docs
```

## Execution Modes

```bash
# One-liner install (downloads and runs)
curl -sL https://raw.githubusercontent.com/.../bootstrap.sh | bash

# Clone and run (for review)
git clone https://github.com/STiXzoOR/swizzin-scripts.git
cd swizzin-scripts/bootstrap
bash bootstrap.sh

# Restore modes
bash bootstrap.sh --restore-ssh
bash bootstrap.sh --restore-tuning
bash bootstrap.sh --restore-all

# Skip phases (advanced)
bash bootstrap.sh --skip-hardening
bash bootstrap.sh --skip-tuning
bash bootstrap.sh --skip-apps
```

## Execution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     BOOTSTRAP START                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. VALIDATION                                                    │
│    • Check root                                                  │
│    • Check Ubuntu 22.04/24.04                                    │
│    • Check network connectivity                                  │
│    • Check not already bootstrapped (idempotent guard)          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. COLLECT CONFIGURATION (all prompts upfront)                   │
│    • SSH: port, public key                                       │
│    • Notifications: Pushover user/token                          │
│    • Apps: bundle or custom selection                            │
│    • Domains: if subdomain apps selected                         │
│    • Secrets: RD token, API keys as needed                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. OS HARDENING                                                  │
│    • Backup existing configs                                     │
│    • Configure SSH (key-only, custom port)                       │
│    • Install & configure fail2ban                                │
│    • Configure UFW (open required ports only)                    │
│    • Configure unattended-upgrades (reboot at 04:00)            │
│    ⚠️  WARNING: Confirm SSH access before proceeding             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. KERNEL TUNING                                                 │
│    • Apply sysctl streaming optimizations                        │
│    • Configure file descriptor limits                            │
│    • Enable BBR congestion control                               │
│    • Apply immediately via sysctl --system                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. SWIZZIN INSTALLATION                                          │
│    • Hand off to official installer (interactive)                │
│    • User selects: username, password                            │
│    • Ensure nginx + panel selected                               │
│    • Wait for completion                                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. CUSTOM APPS (this repo's scripts)                             │
│    Order enforced:                                               │
│    a. Media servers: plex.sh → emby.sh → jellyfin.sh            │
│    b. Arr stack: sonarr.sh → radarr.sh → bazarr.sh → prowlarr   │
│    c. Debrid: zurg.sh → decypharr.sh                            │
│    d. Helpers: huntarr, cleanuparr, byparr, notifiarr, subgen   │
│    e. Watchdog: emby-watchdog.sh --install (if emby)            │
│    f. SSO: organizr.sh (ALWAYS LAST)                            │
│                                                                  │
│    • Export env vars for non-interactive where possible          │
│    • Scripts that must be interactive: run with clear prompts    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 7. NOTIFICATIONS SETUP                                           │
│    • Configure Pushover for system alerts                        │
│    • Hook into unattended-upgrades                               │
│    • Send test notification                                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 8. SUMMARY & NEXT STEPS                                          │
│    • Print installed apps                                        │
│    • Print access URLs                                           │
│    • Print SSH connection info (new port!)                       │
│    • Print credentials reminder                                  │
│    • Create /opt/swizzin-extras/bootstrap.done marker                   │
└─────────────────────────────────────────────────────────────────┘
```

## App Selection & Installation Order

### Preset Bundles

| Bundle     | Apps Installed                                                                 |
| ---------- | ------------------------------------------------------------------------------ |
| Core       | nginx, panel (via Swizzin)                                                     |
| Streaming  | plex.sh, emby.sh, jellyfin.sh (each calls `box install` + optional subdomain)  |
| Arr Stack  | sonarr.sh, radarr.sh, bazarr.sh (multi-instance), prowlarr (via `box install`) |
| Debrid     | zurg.sh, decypharr.sh                                                          |
| Full Stack | All above + notifiarr, huntarr, cleanuparr                                     |
| Custom     | Pick individually                                                              |

### Installation Order (Enforced)

```
Phase 1: Swizzin base
└── curl -sL https://swizzin.ltd/setup.sh | bash
    └── User selects: nginx, panel (minimum)

Phase 2: Media servers (this repo's scripts)
├── plex.sh [--subdomain if wanted]
├── emby.sh [--subdomain if wanted]
└── jellyfin.sh [--subdomain if wanted]
    └── Jellyfin uses port 8097 if emby installed (avoid conflict)

Phase 3: Arr stack (this repo - multi-instance capable)
├── sonarr.sh (prompts for instances)
├── radarr.sh (prompts for instances)
├── bazarr.sh (prompts for instances)
└── box install prowlarr

Phase 4: Debrid stack
├── zurg.sh
└── decypharr.sh

Phase 5: Helpers
├── huntarr.sh, cleanuparr.sh, byparr.sh
├── notifiarr.sh, subgen.sh
└── emby-watchdog.sh --install (if emby)

Phase 6: SSO Gateway (ALWAYS LAST)
└── organizr.sh [--subdomain if wanted]
```

## Custom Scripts Reference

### Simple Installers (no args = install, `--remove` = uninstall)

| Script        | Interactive Prompts   | Env Bypass             |
| ------------- | --------------------- | ---------------------- |
| decypharr.sh  | Mount path            | `DECYPHARR_MOUNT_PATH` |
| notifiarr.sh  | API key               | `DN_API_KEY`           |
| huntarr.sh    | None                  | -                      |
| byparr.sh     | FlareSolverr conflict | -                      |
| cleanuparr.sh | None                  | -                      |
| subgen.sh     | None                  | -                      |

### Complex Installers

| Script           | Arguments                                      | Interactive Prompts                                 | Env Bypass                                                     |
| ---------------- | ---------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------- |
| zurg.sh          | `--switch-version [free\|paid]`                | Version, GitHub token (paid), RD token, mount point | `ZURG_VERSION`, `GITHUB_TOKEN`, `RD_TOKEN`, `ZURG_MOUNT_POINT` |
| emby-watchdog.sh | `--install`, `--remove`, `--status`, `--reset` | Discord, Pushover, Notifiarr, Email                 | -                                                              |

### Subdomain Scripts (`--subdomain`, `--subdomain --revert`, `--remove`)

| Script      | Extra Args                 | Prompts                         | Env Bypass                                   |
| ----------- | -------------------------- | ------------------------------- | -------------------------------------------- |
| plex.sh     | -                          | Domain, LE mode                 | `PLEX_DOMAIN`, `PLEX_LE_INTERACTIVE`         |
| emby.sh     | `--premiere [--revert]`    | Domain, LE mode                 | `EMBY_DOMAIN`, `EMBY_LE_INTERACTIVE`         |
| jellyfin.sh | -                          | Domain, LE mode                 | `JELLYFIN_DOMAIN`, `JELLYFIN_LE_INTERACTIVE` |
| organizr.sh | `--configure`, `--migrate` | Domain, LE mode, app protection | `ORGANIZR_DOMAIN`, `ORGANIZR_LE_INTERACTIVE` |
| seerr.sh    | -                          | Domain, LE mode                 | `SEERR_DOMAIN`, `SEERR_LE_INTERACTIVE`       |

### Multi-Instance Scripts

| Script    | Arguments                                             |
| --------- | ----------------------------------------------------- |
| sonarr.sh | `--add [name]`, `--remove [name] [--force]`, `--list` |
| radarr.sh | `--add [name]`, `--remove [name] [--force]`, `--list` |
| bazarr.sh | `--add [name]`, `--remove [name] [--force]`, `--list` |

## Prerequisites & Script Modifications

### jellyfin.sh Modification Required

Detect emby and shift ports to avoid conflict:

```bash
# At start of script, detect emby
if [[ -f "/install/.emby.lock" ]]; then
    app_port_http="8097"   # Default 8096
    app_port_https="8921"  # Default 8920
    echo_info "Emby detected - Jellyfin will use port $app_port_http to avoid conflict"
else
    app_port_http="8096"
    app_port_https="8920"
fi
```

**Places to update in jellyfin.sh:**

1. Port variables at top
2. Nginx proxy_pass config
3. Subdomain vhost config
4. Any health check URLs
5. Panel registration (if applicable)

## Configuration Collection

Before running anything, bootstrap collects all needed values upfront:

### Phase 1 - System Config

```
- SSH port (default: 22 → suggest 2222 or random)
- SSH public key (paste or path)
- Swizzin master username
- Swizzin master password (or generate)
```

### Phase 2 - Notification Config

```
- Pushover User Key
- Pushover API Token
- (Optional: Discord webhook, email for watchdog)
```

### Phase 3 - App Selection

```
- Preset bundle OR custom selection
- For each media server: subdomain? → domain prompt
- For arr apps: how many instances? (base + names)
- For zurg: free/paid version, RD token, GitHub token (if paid)
```

### Phase 4 - Domain Config (if any subdomain selected)

```
- Base domain (e.g., example.com)
- Individual subdomains auto-suggested:
  - plex.example.com
  - emby.example.com
  - jellyfin.example.com
  - organizr.example.com
```

## OS Hardening

### SSH Hardening

**`/etc/ssh/sshd_config.d/99-hardening.conf`:**

```
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
```

### fail2ban Config

```
- SSH jail enabled
- Ban time: 1 hour (3600s)
- Find time: 10 minutes
- Max retry: 3
```

### UFW Rules

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 32400/tcp comment 'Plex'  # Only if plex selected
ufw enable
```

### Unattended-Upgrades

```
- Security updates: automatic
- Reboot: automatic at 04:00 if required
- Reboot delay: 5 minutes
- Mail notifications: disabled (using Pushover instead)
```

## Kernel Tuning

### Sysctl (`/etc/sysctl.d/99-streaming.conf`)

```bash
# TCP/Network optimization
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Connection tracking (for many streams)
net.netfilter.nf_conntrack_max = 262144

# Memory management
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# File system
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
```

### Limits (`/etc/security/limits.d/99-streaming.conf`)

```bash
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
```

### Systemd (`/etc/systemd/system.conf.d/99-limits.conf`)

```bash
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
```

## Restore Defaults

### Backup Strategy

Before modifying any config, bootstrap backs up originals:

```
/opt/swizzin-extras/bootstrap-backups/
├── ssh/
│   └── sshd_config.original
├── sysctl/
│   └── sysctl.conf.original
├── limits/
│   └── limits.conf.original
└── ufw/
    └── ufw-rules.original
```

### Restore Functions

```bash
_restore_ssh() {
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    # Restore original if backed up, else use distro defaults
    systemctl restart sshd
}

_restore_tuning() {
    rm -f /etc/sysctl.d/99-streaming.conf
    rm -f /etc/security/limits.d/99-streaming.conf
    rm -f /etc/systemd/system.conf.d/99-limits.conf
    sysctl --system
    systemctl daemon-reload
}

_restore_ufw() {
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw enable
}
```

## Notification Integration

### Pushover Helper

```bash
_notify_pushover() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"  # -2 to 2

    [[ -z "$PUSHOVER_USER" || -z "$PUSHOVER_TOKEN" ]] && return 0

    curl -sf -X POST https://api.pushover.net/1/messages.json \
        -d "token=$PUSHOVER_TOKEN" \
        -d "user=$PUSHOVER_USER" \
        -d "title=$title" \
        -d "message=$message" \
        -d "priority=$priority" \
        >/dev/null 2>&1
}
```

### Integration Points

| Event              | Notification                                      |
| ------------------ | ------------------------------------------------- |
| Bootstrap complete | "Server bootstrap complete. SSH on port X"        |
| Reboot scheduled   | "Server will reboot at 04:00 for updates"         |
| Reboot completed   | "Server rebooted successfully" (via cron @reboot) |
| Service failure    | Via watchdog (already configured)                 |

### Unattended-Upgrades Hook

**`/etc/apt/apt.conf.d/99-pushover`:**

```
Dpkg::Pre-Install-Pkgs {"/opt/swizzin-extras/notify-updates.sh";};
```

## Files Created

| Location                          | Purpose                 |
| --------------------------------- | ----------------------- |
| `/opt/swizzin-extras/bootstrap-backups/` | Original config backups |
| `/opt/swizzin-extras/bootstrap.conf`     | Saved configuration     |
| `/opt/swizzin-extras/bootstrap.done`     | Completion marker       |
| `/opt/swizzin-extras/notify-updates.sh`  | Pushover hook for apt   |

## Implementation Checklist

- [ ] Modify jellyfin.sh to use port 8097/8921 when emby is installed
- [ ] Create bootstrap/ directory structure
- [ ] Implement lib/common.sh (colors, logging, prompts)
- [ ] Implement lib/validation.sh (OS checks, root, network)
- [ ] Implement lib/hardening.sh (SSH, fail2ban, UFW)
- [ ] Implement lib/tuning.sh (sysctl, limits)
- [ ] Implement lib/restore.sh (restore defaults)
- [ ] Implement lib/apps.sh (bundles, script runner)
- [ ] Implement lib/notifications.sh (Pushover)
- [ ] Create config templates
- [ ] Implement bootstrap.sh main script
- [ ] Create README.md with usage docs
- [ ] Test on fresh Hetzner Ubuntu 24.04
