---
title: "refactor: Migrate decypharr installer to v2 (Fenrir)"
type: refactor
status: draft
date: 2026-04-19
fork: https://github.com/STiXzoOR/decypharr
upstream: https://github.com/sirrobot01/decypharr
current_pin: STiXzoOR/decypharr v1.2.8 (upstream v1.1.6 + URLBase fix + 26 other commits)
target_pin: STiXzoOR/decypharr v2.2-swizzin (upstream v2.2 + URLBase fix + DebridLink nil-map fix)
---

# refactor: Migrate decypharr installer to v2 (Fenrir)

## TL;DR

Upstream `sirrobot01/decypharr` shipped **v2.0 (2026-04-09)**, **v2.1 (2026-04-15)**, and **v2.2 (2026-04-18)** — the "Fenrir" rewrite: new DFS mount engine, Usenet/Sabnzbd support, setup wizard, reworked repair pipeline, new mount-type abstraction, massive config schema shake-up. Our installer is pinned to our fork at `v1.2.8` (January), which is ~370 commits behind upstream.

Plan: **rebase our fork onto upstream v2.2 and carry only the 3 commits that still matter** — 2 URLBase fixes (bug *still present* in v2) and 1 DebridLink nil-map panic fix (bug *still present* in v2). Every other fork commit is either already in v2, was upstreamed, or targets a file that no longer exists after the rewrite. Tag as `v2.2-swizzin`, and update `decypharr.sh` to the v2 config schema.

Existing installs upgrade cleanly via v2's built-in backward-compat migration (qBitTorrent → Manager, Rclone → Mount) on first startup — our `--update` path just swaps the binary.

## Research Summary (gathered for this plan)

### Per-commit audit of the fork vs v2

The fork has **29 fork-only commits** across `main` and several feature/fix branches. Each was checked against v2.2 source — kept only when the bug still exists or the feature isn't present upstream.

**Keep (2 code commits):**

| SHA (branch) | What it does | v2.2 state | Decision |
|---|---|---|---|
| `207e35b` (fix/urlbase-reverse-proxy) | Wraps 8 `http.Redirect(w, r, "/...", ...)` calls with a `redirectTo()` helper that prepends URLBase | Bug persists in `pkg/server/{auth,middlewares,ui,setup}.go` — and v2 added a **new 9th redirect site** in `setup.go:52`, plus 2 new ones in `middlewares.go` (for the setup-redirect flow). 10 total redirect sites, up from 8 in v1 | **KEEP, re-port to v2 paths** |
| `32b2a61` (fix/urlbase-reverse-proxy) | Trims trailing slash off `cfg.URLBase` before `r.Route(...)` in `pkg/server/server.go` to work around `StripSlashes` middleware | Bug persists at `pkg/server/server.go:134` — exact same code pattern | **KEEP** |
| `2c1db93` (main) | Initializes `Files: make(map[string]types.File)` in DebridLink `GetTorrent()` to prevent "assignment to entry in nil map" panic | Bug persists at `pkg/debrid/providers/debridlink/debrid_link.go:184-207` — struct literal omits `Files`, then writes `torrent.Files[file.Name] = file` on what is still a nil map | **KEEP** |

**Drop (all other fork commits):**

| Commit(s) | Why already handled in v2 |
|---|---|
| `11d246e`, `4533a2a`, `1ea604d` (docs + nginx examples, Zurg guide) | Docs-only; upstream v2 rebuilt the whole docs site on Astro/Starlight — these would be churn |
| `9418514`, `e6f91b5`, `674f294` (CLAUDE.md updates, `.worktrees/` in gitignore) | Fork-internal workflow notes, not shipped behavior |
| `85324b3`, `48e4626`, `1837699`, `26cadcc`, `9ceb5f0` (Zurg PRs #2–6: rate limit, HTTP client, HEAD, URL encoding, repair FP) | v2 **dropped `repair.zurg_url` entirely** — the code paths these patched (`checkZurg`, `getZurgBrokenFiles`) don't exist after the repair-v2 rewrite |
| `ab6a0d2`, `e95e053` ("repair worker false positives for Zurg users"), `1a46709` (revert) | Same — repair pipeline rewritten, Zurg-specific branches gone |
| `14f6fa2` (repair worker: I/O detection, mount checks, Arr overwriting), `6502500` (repair preRunChecks body close), `0a5728b` (repair UI progress) | Repair was **fully rewritten** in v2 ("Repair v2, queue-based imports, browse-driven repair actions"). The underlying functions no longer exist |
| `0beba6b` (rclone status UI), `899a6f7` (torrent search modal), `8ed52c2` (config import/export), `ecb7031` (rebuilt frontend assets) | v2 "Expanded the server and UI significantly with a first-run setup wizard, browse page, global stats, revamped config/download/repair pages, richer APIs". All UI work is superseded — any port would fight the new asset pipeline |
| `838dd19` (GetAvailableSlots for DL/AD/TB) | v2 has `GetAvailableSlots` on all 4 providers: `pkg/debrid/providers/{debridlink,alldebrid,torbox,realdebrid}` all implement it |
| `19a891c` (UnpackRar + sample filtering on DL/AD) | `UnpackRar` field is in v2's config struct (`internal/config/debrid.go:19`). DL/AD already call `cfg.IsFileAllowed(...)` for sample/extension filtering (`debrid_link.go:196,257,558`; `alldebrid.go:213,420`). Actual RAR unpack code exists only for RD in both v1 and v2 — parity was a config-only change, not a real feature gap |
| `7bab4d6` (TorBox permalinks via `redirect=true`) | v2 already uses the permalink pattern: `query.Set("redirect", "true")` at `pkg/debrid/providers/torbox/torbox.go:457`. Upstream adopted the same fix |
| `9530d8c` (Real-Debrid error variable shadowing) | v2 refactored both `GetProfile()` and `GetAvailableSlots()` to use the `doGet` helper — the raw `json.Unmarshal(resp, &data) != nil` pattern is gone |
| `7b35da7` (HTTP response body leaks in arr package) | v2 centralized arr HTTP calls through `a.Request()` (`pkg/arr/arr.go:79`) which defers body close inside the helper. All `searchSonarr`/`searchRadarr`/`batchDeleteFiles`/`GetMedia`/`GetMovies` paths now go through it |
| `fad91f8` (download link retry returning empty on success) | File `pkg/debrid/store/download_link.go` no longer exists. Retry logic moved to `pkg/debrid/account/manager.go`'s `GetDownloadLink` — now retries **across accounts** instead of same-account, so the specific bug is gone |
| `deploy:*`, `CNAME`, `Deployed … with MkDocs` | GitHub Pages deployment artifacts from fork's doc site — don't follow to v2 |

### Net result

**From 29 fork-only commits → 3 to carry forward.** The other 26 were either upstreamed, superseded by v2's rewrite, or targeted code paths that no longer exist.

### What v2 changes that affect us

| Area | v1 (today) | v2 | Impact |
|---|---|---|---|
| Config root section `repair` (zurg_url, interval, workers, strategy) | Used | **Removed** entirely — no `ZurgURL` field anywhere in v2 codebase | Drop from our generated config |
| Debrid `use_webdav` | Used | **Removed** — webdav routing is now controlled via `mount.type` and top-level `enable_webdav_auth` | Drop |
| Debrid `folder` | Required | Deprecated but still migrated (derives `mount.mount_path` from `dirname`) | Keep writing it; harmless |
| Root `rclone: {...}` | Required for rclone mount | Deprecated — auto-migrated to `mount: {type: "rclone", rclone: {...}}` on first load | Switch to new schema to stop tripping migration warnings |
| Root `qbittorrent: {download_folder, refresh_interval}` | Used | Deprecated — auto-migrated to root-level `download_folder`, `refresh_interval` (string "30s") | Switch to new schema |
| Mount types | Implicit: rclone-or-none | Explicit: `dfs` / `rclone` / `external_rclone` / `none` | Add explicit `mount.type` |
| Setup wizard | None | New `/setup` page that fires if `Validate()` fails: no debrid+usenet, empty api_key, empty download_folder | Our pre-populated config has api_key="" for non-zurg path — wizard will fire. For zurg path it won't. **Keep this behavior** — user configures via UI either way |
| API token | Guessed/none | Generated into `$config_dir/auth.json` on first start when `use_auth=true` | `swizzin-app-info` key `apikey` needs to read from `auth.json.api_token`, not from `config.json` (never worked anyway — wrong case and wrong file) |
| Usenet | None | New — Sabnzbd-compatible API at `/sabnzbd/api` | Optional new nginx location; not required unless user wants Usenet |
| armv6 binary | Released | **Dropped** from v2 asset list | Our `armhf` arch case will find no asset — installer should error clearly. amd64/arm64 unaffected |
| `/debug` endpoints | Open | Now behind auth middleware | None — we don't hit them |
| Binary flag | `--config=/path` | `--config=/path` | Unchanged |
| Tarball layout | Single `decypharr` binary at root | Single `decypharr` binary at root | Unchanged |
| Log path | `~/.config/Decypharr/logs/decypharr.log` | `~/.config/Decypharr/logs/decypharr.log` | Watchdog unchanged |
| Error string our watchdog matches | `"no debrid clients available"` | Still present (`pkg/manager/processor.go:329`) | Watchdog unchanged |

### The URLBase bug is still present in v2

File/line moves: `pkg/web/*.go` → `pkg/server/*.go`. Bug persists in:

| File | Redirect sites to patch |
|---|---|
| `pkg/server/server.go` L134 | Route trim (same fix as `32b2a61`) |
| `pkg/server/auth.go` | 1 (same as v1) |
| `pkg/server/middlewares.go` | 3 (2 prior + **new** setup-redirect at L98) |
| `pkg/server/ui.go` | 4 (same set as v1) |
| `pkg/server/setup.go` | 1 (**new file in v2** — setup wizard complete → `/`) |

**Total: 10 redirect call sites** to re-patch (vs 8 in v1) + 1 route trim. Same pattern: introduce a `s.redirectTo(w, r, path)` helper that prepends `s.urlBase` (the field already exists — v2 added it at `pkg/server/server.go:80` for its own templating). The v1 fork patch will NOT cherry-pick cleanly; it needs manual re-application.

## Open Decisions (confirm before execution)

1. **Fork rebase strategy**. Recommendation: drop fork-main's 28 feature commits; start a fresh `v2.2` branch from upstream tag, apply the 3-ish URLBase commits on top, tag `v2.2-urlbase-fix`. Release-only, not main. **Alternative:** keep fork main tracking upstream main verbatim and maintain a separate `patches/urlbase` branch — cleaner but more release-dance work. Going with option A below unless you push back.
2. **Adopt DFS mount for non-zurg users?** v2's new default is rclone for backward compat. DFS claims better streaming/startup but requires disk cache sizing. **Recommendation**: keep `mount.type: "rclone"` for parity with v1 behavior. Users can switch in UI if they want. Revisit after real-world reports land.
3. **Add Usenet/Sabnzbd nginx route?** Not required. **Recommendation**: add it behind a no-op — i.e. emit the `/sabnzbd` location block regardless (proxy only — no extra routes visible to users who haven't enabled Usenet). Cheap, future-proofs. Alternative: omit; users on Usenet can add manually.
4. **`--update` config rewrite?** Current `--update` is binary-only (config untouched). **Recommendation**: keep binary-only. v2 auto-migrates legacy schema on startup and persists via `Save()`. The rewritten config will *add* the new `mount.*` and `download_folder` keys and *leave* the deprecated `qbittorrent`/`rclone` blocks in place (v2 doesn't delete them). That's fine — they get ignored after the first migration pass.
5. **`--update --full` config regeneration?** `--full` already re-runs `_install_decypharr` which rewrites `config.json`. **Recommendation**: have `--full` emit the *new* v2 schema so users can opt into the cleaner config by running `--full`. Preserves their api_key + mount_path from swizdb; overwrites schema.

## Plan

### Step 1 — Clean up the fork (`STiXzoOR/decypharr`)

Goal: fork carries `upstream/v2.2` + exactly 3 code patches.

1. From the clone at `/root/decypharr-migration/fork/` (`upstream` remote already added, tags fetched):
   - `git switch --detach upstream/v2.2 && git switch -c v2.2-swizzin`
   - **Patch 1 — URLBase route trim** (was `32b2a61`, re-port):
     - `pkg/server/server.go:134`: before `r.Route(cfg.URLBase, ...)`, assign `urlBase := cfg.URLBase; if urlBase != "/" { urlBase = strings.TrimSuffix(urlBase, "/") }`, then `r.Route(urlBase, ...)`.
   - **Patch 2 — URLBase-aware redirects** (was `207e35b`, re-port + expand):
     - In `pkg/server/server.go`, add method on `*Server`:
       ```go
       func (s *Server) redirectTo(w http.ResponseWriter, r *http.Request, path string) {
           target := strings.TrimSuffix(s.urlBase, "/") + path
           http.Redirect(w, r, target, http.StatusSeeOther)
       }
       ```
       (`s.urlBase` is already populated at `server.go:122`; no new field needed.)
     - Replace **10** `http.Redirect(w, r, "/...", http.StatusSeeOther)` call sites with `s.redirectTo(w, r, "/...")`:
       - `pkg/server/auth.go:43` — `/`
       - `pkg/server/middlewares.go:28` — `/register`
       - `pkg/server/middlewares.go:47` — `/login`
       - `pkg/server/middlewares.go:98` — `/setup` *(new in v2)*
       - `pkg/server/ui.go:15` — `/register`
       - `pkg/server/ui.go:49` — `/`
       - `pkg/server/ui.go:64` — `/login`
       - `pkg/server/ui.go:118` — `/`
       - `pkg/server/setup.go:52` — `/` *(new file in v2)*
     - Note: only touch SeeOther redirects. Leave the existing `http.Error`/`http.Redirect` on absolute external URLs alone.
   - **Patch 3 — DebridLink nil-map panic** (was `2c1db93`):
     - `pkg/debrid/providers/debridlink/debrid_link.go`, inside `GetTorrent()` (around line 184): add `Files: make(map[string]types.File),` to the `&types.Torrent{...}` struct literal. This matches the pattern already used in `getTorrents()` at line 551 and in the other three providers.
2. Validate:
   - `go build ./...`
   - `go vet ./...`
   - Smoke test by running with `"url_base": "/decypharr/"`: `curl -sI http://127.0.0.1:PORT/decypharr/` should emit `Location: /decypharr/login` (bug repro today gives `/login`). `curl /decypharr/setup` should serve the wizard page. With DebridLink configured, hitting `/decypharr/api/v2/torrents/info?hash=...` should not panic.
3. Tag and release:
   - `git tag -a v2.2-swizzin -m "upstream v2.2 + URLBase reverse-proxy fix + DebridLink nil-map fix"`
   - `git push origin v2.2-swizzin`
   - Run upstream's release workflow on the tag (fork inherits the GoReleaser config from `.github/workflows/`). **Asset names must match upstream** (`decypharr_Linux_x86_64.tar.gz`, `decypharr_Linux_arm64.tar.gz`) so the installer's existing `grep "Linux_$arch"` logic works unchanged.
4. Force-reset fork `main` to `upstream/main` — discard the 26 obsolete diverged commits. (Feature branches on origin can be left or deleted; they're dead.) This makes "latest upstream + 3 Swizzin patches" reproducible: for each new upstream release, `git switch upstream/vX.Y`, re-apply the 3 patches (they're stable — only 5 files touched), retag `vX.Y-swizzin`, release.
5. (Nice-to-have) open upstream PRs for Patches 1+2 (URLBase fix is a real reverse-proxy bug that affects every user on a subfolder deploy) and Patch 3 (panic). If accepted, the fork can retire.

### Step 2 — Rewrite `decypharr.sh` config generation for v2 schema

Replace the `config.json` heredoc in `_install_decypharr` (lines 268–393) with v2 layout. Key differences:

```json
{
  "url_base": "/decypharr/",
  "port": "$app_port",
  "log_level": "info",
  "use_auth": false,

  "debrids": [
    {
      "provider": "realdebrid",            // NEW in v2 — was implicit via name
      "name": "realdebrid",
      "api_key": "$rd_api_key",
      "download_api_keys": ["$rd_api_key"],
      "folder": "$rd_folder",              // deprecated but still migrated
      "rate_limit": "250/minute",
      "minimum_free_slot": 1,
      "torrents_refresh_interval": "15s",
      "download_links_refresh_interval": "40m",
      "workers": 600,
      "auto_expire_links_after": "3d"
      // removed: use_webdav (gone in v2)
      // removed: folder_naming (moved to root)
    }
  ],

  "download_folder": "$app_mount_path/symlinks/downloads",   // NEW top-level, was qbittorrent.download_folder
  "refresh_interval": "5s",                                  // was qbittorrent.refresh_interval (int seconds) → now Go duration string
  "folder_naming": "filename",                               // moved from per-debrid
  "categories": ["sonarr", "radarr"],
  "default_download_action": "symlink",

  "mount": {                                                 // NEW — replaces root rclone block
    "type": "$mount_type",                                   // "rclone" for non-zurg, "none" for zurg
    "mount_path": "$app_mount_path",
    "rclone": { /* only populated when type=rclone */
      "port": "5572",
      "vfs_cache_mode": "full",
      "vfs_cache_max_size": "256G",
      "vfs_cache_max_age": "72h",
      "vfs_cache_poll_interval": "1m",
      "vfs_read_ahead": "1G",
      "vfs_fast_fingerprint": true,
      "buffer_size": "256M",
      "transfers": 8,
      "dir_cache_time": "1h",
      "attr_timeout": "15s",
      "no_modtime": true,
      "no_checksum": true,
      "log_level": "INFO"
    }
  },

  "allowed_file_types": [ /* unchanged — v2 still reads AllowedExt at root */ ],
  "allow_samples": false,

  "notifications": { "enabled": false }   // optional — primes the UI
  // removed: repair {} — v2 dropped ZurgURL entirely
}
```

Changes by branch:
- **Zurg detected path** (`zurg_mount != ""`): `mount.type = "none"`, omit `mount.rclone`, keep `debrids[0].folder = "$zurg_mount/__all__/"`. v2 won't auto-mount anything, zurg handles mount externally — identical effective behavior to our current `rclone.enabled: false`.
- **No-zurg path**: `mount.type = "rclone"`, full rclone block as above. Same user experience as today.

### Step 3 — Surrounding systems

1. **`swizzin-app-info`** (`swizzin-app-info:349-356`):
   - Current `"apikey": "apiKey"` key is broken today — v1 stored the API token in `auth.json`, not `config.json`; the case was also wrong. **Fix in this PR**: add a second config path for `auth.json` and map `apikey` → `api_token`.
   - Paths already correct.
2. **Watchdog** (`watchdog/decypharr-watchdog.sh`): no changes needed. Log file, log level, and `"no debrid clients available"` error string are all preserved in v2 (`pkg/manager/processor.go:329`).
3. **nginx** (`_nginx_decypharr` in `decypharr.sh:697-731`): two tweaks.
   - Broaden the auth-bypass from `/decypharr/api` to cover both qBit **and** Sabnzbd (v2 mounts Sabnzbd at `/sabnzbd/api`):
     ```nginx
     location ^~ /decypharr/api/ {
         auth_request off;
         proxy_pass http://127.0.0.1:$app_port/decypharr/api/;
     }
     location ^~ /decypharr/sabnzbd/api {
         auth_request off;
         proxy_pass http://127.0.0.1:$app_port/decypharr/sabnzbd/api;
     }
     ```
     (Sabnzbd API is optional — only hit when the user connects Sonarr/Radarr as Sabnzbd. No harm leaving the block there when Usenet is unused.)
   - Existing qBit API proxy path is now `/decypharr/api/v2` under v2 (was `/decypharr/api/v2` in v1 too — this doesn't change, our broadened `/api/` block still covers it).
4. **Backup** (`backup/swizzin-backup.sh`, `backup/swizzin-restore.sh`): no changes. `$HOME/.config/Decypharr/` is already backed up; v2 stores `auth.json` and `torrents.json` in the same directory, so they get included automatically.
5. **swizdb keys**: no schema change. We keep `decypharr/mount_path` and `decypharr/owner`.

### Step 4 — Rollout

1. Land the fork release (`STiXzoOR/decypharr v2.2-urlbase-fix`) **first**. Without the release, the installer breaks.
2. Land the `decypharr.sh` changes in this repo. Test matrix on the current server:
   - Clean install, no zurg → expect: setup wizard at `/decypharr/setup` (because api_key="" triggers Validate() failure). User fills in via UI. rclone mount active.
   - Clean install, zurg installed → api_key pre-filled from zurg, no wizard, `mount.type=none`, zurg mount used.
   - `--update` on a running v1 install → v2 binary starts, loads v1 config, auto-migrates `rclone.*` → `mount.rclone.*` and `qbittorrent.*` → root-level manager keys, writes migrated config back. Service comes up on same port. No config loss.
   - `--update --full` → rewrites config in v2 schema, restarts.
   - `--remove` → unchanged flow. No lingering v2-specific state.
3. Watch for issues specific to v2's migration pass:
   - If a user's v1 config had `repair.zurg_url` set, it'll be silently dropped on first v2 save — document this. Zurg linkage still works because `debrids[0].folder` points to the zurg mount.
   - If a user set `debrid.use_webdav`, v2 drops it. Behavior now driven by `mount.type` / `enable_webdav_auth`.
4. Update `docs/apps/` — no dedicated decypharr doc exists, but mention v2 config changes in commit message + PR description.

## Risks

- **Fork release cadence pressure**: we now track v2.x and rebase a 10-site redirect patch + 1-line DebridLink patch per upstream release. The 10 redirect sites are mechanical (find/replace `http.Redirect(w, r, "/" → s.redirectTo(w, r, "/`) — each rebase should take ~15 min unless upstream adds a new redirect. Mitigation: upstream PRs for both patches; retire the fork when accepted.
- **v2's Setup wizard bypasses our pre-filled config for non-zurg users**. This is a regression in "one-shot install" feel — user now clicks through the wizard even if api_key is the only thing they'd enter. Arguably acceptable, possibly desirable (explicit consent, validates creds before saving). Mitigation: surface a post-install hint: `echo_info "Visit https://.../decypharr/setup to finish configuration"`.
- **DFS / Usenet features untested on swizzin**: scope kept narrow (rclone or none). Users who want DFS enable it in UI.
- **armv6 users** (if any exist) lose updates. Mitigation: clear error message in `_install_decypharr` arch detection.

## Files Touched

- `/opt/swizzin-scripts/decypharr.sh` — config heredoc, nginx block, arch error, post-install hint
- `/opt/swizzin-scripts/swizzin-app-info` — add `auth.json` path + `apikey → api_token`
- Fork repo `STiXzoOR/decypharr` — new branch `v2.2-urlbase-fix`, tag, GitHub release

## Out of Scope

- Upstreaming the URLBase fix to `sirrobot01/decypharr` (separate PR, not a blocker).
- Adopting DFS / Usenet / new repair UI beyond plumbing nginx for Sabnzbd API.
- Rewriting the installer to expose `mount.type` as an install-time prompt.
