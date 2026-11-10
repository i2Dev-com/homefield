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
- **Read-only first.** `status`, `diagnose`, `preflight`, `memory`,
  `version` and `report` change nothing. `route` and `adopt` take `--dry-run`
  (and `adopt --setup` opens nothing until you merge its pull request).
- **Secrets.** Registration tokens reach the VM on stdin, never on a command
  line; nothing a command prints is a credential.

## Commands

| Command | What it does | Notes for scripts |
|---|---|---|
| `setup` | The whole first-time setup in one command: preflight (stops on a failure), then install, then a summary and next steps; on a terminal it offers the routing pull request | Takes install's options; on a registered instance it upgrades |
| `install` | Create the VM, provision it, register the runner; for an organization, create the runner group and wait for online | The lower-level command `setup` runs; reports preflight, does not stop on it |
| `upgrade` | Re-run provisioning on a registered runner: packages, hooks, runner binary | Refuses (and skips) a VM with a job running, unless `--force` |
| `status` | Each VM, its registration, the GitHub listing, the service, the job, npm | `--json`; exits 0 only when every VM answered well |
| `start` | Boot each VM, then report whether its runner is taking jobs | Exits 0 when every runner is online |
| `stop` | Stop each VM | Refuses a VM with a job running; stopping an already stopped VM is not an error |
| `diagnose` | One read-only report per VM, with the fix for each problem | `--json`; exits 1 on any problem; starts and changes nothing |
| `uninstall` | Deregister the runner and delete one VM | Refuses to guess with more than one VM: `--instance` is required |
| `reset` | Roll back an install, complete or half-finished | Asks first; `HOMEFIELD_YES=1` answers yes; a no-op when nothing to undo |
| `route` | Switch repositories' routed jobs to hosted or local (`CI_RUNNER`) | `route hosted` also re-runs stuck runs; `--dry-run` |
| `preflight` | Check prerequisites for a fresh install | Exits 0 when all pass, 1 otherwise, naming the fix |
| `adopt` | Prepare a repository: check the routing, add it to the group, switch it on | `--setup` opens the routing pull request; `--wait` carries on after the merge; refuses a public repository |
| `memory` | Every VM's memory use: average and peak per day, out-of-memory kills | `--days N` (default 7); fails for a VM it cannot ask |
| `report` | Queue wait, duration and minutes of jobs, local against hosted | `--json`; one API call per run, so allow a few minutes a month |
| `version` | The installed version, and whether a newer release exists (read from GitHub's public API; a private fork set with `HOMEFIELD_REPO` is not checked) | |

## Environment variables

| Variable | Effect |
|---|---|
| `HOMEFIELD_YES=1` | Answer yes to the tool's prompts: `reset`'s plan, the one-liner's Homebrew question |
| `HOMEFIELD_INSTANCE` | The default instance, as `--instance` does |
| `HOMEFIELD_GH_TIMEOUT` | Seconds a GitHub call waits before "not checked" (default 15) |
| `HOMEFIELD_COLOR` | `always` colors piped output; `NO_COLOR` (any value) turns color off everywhere |
| `HOMEFIELD_STATE_DIR` | Where the per-instance state files live (default `~/.local/state/homefield`) |
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
  "extra_packages": ["libpq-dev"]
}
```

`on_github.state` is `listed`, `not_listed`, `timeout` or `not_checked`;
`job.state` is `running`, `idle` or `unknown`; `npm` is `ok`, `broken` or
`unknown`. `healthy` is false when a fact that must be answerable was not (a
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

## Recipes

```bash
# Is everything healthy? One read-only command; the JSON names each problem's fix.
homefield diagnose --json

# Which VMs exist, and is each taking jobs?
homefield status --json

# Non-interactive first install (the one-liner's switches, then setup);
# HOMEFIELD_YES goes to the bash side of the pipe — that is the process
# whose prompts it answers:
curl -fsSL https://raw.githubusercontent.com/i2Dev-com/homefield/v0.5.3/install.sh | HOMEFIELD_YES=1 bash -s -- --url https://github.com/<org>

# Route a repository back to hosted (the recovery path, also the off switch):
homefield route hosted --repo <owner>/<repo>

# Preview a routing change without touching anything:
homefield route hosted --repo <owner>/<repo> --dry-run
homefield adopt --repo <owner>/<repo> --dry-run

# What did the VM's memory do this week?
homefield memory --days 7
```