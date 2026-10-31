# Security

This project runs pull-request code on your machine, so its isolation is the
point. Please report weaknesses in it privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the **Security** tab of this
repository → *Report a vulnerability*. Please don't open a public issue for
anything in scope below: escaping the VM, reading the host's files or
credentials, or bypassing the routing guard. The known limitations further
down are documented behaviour, so a public issue is fine for those. Include
what you ran, what you expected and what happened; a reproduction from
inside the guest is ideal.

We aim to acknowledge reports within a week and to credit reporters unless
they'd rather not be.

## What is in scope

- Escaping the VM, or reading the host's files or credentials from it.
- Getting the runner to run code from a fork, or from Dependabot or on a push
  when the repository has not opted those in (`dependabot: local`, `push` in
  `events`), despite the canonical routing expression; or a `runs-on` that
  reaches the runner while `routing-guard` passes.
- Leaking registration or removal tokens (they should only ever reach the VM
  on stdin).
- `bin/homefield` or `provision.sh` doing something unsafe with their inputs.

## Known limitations

These are documented and not treated as vulnerabilities; see the
[trust boundary](docs/runbook.md#trust-boundary):

- **Network:** jobs can reach the internet and the LAN. Through
  `host.lima.internal` they can reach host services bound to `*`; ones bound
  to `127.0.0.1` only are blocked for VMs created on Lima ≥ 2.3.0 (not yet a
  stable release; `networkOpts.hostLoopback: false` in `vm/lima.yaml`) and
  reachable on older Lima, which ignores that line — `install` and `upgrade`
  probe the truth from inside the guest and warn or refuse accordingly
  ([#18](https://github.com/i2Dev-com/homefield/issues/18)).
- **Public repositories are not supported.** A pull request runs its own
  workflow files, so anyone who can open one can change `runs-on`. Only
  private repositories may reach the runner.
- **Inside the VM, jobs are root-equivalent**, and repositories sharing the
  runner can see what earlier jobs left behind.

## Supported versions

Fixes land on `main` and ship in a new release. Only the latest release is
supported.
