# Service Watchdog

A cron-based monitoring system that checks service health and automatically restarts unhealthy services with cooldown protection.

## Directory Structure

```
watchdog/
├── watchdog.sh               # Generic watchdog engine
├── emby-watchdog.sh          # Emby-specific installer/manager
└── configs/
    ├── watchdog.conf.example       # Global config template
    └── emby-watchdog.conf.example  # Emby config template
```

## Usage

```bash
bash watchdog/emby-watchdog.sh              # Interactive setup
bash watchdog/emby-watchdog.sh --install    # Install watchdog for Emby
bash watchdog/emby-watchdog.sh --remove     # Remove watchdog for Emby
bash watchdog/emby-watchdog.sh --status     # Show current status
bash watchdog/emby-watchdog.sh --reset      # Clear backoff state, resume monitoring
```

## How It Works

1. Cron runs `watchdog.sh` every 2 minutes
2. Checks if process is running (`systemctl is-active`)
3. Checks HTTP health endpoint (`curl` + response validation)
4. If unhealthy, restarts service (max 3 restarts per 15 minutes)
5. Sends notifications via Discord, Pushover, Notifiarr, or email
6. Enters backoff mode if max restarts reached

## Runtime Files

| File                                       | Purpose                                 |
| ------------------------------------------ | --------------------------------------- |
| `/opt/swizzin-extras/watchdog.sh`          | Engine script                           |
| `/opt/swizzin-extras/watchdog.conf`        | Global config (notifications, defaults) |
| `/opt/swizzin-extras/watchdog.d/emby.conf` | Emby-specific config                    |
| `/var/log/watchdog/emby.log`               | Log file                                |
| `/var/run/watchdog/emby.state`             | State (restart counts, backoff)         |
| `/etc/cron.d/emby-watchdog`                | Cron job                                |

## Adding New Services

Create a new wrapper script (copy `watchdog/emby-watchdog.sh`) and adjust:

- `SERVICE_NAME` - systemd service name
- `HEALTH_URL` - HTTP endpoint to check
- `HEALTH_EXPECT` - Expected response (string match)
