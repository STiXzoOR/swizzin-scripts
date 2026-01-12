# Service Watchdog Design

**Date:** 2026-01-12
**Status:** Approved
**Scope:** Generic watchdog engine + Emby-specific wrapper

## Overview

A cron-based watchdog system that monitors services via process state and HTTP health checks, automatically restarts unhealthy services with cooldown protection, and sends notifications through multiple configurable channels.

## Goals

- Detect when Emby (or other services) crashes or becomes unresponsive
- Automatically restart with rate limiting to prevent thrashing
- Notify via Discord, Pushover, Notifiarr, or email
- Generic engine reusable for Plex, Jellyfin, Sonarr, etc.
- Simple cron-based execution (no daemon to manage)

## File Structure

### Repository Files

```
swizzin-scripts/
├── watchdog.sh              # Generic watchdog engine
├── emby-watchdog.sh         # Emby-specific installer/wrapper
└── configs/
    └── watchdog.conf.example    # Example global config
    └── emby-watchdog.conf.example  # Example Emby config
```

### Runtime Files (Target System)

```
/opt/swizzin/watchdog.sh              # The engine
/opt/swizzin/watchdog.conf            # Global config (notifications, defaults)
/opt/swizzin/watchdog.d/              # Per-service configs
    └── emby.conf
/var/log/watchdog/                    # Logs
    └── emby.log
/var/run/watchdog/                    # State and locks
    ├── emby.state
    └── emby.lock
```

### Cron Entry

```
*/2 * * * * /opt/swizzin/watchdog.sh /opt/swizzin/watchdog.d/emby.conf
```

## Configuration

### Global Config (`/opt/swizzin/watchdog.conf`)

Shared settings across all monitored services:

```bash
# Notifications (leave empty to disable)
DISCORD_WEBHOOK=""
PUSHOVER_USER=""
PUSHOVER_TOKEN=""
NOTIFIARR_API_KEY=""
EMAIL_TO=""

# Default cooldown settings (can be overridden per-service)
DEFAULT_MAX_RESTARTS=3
DEFAULT_COOLDOWN_WINDOW=900      # 15 minutes in seconds
DEFAULT_HEALTH_TIMEOUT=10        # seconds to wait for HTTP response
```

### Per-Service Config (`/opt/swizzin/watchdog.d/emby.conf`)

Service-specific settings:

```bash
# Service identification
SERVICE_NAME="emby-server"          # systemd service name
APP_NAME="Emby"                     # Display name for notifications

# Health check
HEALTH_URL="http://127.0.0.1:8096/emby/System/Info/Public"
HEALTH_TIMEOUT=10                   # seconds (optional, uses default)
HEALTH_EXPECT="ServerName"          # string that must appear in response (optional)

# Cooldown overrides (optional, uses defaults if omitted)
# MAX_RESTARTS=3
# COOLDOWN_WINDOW=900

# File paths (auto-generated based on service name if omitted)
# LOG_FILE="/var/log/watchdog/emby.log"
# STATE_FILE="/var/run/watchdog/emby.state"
```

### State File Format (`/var/run/watchdog/emby.state`)

```bash
RESTART_COUNT=0
RESTART_TIMESTAMPS=""
BACKOFF_UNTIL=""
```

## Watchdog Logic Flow

```
┌─────────────────────────────────────┐
│        Cron triggers script         │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│   Acquire lock (flock) or exit      │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│    Load global + service config     │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│         Load state file             │
└─────────────────┬───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│   Are we in backoff mode?           │
│   (BACKOFF_UNTIL > now)             │
├──────────Yes────┴────────No─────────┤
│                                     │
▼                                     ▼
Check if manual              ┌──────────────────────────────┐
restart occurred ──Yes──►    │  Check 1: Is process running?│
       │                     │  (systemctl is-active)       │
       No                    └───────────┬──────────────────┘
       │                                 │
       ▼                                 ▼
   Log "skipping,            ┌──────────────────────────────┐
   in backoff"               │  Check 2: HTTP health check  │
   Exit 0                    │  (curl + response validation)│
                             └───────────┬──────────────────┘
                                         │
                                         ▼
                             ┌──────────────────────────────┐
                             │       Both checks pass?      │
                             ├─────Yes───────────No─────────┤
                             │                              │
                             ▼                              ▼
                        Log "healthy"          Purge old timestamps
                        Exit 0                 from state file
                                                     │
                                                     ▼
                                          ┌──────────────────┐
                                          │ Count < MAX?     │
                                          ├──Yes───────No────┤
                                          │            │
                                          ▼            ▼
                                     Restart      Set BACKOFF_UNTIL
                                     service      Notify "max restarts,
                                     Wait 10s     giving up"
                                     Verify       Save state
                                     health       Exit 1
                                     Notify
                                     result
                                     Increment
                                     count
                                     Save state
                                     Exit 0/1
```

## Health Check Logic

1. **Process check:** `systemctl is-active --quiet $SERVICE_NAME`
2. **HTTP check:** `curl -sf --max-time $HEALTH_TIMEOUT "$HEALTH_URL"`
3. **Response validation:** If `HEALTH_EXPECT` is set, verify string exists in response

A service is considered **unhealthy** if:
- Process is not running, OR
- HTTP request fails/times out, OR
- HTTP response doesn't contain expected string

## Cooldown Logic

- Track timestamps of each restart in the current window
- Before restarting, purge timestamps older than `COOLDOWN_WINDOW`
- If remaining count >= `MAX_RESTARTS`, enter backoff mode
- Backoff mode: skip all restart attempts, notify once
- Manual restart detection: if service uptime < cooldown window while in backoff, clear backoff and resume

## Notification Events

| Event | Level | Message |
|-------|-------|---------|
| Restart triggered | warning | "⚠️ {APP_NAME} was unhealthy, restarted (attempt {N}/{MAX})" |
| Restart succeeded | info | "✅ {APP_NAME} restarted successfully, health check passed" |
| Restart failed | error | "❌ {APP_NAME} restart failed, service did not come up healthy" |
| Max restarts hit | error | "🛑 {APP_NAME} hit max restarts ({MAX} in {WINDOW}min), giving up until manual intervention" |
| Backoff cleared | info | "ℹ️ {APP_NAME} watchdog resumed after manual restart detected" |

### Notification Function

```bash
_notify() {
    local title="$1"
    local message="$2"
    local level="$3"  # info, warning, error

    [[ -n "$DISCORD_WEBHOOK" ]]   && _notify_discord "$title" "$message" "$level"
    [[ -n "$PUSHOVER_USER" ]]     && _notify_pushover "$title" "$message" "$level"
    [[ -n "$NOTIFIARR_API_KEY" ]] && _notify_notifiarr "$title" "$message" "$level"
    [[ -n "$EMAIL_TO" ]]          && _notify_email "$title" "$message" "$level"
}
```

Notifications are non-blocking — failures are logged but don't prevent restart.

## Emby Wrapper Script (`emby-watchdog.sh`)

### Usage

```bash
bash emby-watchdog.sh              # Interactive setup
bash emby-watchdog.sh --install    # Install watchdog for Emby
bash emby-watchdog.sh --remove     # Remove watchdog for Emby
bash emby-watchdog.sh --status     # Show current status
bash emby-watchdog.sh --reset      # Clear backoff state, resume monitoring
```

### Install Flow

1. Check Emby is installed (`/install/.emby.lock`)
2. Copy `watchdog.sh` to `/opt/swizzin/` if not present
3. Create `/opt/swizzin/watchdog.conf` if not present (prompt for notification settings)
4. Create `/opt/swizzin/watchdog.d/emby.conf`
5. Create `/var/log/watchdog/` and `/var/run/watchdog/` directories
6. Add cron entry via `/etc/cron.d/emby-watchdog`
7. Run initial health check to verify setup

### Status Output

```
Emby Watchdog Status
━━━━━━━━━━━━━━━━━━━━
Service:     emby-server (active)
Health:      http://127.0.0.1:8096/emby/System/Info/Public (OK)
Restarts:    1/3 in current window
Last check:  2 minutes ago
State:       monitoring
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Config file missing | Exit with error, log "config not found" |
| Global config missing | Exit with error, prompt to run setup |
| Service doesn't exist | Exit with error, notify once |
| Health URL unreachable | Treat as unhealthy |
| Health URL returns non-200 | Treat as unhealthy |
| Health URL times out | Treat as unhealthy |
| `HEALTH_EXPECT` string missing | Treat as unhealthy |
| State file corrupted/missing | Recreate with zero counts |
| Cron runs while restart in progress | Lockfile (`flock`) prevents overlap |
| Manual restart detected during backoff | Clear backoff, resume monitoring |
| Notification fails | Log warning, continue with restart |
| `systemctl restart` fails | Log error, count as failed attempt, notify |

## Lockfile Handling

```bash
LOCK_FILE="/var/run/watchdog/${SERVICE_NAME}.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log "Already running, skipping"; exit 0; }
```

## Future Extensibility

Adding a new service (e.g., Plex):

1. Create `plex-watchdog.sh` wrapper (copy/adapt from `emby-watchdog.sh`)
2. Define `HEALTH_URL` for Plex: `http://127.0.0.1:32400/identity`
3. Run `bash plex-watchdog.sh --install`

The generic `watchdog.sh` engine requires no changes.

## Implementation Checklist

- [x] Create `watchdog.sh` (generic engine)
- [x] Create `configs/watchdog.conf.example`
- [x] Create `configs/emby-watchdog.conf.example`
- [x] Create `emby-watchdog.sh` (Emby wrapper)
- [ ] Test on Swizzin system with Emby installed
- [x] Update CLAUDE.md with new scripts
