# Multi-Instance Scripts (Sonarr/Radarr)

sonarr.sh and radarr.sh manage multiple named instances of Sonarr/Radarr.

## Usage

```bash
sonarr.sh                      # Install base if needed, then add instances interactively
sonarr.sh --add [name]         # Add a named instance (e.g., 4k, anime, kids)
sonarr.sh --remove [name]      # Remove instance(s) - interactive if no name
sonarr.sh --remove name --force # Remove without prompts, purge config
sonarr.sh --list               # List all instances with ports
```

## Naming Convention

| Component  | Pattern                               | Example                          |
| ---------- | ------------------------------------- | -------------------------------- |
| Service    | `sonarr-<name>.service`               | `sonarr-4k.service`              |
| Config dir | `/home/<user>/.config/sonarr-<name>/` | `/home/user/.config/sonarr-4k/`  |
| Nginx      | `/etc/nginx/apps/sonarr-<name>.conf`  | `/etc/nginx/apps/sonarr-4k.conf` |
| URL path   | `/sonarr-<name>/`                     | `/sonarr-4k/`                    |
| Lock file  | `/install/.sonarr-<name>.lock`        | `/install/.sonarr-4k.lock`       |

## Instance Name Validation

- Alphanumeric only (a-z, 0-9), converted to lowercase
- Checked against existing lock files for uniqueness
- Reserved words blocked: "base"

## Port Allocation

Dynamic via `port 10000 12000` (not the base port).

## App Differences

| Variable        | Sonarr             | Radarr             |
| --------------- | ------------------ | ------------------ |
| `app_binary`    | /opt/Sonarr/Sonarr | /opt/Radarr/Radarr |
| `app_base_port` | 8989               | 7878               |
| `app_branch`    | main               | master             |

## Base App Protection

The base instance cannot be removed via these scripts. Remove all additional instances before running `box remove sonarr/radarr`.
