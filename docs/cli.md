# CLI reference: commands, options, exit codes, environment variables

The human-facing help is the tool's own: `homefield --help` is the
one-line-per-command overview, `homefield help <command>` (or
`<command> --help`) prints one command's options, and `homefield help` is the
full reference. This page is the same facts, organized for scripts and AI
agents that drive the tool without a human in the loop. The guides:
[getting-started.md](getting-started.md) (first install),
[adopting.md](adopting.md) (routing a repository),
[runbook.md](runbook.md) (operating the runner).

## Conventions

- **Exit codes.** A command that acts on every VM exits 0 only when every one
  of them answered well, and 1 otherwise, with the fix named per VM; a
  failure on one VM never skips the next. The exceptions are listed per
  command below.
- **Output.** Colors (the `OK`/`WARN`/`FAIL` markers, warnings, errors) are
  for a terminal only: piped output is plain, so `grep` and substring matches
  are safe. `--color=always` forces color into a pipe; `NO_COLOR` and
  `--color=never` turn it off.
- **Instances.** Commands that act on a VM cover every HomeField VM on the
  Mac by default; `--instance NAME` (before or after the command, or
  `$HOMEFIELD_INSTANCE`) narrows them to one. `install`/`setup` create and
  act on exactly the instance they are given.
- **Read-only first.** `status`, `diagnose`, `preflight --no-prefetch` (and
  non-terminal `preflight`), `memory`, `version` and `report` change nothing.
  `route` and `adopt` take `--dry-run` (and `adopt --setup` opens nothing until
  you merge its pull request).
- **Secrets.** Registration tokens reach the VM on stdin, never on a command
  line; nothing a command prints is a credential.

## Commands

| Command | What it does | Notes for scripts |
|---|---|---|
| `setup` | The whole first-time setup in one command: preflight (stops on a failure), then install, then a summary and next steps; on a terminal it offers the routing pull request | Takes install's options; on a registered instance it upgrades |
| `install` | Create the VM, provision it, register the runner; for an organization, create the runner group and wait for online | The lower-level command `setup` runs; reports preflight, does not stop on it; `--ephemeral` registers one job per registration; `--ephemeral --reset-vm` clones a fresh VM from a base (`<instance>-base`) for every re-register |
| `upgrade` | Re-run provisioning on a registered runner: packages, hooks, runner binary | Refuses (and skips) a VM with a job running, unless `--force`; `--reset-vm` / `--no-reset-vm` switch the VM reset (on only when install created the base) |
| `re-register` | Re-register an `--ephemeral` runner with a fresh one-hour token (piped on stdin) | `--watch` polls and re-registers after each job completes; on failure leaves runner visibly offline; with the reset on, each re-register first clones a fresh VM from the base; `--reset-vm` / `--no-reset-vm` override the saved switch for one run. Re-registering in place (the reset off) is refused: a VM that has been registered may have run jobs, and a registration token must not go into one — a job's leftover root process could read it (runbook, trust boundary) |
| `status` | Each VM, its registration, the GitHub listing, the service, the job, npm | `--json`; exits 0 only when every VM answered well |
| `start` | Boot each VM, then report whether its runner is taking jobs | Exits 0 when every runner is online; `--route-local` puts the repositories a stop flipped to hosted back to local (automatic on an `--auto-route` VM) |
| `stop` | Stop each VM | Refuses a VM with a job running; stopping an already stopped VM is not an error; `--route-hosted` first sends the routed repositories to hosted when no other online runner serves the label (automatic on an `--auto-route` VM); a fallback that cannot be proven still stops and exits 1 |
| `diagnose` | One read-only report per VM, with the fix for each problem | `--json`; exits 1 on any problem; starts and changes nothing |
| `uninstall` | Deregister the runner and delete one VM | Refuses to guess with more than one VM: `--instance` is required; a `--reset-vm` install's base VM (`<instance>-base`) is deleted with it (only a base install marked; never an ordinary runner by that name) |
| `reset` | Roll back an install, complete or half-finished | Asks first; `HOMEFIELD_YES=1` answers yes; a no-op when nothing to undo; a `--reset-vm` install's base VM is deleted with the VM (same marker guard), an orphaned one (no runner VM) on its own, and reported when it cannot be |
| `route` | Switch repositories' routed jobs to hosted or local (`CI_RUNNER`) | `route hosted` also re-runs stuck runs; `--dry-run`; `route local` records the consumer's guard options (`--events push,schedule`, `--dependabot local`, `--mode simple` — the guard's own names and defaults) so the demand scaler counts only runs the expression would route to the runner; `--profile unknown` records the legacy three-field shape instead (the profile is not known and the demand scaler stays permissive) |
| `route-watch` | The sleep/wake half of the automatic fallback: a LaunchAgent (`com.homefield.route-watcher`, installed by `install`/`upgrade --auto-route`) runs `route-watch sleep` when the Mac sleeps and `route-watch wake` when it wakes up or logs in | `sleep` flips the routed repositories of every idle, Running VM with the automatic fallback on to hosted (a VM with a job running, or one that cannot be asked, is skipped and left as it is; the VMs are not stopped); `wake` starts those VMs, waits for each runner to be listed online (up to `HOMEFIELD_WATCH_WAKE_WAIT` seconds, default 120) and routes the flipped repositories back to local; if the Mac goes back to sleep while a wake recovery is running, the sleep notification kills it and runs the sleep-side flip first. One run is recorded in the watcher's state file, in the `route-watcher` subdirectory of the state directory; the log is the `log` file in the same subdirectory, and `status`/`diagnose` show the last run. `--no-auto-route`, `uninstall` and `reset` remove the agent when no VM on this Mac has the fallback on anymore |
| `preflight` | Check prerequisites for a fresh install | `--prefetch` / `--no-prefetch` controls VM image caching (default: on for a terminal, off otherwise; failed fetch warns only); exits 0 when prerequisites pass, 1 otherwise |
| `adopt` | Prepare a repository: check the routing, add it to the group, switch it on | `--setup` opens the routing pull request; `--wait` carries on after the merge; `--app-id` / `--app-key-file` for GitHub App auth; refuses a public repository |
| `memory` | Every VM's memory use: average and peak per day, out-of-memory kills | `--days N` (default 7); fails for a VM it cannot ask |
| `report` | Queue wait, duration and minutes of jobs, local against hosted | `--json`; one API call per run, so allow a few minutes a month |
| `fleet` | Fleet-wide status (`status`, default), `start`, `stop`, and the demand scaler (`watch`) across every HomeField VM on this Mac | `fleet [status] [--json]` prints per-VM rows and `total`/`online`/`idle`/`busy`/`offline` counts; `fleet start` boots all VMs and prints the fleet summary; `fleet start`/`fleet stop` take `--route-local`/`--route-hosted` for every VM; `fleet watch [--interval SEC] [--max-ticks N]` runs the demand scaler's ticks — spare VMs behind a busy fleet, and (opt-in) scale-to-zero with wake-on-demand (see the runbook, "The demand scaler") |
| `webhook` | The opt-in webhook receiver: GitHub's `workflow_job` deliveries ring the demand scaler through a cloudflared tunnel instead of waiting up to a tick interval | `webhook setup --hostname FQDN [--port N] [--overwrite-dns]` creates the tunnel, routes the DNS name, writes the 0600 webhook secret and installs the `com.homefield.webhook` LaunchAgent (needs a one-time `cloudflared tunnel login` and a domain on the Cloudflare account; the hostname must be a first-level subdomain of that domain — the zone's free Universal SSL certificate covers only the apex and `*.<domain>`, so a deeper name gets a TLS alert 40 at the edge; an existing DNS record for the hostname is refused unless `--overwrite-dns`, because the record may point at another tunnel or service); `webhook connect REPO` subscribes a repository to `workflow_job` (repo admin via gh; safe to re-run); `webhook status`; `webhook remove [--purge]`. Deliveries are HMAC-verified (`X-Hub-Signature-256`) before anything else; the receiver listens on 127.0.0.1 only, and each verified delivery spawns one `fleet watch --max-ticks 1` tick |
| `update` | Update the installed tool and every idle VM to the latest patch release (or branch head), then verify with `diagnose` | `--check` checks without applying; `--allow-minor` opts into minor/major bumps; `--auto` runs periodic check/apply per `HOMEFIELD_AUTO_UPDATE`; `--schedule install\|remove\|status` manages the macOS LaunchAgent; rolls back on failure |
| `version` | The installed version, and whether a newer release exists (read from GitHub's public API; a private fork set with `HOMEFIELD_REPO` is not checked) | |

## Environment variables

| Variable | Effect |
|---|---|
| `HOMEFIELD_YES=1` | Answer yes to the tool's prompts: `reset`'s plan, the one-liner's Homebrew question |
| `HOMEFIELD_INSTANCE` | The default instance, as `--instance` does |
| `HOMEFIELD_GH_TIMEOUT` | Seconds a GitHub call waits before "not checked" (default 15) |
| `HOMEFIELD_GITHUB_HOST` | The GitHub host commands without a `--url` work on (default `github.com`): a GitHub Enterprise Server host or a GHE.com subdomain. A `--url` always wins over it |
| `HOMEFIELD_COLOR` | `always` colors piped output; `NO_COLOR` (any value) turns color off everywhere |
| `HOMEFIELD_STATE_DIR` | Where the per-instance state files live (default `~/.local/state/homefield`) |
| `HOMEFIELD_LIMA_CACHE_DIR` | Lima's download cache root for `preflight` image caching (default `~/Library/Caches/lima`) |
| `HOMEFIELD_LIMA_TEMPLATE` | Override the Lima template YAML path checked by `preflight` image pre-fetching |
| `HOMEFIELD_AUTO_UPDATE` | Periodic mode for `homefield update --auto`: `off` (default), `notify` (check only), or `patch` (auto-apply patch bumps while idle) |
| `HOMEFIELD_UPDATE_INTERVAL` | Seconds between `homefield update --auto` checks and LaunchAgent runs (default `21600` = 6h; `0` disables) |
| `HOMEFIELD_AUTO_UPDATE_MINOR` | Set `1` to allow minor/major bumps in `HOMEFIELD_AUTO_UPDATE=patch` mode (default `0`) |
| `HOMEFIELD_WATCH_SLEEP_BUDGET` | Seconds the sleep-side flip may take before the watcher kills it (default 20, of the ~30 s macOS grants before it forces the sleep) |
| `HOMEFIELD_WATCH_WAKE_WAIT` | Seconds `route-watch wake` waits per VM for its runner to be listed online (default 120) |
| `HOMEFIELD_WATCH_WAKE_BUDGET` | Seconds the whole wake run may take before the watcher kills it (default 600) |
| `HOMEFIELD_SCALE_INTERVAL` | Seconds between the demand scaler's ticks (default 60) |
| `HOMEFIELD_SCALE_WAIT` | Seconds a queued job must have waited before the scaler boots a spare VM (default 300) |
| `HOMEFIELD_SCALE_IDLE` | Seconds a secondary must have had no job before the scaler stops it again (default 900) |
| `HOMEFIELD_SCALE_MAX` | Fleet-size cap: the most HomeField VMs on the Mac the scaler will create for (default 4) |
| `HOMEFIELD_SCALE_ZERO` | Set `1` to let the scaler stop the fleet's own idle VMs after the cooldown (scale to zero) and wake them on demand; off by default (see the runbook, "Scale to zero, and wake on demand") |
| `HOMEFIELD_SCALE_TICK_BUDGET` | Seconds one `fleet watch` tick may take before the agent kills it (default 1800) |
| `HOMEFIELD_WEBHOOK_PORT` | The webhook receiver's listen port (default 8787); baked into the agent's plist by `webhook setup` |
| `HOMEFIELD_WEBHOOK_ACTIONS` | `workflow_job` actions that ring the scaler, comma-separated (default `queued,completed`) |
| `HOMEFIELD_WEBHOOK_DEBOUNCE` | Minimum seconds between ticks the receiver spawns (default 1; a tick child already running always suppresses a spawn instead) |
| `HOMEFIELD_WEBHOOK_TUNNEL` | The cloudflared tunnel name the receiver runs (default `homefield-webhook`) |
| `HOMEFIELD_WEBHOOK_READ_TIMEOUT` | Seconds a connection may sit between reads before the receiver closes it (default 10); bounds what a peer that declares a body and never sends it can hold |
| `HOMEFIELD_WEBHOOK_MAX_CONNECTIONS` | Concurrent connections the receiver serves (default 32); excess connections are closed before a thread is spent on them; a value below 1 is not a usable cap and falls back to the default |

The `HOMEFIELD_WATCH_*`, `HOMEFIELD_SCALE_*` and `HOMEFIELD_WEBHOOK_*` variables set when `install`/`upgrade --auto-route` or `webhook setup` runs are baked into the LaunchAgent's plist environment, so the agent runs with the tuning the installer chose (launchd does not inherit a shell's environment).
| `HOMEFIELD_SOURCE_ONLY=1` | Internal: source `bin/homefield` for its functions, run nothing |

## Machine-readable output (`--json`)

`diagnose --json` and `status --json` need neither `jq` nor `python3` to
produce, and print nothing else on stdout.

`diagnose --json` — one object per VM, or, for every VM on the Mac, a wrapper:

```json
{
  "instance": "homefield",
  "healthy": true,
  "vm": {"created": true, "status": "Running", "guest_checked": true,
          "skipped_reason": null,
          "isolation": {"state": "closed", "detail": null},
          "loopback": {"state": "verified", "detail": "closed (the guest cannot reach the Mac's 127.0.0.1)"},
          "registered": true,
          "runner": {"name": "my-mac-homefield", "id": "42", "url": "https://github.com/acme"},
          "on_github": {"state": "listed", "status": "online", "busy": false, "detail": null},
          "service": {"state": "running", "unit": "actions.runner.acme.test.service"},
          "version": "2.338.0", "extra_packages": ["libpq-dev"], "npm": "ok"},
  "github": {"scope": "https://github.com/acme",
              "group": {"state": "checked", "name": "homefield-ci", "id": "7",
                         "visibility": "selected", "allows_public": false,
                         "repositories": ["acme/app"], "detail": null}},
  "prerequisites": [{"name": "Lima", "status": "ok", "message": "..."}],
  "problems": [],
  "warnings": [],
  "hints": []
}
```

For every VM on the Mac, the wrapper is
`{"instances": [...], "healthy": <bool>, "prerequisites": [...], "vms": [<object>...]}`;
a field that could not be checked is `null`; `problems` carries a
`{check, message, fix}` pair per problem found, and `warnings`/`hints` carry
the notes that are not problems.

`status --json` — the same facts as the human report, one object per VM:

```json
{
  "instance": "homefield",
  "healthy": true,
  "vm": {"created": true, "status": "Running"},
  "registered": true,
  "runner": {"name": "my-mac-homefield", "url": "https://github.com/acme", "id": "42"},
  "on_github": {"state": "listed", "status": "online"},
  "service": {"state": "running", "unit": "actions.runner.acme.test.service"},
  "job": {"state": "idle"},
  "version": "2.338.0",
  "npm": "ok",
  "extra_packages": ["libpq-dev"],
  "loopback": {"state": "verified", "detail": "closed (the guest cannot reach the Mac's 127.0.0.1)"}
}
```

`on_github.state` is `listed`, `not_listed`, `timeout` or `not_checked`;
`job.state` is `running`, `idle` or `unknown`; `npm` is `ok`, `broken` or
`unknown`; `loopback.state` is `verified`, `not-verified`, `open`, `stale`,
`skipped` or `unknown`. `healthy` is false when a fact that must be answerable was not (a
job or npm state unknown, the runner removed from GitHub, the VM unaskable) —
the same facts the exit status carries. For every VM on the Mac, the wrapper
is `{"instances": [...], "healthy": <bool>, "vms": [<object>...]}`.

`report --json` — the same rows the human form prints, as objects:
repository, day, queue wait, duration, minutes, local against hosted.

## Exit codes worth knowing

- `preflight`: 0 every check passes, 1 otherwise (the message names the fix
  command).
- `status`, `start`, `stop`, `upgrade`, `uninstall`, `reset`, `memory`:
  0 when every VM answered well, 1 otherwise.
- `diagnose`: 0 when every VM is healthy, 1 on any problem.
- `adopt` (plain, and `--setup` before the pull request exists): 1 when
  something stands in the way, having changed nothing; the output says what
  to add.
- `adopt --setup --wait`: 0 merged and switched on; 4 when the pull request
  was closed without a merge, is still open at the timeout, or cannot be
  read; 5 when it was merged but adopt then failed; 130/143 after Ctrl-C and
  SIGTERM (the state is safe and reported); 1 for anything before the pull
  request exists, as without `--wait`.
- `route`: 0 when every repository was routed; a repository that cannot be
  switched is warned about and skipped.
- `start`/`stop`: the runner/service rows as before; with the fallback
  (`--route-hosted`/`--route-local`, or automatic on an `--auto-route` VM),
  1 when the fallback could not be proven — GitHub unreachable, the runner
  missing from GitHub's list, a flip or restore that failed — while the VM
  itself is still stopped or started.
- `route-watch`: 1 when any VM's sleep or wake side failed (a flip that
  could not be proven, a VM that could not be started or asked, a runner
  that never came online); the other VMs still ran, and the run is recorded
  as failed either way.

## Recipes

```bash
# Is everything healthy? One read-only command; the JSON names each problem's fix.
homefield diagnose --json

# Which VMs exist, and is each taking jobs?
homefield status --json

# Non-interactive first install (the one-liner's switches, then setup);
# HOMEFIELD_YES goes to the bash side of the pipe — that is the process
# whose prompts it answers:
curl -fsSL https://raw.githubusercontent.com/i2Dev-com/homefield/v0.6.0/install.sh | HOMEFIELD_YES=1 bash -s -- --url https://github.com/<org>

# Route a repository back to hosted (the recovery path, also the off switch):
homefield route hosted --repo <owner>/<repo>

# Preview a routing change without touching anything:
homefield route hosted --repo <owner>/<repo> --dry-run
homefield adopt --repo <owner>/<repo> --dry-run

# Adopt a repository using GitHub App authentication (key file or stdin):
homefield adopt --repo <owner>/<repo> --app-id 12345 --app-key-file /etc/github-app.pem

# What did the VM's memory do this week?
homefield memory --days 7
```