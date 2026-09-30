#!/usr/bin/env python3
"""Pin every job that can run on the local self-hosted runner to one
canonical `runs-on` expression.

GitHub evaluates `runs-on` before any step runs, so no action can choose a
job's runner: each opted-in job has to carry the expression inline. This check
is what keeps those inline copies honest. The expression carries four
guarantees that nothing else enforces:

  1. A hosted fallback. With the repository variable CI_RUNNER unset or
     anything but `local`, the job runs on ubuntu-latest. A copy without the
     `|| 'ubuntu-latest'` leg queues forever whenever the local runner is off.
  2. Pull requests only. Pushes (main, release branches) always run hosted, so
     merging and deploying never depend on a laptop being awake.
  3. Dependabot stays hosted, checked by actor and by branch. Its branches
     bring in unreviewed install scripts, and the local VM, unlike a hosted
     one, is not thrown away after the job.
  4. Pull requests from forks stay hosted: only a branch of the repository
     itself, pushed by someone with write access, is routed. A deleted fork
     leaves head.repo null, which also fails the comparison and runs hosted.
     This is defence in depth, not a boundary: a fork PR runs the workflow
     files from its own merge commit, so it can rewrite runs-on altogether.
     What keeps strangers off the runner is the runner group admitting
     private repositories only.

Every `runs-on` must be either the canonical expression or a GitHub-hosted
image name (ubuntu-*, windows-*, macos-*, alone or as a one-item list). It is
an allowlist because the ways to reach the local runner are open-ended: GitHub
matches labels case-insensitively and gives a job any runner whose labels are
a superset of the requested ones, so `Self-Hosted`, `[linux, ARM64]` or
`group: local-ci` all land on the VM with none of the guards. Anything not on
the list fails, including an expression this check cannot evaluate and a
multi-line `runs-on` (a list or mapping on the following lines). Write those
on one line, or keep the job on a hosted image name.

The set of opted-in jobs must equal EXPECTED exactly, so routing a job to the
local runner is always a deliberate, reviewed change.

Exit status: 0 if every check passes, 1 otherwise.
"""
import argparse
import os
import re
import sys

# A GitHub-hosted image label, optionally quoted. Case-insensitive, as GitHub's
# label matching is. None of these can name the local runner, whose labels are
# self-hosted, Linux, ARM64 and the routing label.
# Also accepted as a one-element flow list, `[ubuntu-latest]`.
HOSTED = re.compile(
    r"""^(\[\s*)?(['"]?)(ubuntu|windows|macos)-[a-z0-9._-]+\2(?(1)\s*\])$""",
    re.IGNORECASE,
)


def canonical_expression(label: str, arch: str) -> str:
    labels = ",".join(f'"{x}"' for x in ("self-hosted", "linux", arch, label))
    return (
        "${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request'"
        " && github.actor != 'dependabot[bot]'"
        " && !startsWith(github.head_ref, 'dependabot/')"
        " && github.event.pull_request.head.repo.full_name == github.repository"
        f" && fromJSON('[{labels}]') || 'ubuntu-latest' }}}}"
    )


# Each guard, as the fragment of the expression that implements it. Asserted
# against the canonical expression itself, so a future edit to
# canonical_expression() cannot weaken every copy at once without failing here.
GUARDS = [
    ("|| 'ubuntu-latest'", "hosted fallback"),
    ("vars.CI_RUNNER == 'local'", "opt-in switch"),
    ("github.event_name == 'pull_request'", "pull-request-only rule"),
    ("github.actor != 'dependabot[bot]'", "Dependabot actor excluded"),
    ("!startsWith(github.head_ref, 'dependabot/')", "Dependabot branch excluded"),
    (
        "github.event.pull_request.head.repo.full_name == github.repository",
        "fork pull requests excluded",
    ),
]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--workflows-dir", default=".github/workflows")
    ap.add_argument("--label", default="i2dev-ci")
    ap.add_argument("--arch", default="arm64")
    ap.add_argument(
        "--expected",
        default="",
        help="file:job entries that opt in, separated by newlines, commas or spaces",
    )
    args = ap.parse_args()

    canonical = canonical_expression(args.label, args.arch)
    expected = [e for e in re.split(r"[\s,]+", args.expected) if e]

    failed = 0
    passed = 0

    def fail(msg: str) -> None:
        nonlocal failed
        print(f"  \033[31mFAIL\033[0m {msg}")
        failed += 1

    def ok(msg: str) -> None:
        nonlocal passed
        print(f"  \033[32mPASS\033[0m {msg}")
        passed += 1

    print(f"self-hosted runner routing (label {args.label}, {args.workflows_dir})")

    if not os.path.isdir(args.workflows_dir):
        fail(f"workflows dir {args.workflows_dir} not found")
        return 1

    found = []
    for name in sorted(os.listdir(args.workflows_dir)):
        if not name.endswith((".yml", ".yaml")):
            continue
        job = None
        in_jobs = False
        path = os.path.join(args.workflows_dir, name)
        with open(path) as fh:
            for lineno, line in enumerate(fh, 1):
                # Comments may name the label; only code counts. Safe to cut at
                # '#' because the canonical expression contains none.
                code = line.split("#", 1)[0]
                # Job ids are the two-space keys under top-level `jobs:` only,
                # so `push:` or `workflow_call:` under `on:` are never taken
                # for one.
                top = re.match(r"^([A-Za-z0-9_-]+):", code)
                if top:
                    in_jobs = top.group(1) == "jobs"
                    job = None
                # Keys may be quoted (`"checks":`); a quoted key missed here
                # would credit its runs-on to the previous job.
                m = re.match(r"""^  (['"]?)([A-Za-z0-9_-]+)\1:\s*$""", code)
                if in_jobs and m:
                    job = m.group(2)
                where = f"{name}:{lineno} (job {job})"
                m = re.match(r"^\s*runs-on:\s*(.*?)\s*$", code)
                # Only runs-on lines matter. Every one is checked against the
                # allowlist below, and a multi-line runs-on already fails on
                # its first line, so the label appearing elsewhere (a step
                # name, a docs URL in a run string) is not routing.
                if not m:
                    continue
                value = m.group(1)
                if HOSTED.match(value):
                    continue
                if value != canonical:
                    fail(
                        f"{where}: runs-on is neither a GitHub-hosted image nor the"
                        " canonical expression\n"
                        f"         got:  {value or '(multi-line)'}\n         want: {canonical}"
                    )
                    continue
                found.append(f"{name}:{job}")
                ok(f"{where} uses the canonical expression")

    for key in expected:
        if key in found:
            ok(f"{key} is routed")
        else:
            fail(f"{key} is expected to opt in but does not")
    for key in found:
        if key not in expected:
            fail(f"{key} opts in but is not in the expected list — add it deliberately")

    for needle, why in GUARDS:
        if needle in canonical:
            ok(f"canonical expression has {why}")
        else:
            fail(f"canonical expression lost its {why}")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
