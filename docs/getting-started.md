# Getting started: the first install in detail

The [README's Quick start](../README.md#quick-start) is the short version;
this page is the detail behind it — what the one-liner and `setup` do, the
account types, preflight, tokens and what to do when something stops. For
routing a repository after the install, see
[adopting.md](adopting.md); for operating the runner day to day, see
[runbook.md](runbook.md). Every command, option, exit code and environment
variable is in [cli.md](cli.md).

## The one-liner and `setup`

The one-liner installs Lima and `gh` with Homebrew if they are missing (Lima
also if it is older than 2.3), after one question that names the `brew`
commands it will run, puts the tool in `~/.local/share/homefield` with a
`homefield` command on your PATH, and runs `homefield setup` (`homefield
install` on a release older than `setup`). If `gh` is installed but not logged
in, and that is the only thing missing, `setup` offers to run `gh auth login`
for you on a terminal (with `-s admin:org` when `--url` is an organization, so
the runner group needs no second authorization). Without `--url`, `setup` asks
for your organization or repository URL. It creates the VM, checks its
isolation, provisions it, creates the `homefield-ci` runner group for an
organization (selected repositories only, no public ones), registers the
runner with the routing label `homefield-ci` and waits until GitHub shows it
online. Any other option is appended after `bash -s --`, like `--url`:

```bash
... | bash -s -- --url https://github.com/<org>      # or https://github.com/<owner>/<repo>
```

From a checkout, with Lima ≥ 2.3, run `bin/homefield setup --url
https://github.com/<org>` instead. `setup` is the whole first-time setup in one
command: it runs `preflight` first and stops, with nothing created, if any check
fails (a warning does not stop it; on a terminal, a `gh` that is not logged in
is first offered `gh auth login` when no other check fails, and the check runs
after it); then it does what `install` does, and ends with a summary, one line
per step, that marks what is done with a check mark and what needs attention
with `!` (a runner group wider than recommended, a runner that is not online
yet), followed by the next steps and the repositories that can already use the
runner.

On a terminal it then offers to open the routing pull request and carry on once
you merge it (`homefield adopt --setup --wait`): for the repository the runner
is registered to (a personal account, or a repository URL) it asks `Open the
routing pull request for <owner>/<repo> now, and carry on once you merge it?
[Y/n]`, and for an organization it asks which repository to route first (a
name, or `owner/repo`; Enter skips). Nothing is opened on GitHub unless you say
yes. After yes, `setup` waits for your merge and then adds the repository to the
runner group and switches it on, in the same run (Ctrl-C is safe: it leaves the
pull request as it is and prints the command to go on with). If `adopt` refuses
(a public repository, no write access, no workflow to route) the setup is still
done: it says so and how to run `adopt` again; so it is if the wait ends without
a merge, and then it says the pull request is open. Without a terminal, `setup`
only prints the next steps. It takes `install`'s options, and on an instance
that is already registered it upgrades it, as `install` does (without the
offer).

`install` stays the lower-level command: it prints the preflight report but
does not stop on it, and ends with its own short advice. Running the one-liner
again upgrades the tool and leaves an existing VM alone; `homefield upgrade`
updates the VM, `homefield version` says when a newer release exists, and
`homefield status` shows each VM's runner and whether GitHub still lists it.
`homefield start` boots a stopped VM and then says whether its runner is
actually taking jobs: registered, its service running and GitHub listing it
online — booted and online are separate facts, and it exits 1 with the fix
when they diverge. `homefield stop` stops the VM, so its runner takes no jobs
until it starts again, but refuses while a job is running, since stopping
would cancel it.

## Personal account or organization

`install` looks the URL's owner up first (with `gh`, else the public API) and
says whether it found an organization or a personal account. A personal
account cannot have an account-wide runner or a runner group, so it is
registered for one repository (`--url https://github.com/<you>/<repo>`); given
only its owner URL, `install` asks for the repository on a terminal and stops
without one. If the lookup cannot run (the API is unreachable, or your token
cannot see the account), `--personal` or `--org` says which it is and skips the
lookup; they cannot be combined.

## Preflight

Before a checkout setup, `homefield preflight` reports on everything the tool
needs: macOS, Apple Silicon, Lima ≥ 2.3, gh ≥ 2.81 (logged in; the `admin:org`
scope is only a warning, since a repository URL does not need it), python3 and
Homebrew. The gh floor is what the tool's own gh calls need —
`gh auth status --json hosts` and `gh api --jq` — and preflight names
`brew upgrade gh` when the installed gh is older.
It exits 0 when every check passes and 1 otherwise, naming the command that
fixes each failure (`brew install lima`, `gh auth login`, and so on); `setup`
prints it first and stops on any failure, while `install` prints it and then
gates on its own subset (macOS, Apple Silicon and Lima) before creating
anything, so gh, python3 or Homebrew missing stops `preflight` and `setup` but
not `install`. The one-liner itself checks only macOS, Apple Silicon and
Lima, and needs Homebrew to install Lima, which it checks before downloading
anything. It offers `brew install gh` in the same question but does not need
it: declining, having no terminal (without `HOMEFIELD_YES=1`) or having no
Homebrew goes on, and the preflight it then hands over to (`setup`) reports a
missing `gh` with the command to run, so a failed preflight check stops it
before the VM is created. `HOMEFIELD_YES=1` installs both without asking.

The level markers (`OK`, `WARN`, `FAIL`), the summaries and errors are
colored — green, yellow, red — when the output goes to a terminal. Piped
output stays plain, so scripts and `grep` keep working; `HOMEFIELD_COLOR=always`
colors a pipe, `NO_COLOR` (the no-color.org convention) turns color off
everywhere, and `--color=never` beats both. Every colored marker keeps its
plain word, so text around the colors reads the same either way.

## When something goes wrong

`homefield diagnose` (`--json` for scripts) reads everything in one report: the
VM, the runner and whether GitHub lists it, the runner group, and the
prerequisites. It names each problem with its fix command, exits 1 on any
problem, and only reads: it never starts, stops or changes anything.
When an install stops partway, `homefield reset` rolls back whatever it left
(the runner's registration, the VM and the runner group install created),
after listing it and asking; it is a no-op when there is nothing to undo
([runbook: rolling back](runbook.md#rolling-back-a-failed-install)).

## Registration token and runner group

Registration needs a one-hour token, and the group needs the `admin:org`
scope. `gh` fetches the token if you are an org owner or a repository admin
(and offers to add the scope); otherwise you paste a token from the runners
page's *New runner*. A repository URL needs neither a group nor the scope.
The group admits no repository until `adopt` adds it.

## Routing a repository yourself

`setup` offers to route a repository at its end. To do it later, or for
another repository, follow [adopting.md](adopting.md), and once that is
merged:

```bash
homefield adopt --repo <owner>/<repo>    # hosted again: homefield route hosted --repo <owner>/<repo>
```

`adopt` checks that the repository's routing and guard are in place, and only
then adds it to the runner group and switches it to the local runner. It
refuses a public repository. `--dry-run` shows what it would do. After the
switch it offers to re-run the repository's latest pull-request run and report
where each job landed (`--verify` does it without asking, `--no-verify` never;
[adopting.md](adopting.md#let-adopt-check-the-first-run)).

Rather than editing the workflows by hand, `homefield adopt --setup --repo
<owner>/<repo>` opens a pull request that writes those edits for you: the
routing expression on every pull-request job that runs on a GitHub-hosted
image — the simple expression for a repository without a guard, or pass
`--guards` for the guarded one in the README — the guard step listing them, and
`runner.arch` added to the cache keys
([adopting.md](adopting.md#let-adopt-write-steps-1-to-4)). Merge it, then run
`homefield adopt` to switch the repository on, or add `--wait`
(`homefield adopt --setup --wait --repo <owner>/<repo>`) and the same command
waits for your merge, then carries on and switches the repository on. A fresh
`setup` on a terminal offers to do exactly that for you at its end.

`homefield help <command>` prints a command's options (`--label`,
`--packages`, `--preset`, `--cpus`, ...); `homefield help` is the full
reference, and [cli.md](cli.md) is the same for scripts and agents.
[runbook.md](runbook.md) covers operating the runner.

`--preset browsers|hosted` closes a common parity gap in one command and adds
to what the VM already has instead of replacing the saved list: `browsers` is
the twelve Chromium OS libraries on Ubuntu 24.04; `hosted` includes them plus
`gh`, `shellcheck`, `sqlite3`, `xvfb` and `rsync`, an AWS CLI v2 hook and a
Node major matching the hosted image. Presets copy their hooks into
`/etc/homefield/provision.d/`, tracked upstream at provision time; jobs whose
versions matter still pin them ([runbook: Adding tools](runbook.md#adding-tools)).