#!/usr/bin/env python3
"""The routing guard: pin every job that can run on the local self-hosted
runner to one canonical `runs-on` expression.

GitHub evaluates `runs-on` before any step runs, so no action can choose a
job's runner: each opted-in job has to carry the expression inline. This check
is what keeps those inline copies honest. The expression carries four
guarantees that nothing else enforces. Guarantees 1 and 4 are mandatory; 2
and 3 are defaults that the repository can change, each with a cost:

  1. A hosted fallback (mandatory). With the repository variable CI_RUNNER
     unset or anything but `local`, the job runs on a GitHub-hosted image:
     `fallback`, ubuntu-latest by default, which must itself be a hosted image
     name, never a self-hosted label. A copy without the fallback leg queues
     forever whenever the local runner is off.
  2. Pull requests only (default; the `events` option). Pushes (main, release
     branches) then always run hosted, so merging and deploying never depend
     on the runner's machine being awake. Adding push, workflow_dispatch or
     schedule puts those jobs on the Mac: a deploy gated on CI can queue
     behind it, and it falls back to hosted only when CI_RUNNER is switched.
     Two events are refused outright. pull_request_target runs with the
     repository's secrets on code from forks. merge_group can carry a fork's
     pull request but has no github.event.pull_request, so guarantee 4 could
     not be checked.
  3. Dependabot stays hosted (default; the `dependabot` option), checked by
     actor and by branch. Its branches bring in unreviewed install scripts,
     and the local VM, unlike a hosted one, is not thrown away after the job.
     `dependabot: local` drops both checks and accepts that.
  4. Pull requests from forks stay hosted (mandatory): only a branch of the
     repository itself, pushed by someone with write access, is routed. A
     deleted fork leaves head.repo null, which also fails the comparison and
     runs hosted. This is defence in depth, not a boundary: a fork PR runs the
     workflow files from its own merge commit, so it can rewrite runs-on
     altogether. What keeps strangers off the runner is the runner group
     admitting private repositories only.

Every `runs-on` must be either the canonical expression or a GitHub-hosted
image name (ubuntu-*, windows-*, macos-*, alone or as a one-item list). It is
an allowlist because the ways to reach the local runner are open-ended: GitHub
matches labels case-insensitively and gives a job any runner whose labels are
a superset of the requested ones, so `Self-Hosted`, `[linux, ARM64]` or
`group: homefield-ci` all land on the VM with none of the guards. Anything not on
the list fails, including an expression this check cannot evaluate and a
multi-line `runs-on` (a list or mapping on the following lines). Write those
on one line, or keep the job on a hosted image name.

The file is read line by line, with no YAML parser, so it can only vouch for
the plain block style. Valid YAML that says the same thing another way (a
quoted `"runs-on"` key, a job written as a `{...}` mapping, a `<<` merge key,
`? runs-on`, a top-level key the scan cannot read) would pass unseen. Those
fail too, with a message that says how to write them plainly.

The set of opted-in jobs must equal --jobs exactly, so routing a job to the
local runner is always a deliberate, reviewed change.

Exit status: 0 if every check passes, 1 otherwise.

Two flags print instead of checking, for tools that build on the same rules
(bin/homefield adopt): --list names the jobs that carry the canonical
expression, and --print-expression prints the expression itself. Both take
the same options as a check (--events, --dependabot, --fallback).
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


# The routing label must be one custom label, the rule provision.sh applies to
# RUNNER_LABEL; keep the two in step. A comma would make the label several
# labels, and a GitHub default label or hosted image name would make the runner
# match jobs that never asked for it: GitHub gives a job any runner whose
# labels are a superset of the request, so a runner labelled `ubuntu-latest`
# takes plain `runs-on: ubuntu-latest` jobs, which HOSTED above lets through.
LABEL_CHARS = re.compile(r"^[A-Za-z0-9._-]+$")
RESERVED_LABEL = re.compile(
    r"^(self-hosted|linux|windows|macos|ubuntu|x64|x86|arm|arm64)$"
    r"|^(ubuntu|windows|macos)-",
    re.IGNORECASE,
)


def label_problem(label: str) -> str:
    if not LABEL_CHARS.match(label):
        return "must be one label of letters, digits, '.', '_' or '-'"
    if RESERVED_LABEL.match(label):
        return "must be a custom label, not a GitHub default label or hosted image name"
    return ""


# The events a job can be routed on, in the order the expression lists them.
# Some events are deliberately absent; REFUSED says why.
EVENTS = ("pull_request", "push", "workflow_dispatch", "schedule")
REFUSED = {
    "pull_request_target": "it runs with the repository's secrets on code from forks",
    "merge_group": "a merge group can hold a pull request from a fork, and the"
    " event has no pull_request to check where it came from",
}
DEFAULT_EVENTS = "pull_request"
DEPENDABOT = ("hosted", "local")
# The fallback must be a bare GitHub-hosted image name: a self-hosted label
# here would send the job to the runner whenever CI_RUNNER is not `local`.
FALLBACK = re.compile(r"(ubuntu|windows|macos)-[a-z0-9._-]+", re.IGNORECASE)


def parse_events(text: str) -> list:
    """The events in `text` (separated by newlines, commas or spaces), as a
    list in canonical order without duplicates. Raises ValueError."""
    given = [e for e in re.split(r"[\s,]+", text) if e]
    for event in given:
        if event in REFUSED:
            raise ValueError(f"events: {event} is refused: {REFUSED[event]}")
        if event not in EVENTS:
            raise ValueError(f"events: {event!r} is not one of {', '.join(EVENTS)}")
    if not given:
        raise ValueError(f"events: name at least one of {', '.join(EVENTS)}")
    return [e for e in EVENTS if e in given]


def option_problem(dependabot: str, fallback: str) -> str:
    if dependabot not in DEPENDABOT:
        return f"dependabot: {dependabot!r} must be hosted or local"
    if not FALLBACK.fullmatch(fallback):
        return (
            f"fallback: {fallback!r} must be a bare GitHub-hosted image name"
            " (ubuntu-*, windows-* or macos-*): a self-hosted label would"
            " defeat the hosted fallback"
        )
    return ""


def event_clause(events: list) -> str:
    clauses = [f"github.event_name == '{e}'" for e in events]
    return clauses[0] if len(clauses) == 1 else "(" + " || ".join(clauses) + ")"


# With pull_request alone the fork comparison stands bare. With other events it
# must let them through: they carry no pull_request, so the comparison would be
# against null and send them hosted.
FORK_PR = "github.event.pull_request.head.repo.full_name == github.repository"
FORK_ANY = f"(github.event_name != 'pull_request' || {FORK_PR})"


def fork_clause(events: list) -> str:
    return FORK_PR if events == ["pull_request"] else FORK_ANY


def canonical_expression(
    label: str,
    arch: str,
    events=(DEFAULT_EVENTS,),
    dependabot: str = "hosted",
    fallback: str = "ubuntu-latest",
) -> str:
    """The expression for validated options: `events` in canonical order."""
    labels = ",".join(f'"{x}"' for x in ("self-hosted", "linux", arch, label))
    clauses = ["vars.CI_RUNNER == 'local'", event_clause(list(events))]
    if dependabot == "hosted":
        clauses += [
            "github.actor != 'dependabot[bot]'",
            "!startsWith(github.head_ref, 'dependabot/')",
        ]
    clauses += [fork_clause(list(events)), f"fromJSON('[{labels}]')"]
    return "${{ " + " && ".join(clauses) + f" || '{fallback}' }}}}"


def guards(events: list, dependabot: str, fallback: str) -> list:
    """Each guard the options call for, as (fragment, name): the fragment of
    the expression that implements it. Asserted against the canonical
    expression itself, so a future edit to canonical_expression() cannot
    weaken every copy at once without failing here."""
    found = [
        (f"|| '{fallback}'", "hosted fallback"),
        ("vars.CI_RUNNER == 'local'", "opt-in switch"),
        (event_clause(events), "event rule"),
        (fork_clause(events), "fork pull requests excluded"),
    ]
    if dependabot == "hosted":
        found += [
            ("github.actor != 'dependabot[bot]'", "Dependabot actor excluded"),
            ("!startsWith(github.head_ref, 'dependabot/')", "Dependabot branch excluded"),
        ]
    return found


# This check reads workflows line by line, with no YAML parser, so it can only
# vouch for the plain block style GitHub's own examples use. Valid YAML that
# says the same thing another way (a quoted `"runs-on"` key, a job written as a
# `{...}` mapping, a `<<` merge key, `? runs-on`) would pass unseen, so these
# fail instead, and the message says how to write it.
PLAIN_KEY = re.compile(r"""^(['"]?)[A-Za-z0-9_-]+\1:(\s|$)""")
UNREAD = (
    (re.compile(r"""^\s*(-\s+)?["']runs-on["']\s*:"""), "a quoted runs-on key"),
    # A line that opens a {...} or [...] and names runs-on. A plain job body
    # never starts a line with a bracket.
    (re.compile(r"""^\s*[{,\[].*runs-on"""), "runs-on inside a {...} mapping"),
    (re.compile(r"""^\s*\?(\s|$)"""), "a ? complex key"),
    (re.compile(r"""^\s*runs-on\s+:"""), "a space before the colon of runs-on"),
    (re.compile(r"""^\s*["']?<<["']?\s*:"""), "a << merge key"),
    (re.compile(r"""^\s*-?\s*"[^"]*\\[^"]*"\s*:"""), "a double-quoted key with an escape"),
    # A key whose quote is still open at the end of the line: a double-quoted
    # scalar may continue on the next line (`"runs-\` then `on"` reads as
    # runs-on), so neither line holds the word.
    (re.compile(r"""^\s*[-?]?\s*"(?:[^"\\]|\\.)*\\?$"""), "a quoted key that continues on the next line"),
    (re.compile(r"""^\s*[-?]?\s*'(?:[^']|'')*$"""), "a quoted key that continues on the next line"),
)
# The start of a block scalar (`run: |`, `- >-`, `run: &script |`): the lines under it are text, not
# keys, so a script line that begins with `?`, a bracket or a quote is not YAML
# the checks above are about.
BLOCK_START = re.compile(r"""^(\s*)(-\s+)?([^\s#][^#]*?:\s+)?(?:[&!]\S*\s+)*[|>][-+0-9]*\s*$""")
HOW = "write routing as a plain `runs-on: ...` line directly under a plain `job-id:` line"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--workflows-dir", default=".github/workflows")
    ap.add_argument("--label", default="homefield-ci")
    ap.add_argument("--arch", default="arm64")
    ap.add_argument(
        "--events",
        default=DEFAULT_EVENTS,
        help=f"events routed locally ({', '.join(EVENTS)}), separated by newlines,"
        " commas or spaces",
    )
    ap.add_argument("--dependabot", default="hosted", help="hosted or local")
    ap.add_argument(
        "--fallback", default="ubuntu-latest", help="the GitHub-hosted image used when not local"
    )
    ap.add_argument(
        "--jobs",
        default="",
        help="file:job entries that opt in, separated by newlines, commas or spaces",
    )
    ap.add_argument(
        "--list",
        action="store_true",
        help="print the jobs that carry the canonical expression, one file:job per"
        " line, and exit 0; checks nothing else",
    )
    ap.add_argument(
        "--print-expression",
        action="store_true",
        help="print the canonical runs-on expression for the options and exit",
    )
    args = ap.parse_args()

    problem = label_problem(args.label)
    if problem:
        print(f"  \033[31mFAIL\033[0m label {args.label!r} {problem}")
        return 1
    try:
        events = parse_events(args.events)
    except ValueError as err:
        print(f"  \033[31mFAIL\033[0m {err}")
        return 1
    problem = option_problem(args.dependabot, args.fallback)
    if problem:
        print(f"  \033[31mFAIL\033[0m {problem}")
        return 1
    canonical = canonical_expression(args.label, args.arch, events, args.dependabot, args.fallback)
    if args.print_expression:
        print(canonical)
        return 0
    expected = [e for e in re.split(r"[\s,]+", args.jobs) if e]
    quiet = args.list

    failed = 0
    passed = 0

    def fail(msg: str) -> None:
        nonlocal failed
        if not quiet:
            print(f"  \033[31mFAIL\033[0m {msg}")
        failed += 1

    def ok(msg: str) -> None:
        nonlocal passed
        if not quiet:
            print(f"  \033[32mPASS\033[0m {msg}")
        passed += 1

    if not quiet:
        print(f"self-hosted runner routing (label {args.label}, {args.workflows_dir})")

    if not os.path.isdir(args.workflows_dir):
        if quiet:
            print(f"workflows dir {args.workflows_dir} not found", file=sys.stderr)
            return 1
        fail(f"workflows dir {args.workflows_dir} not found")
        return 1

    found = []
    for name in sorted(os.listdir(args.workflows_dir)):
        if not name.endswith((".yml", ".yaml")):
            continue
        job = None
        in_jobs = False
        job_indent = None
        scalar_col = None
        path = os.path.join(args.workflows_dir, name)
        with open(path) as fh:
            for lineno, line in enumerate(fh, 1):
                # Comments may name the label; only code counts. Safe to cut at
                # '#' because the canonical expression contains none.
                code = line.split("#", 1)[0]
                # Inside a block scalar (blank, or indented past its key), the
                # line is text. The unreadable-syntax checks skip it.
                in_scalar = False
                if scalar_col is not None:
                    in_scalar = not line.strip() or len(line) - len(line.lstrip()) > scalar_col
                    if not in_scalar:
                        scalar_col = None
                if not in_scalar:
                    start = BLOCK_START.match(code)
                    if start:
                        # The key's own column, or the dash's for `- |`.
                        scalar_col = len(start.group(1)) + (len(start.group(2)) if start.group(2) and start.group(3) else 0)
                # Job ids are the keys directly under top-level `jobs:` — at
                # whatever indent the file's first such key uses, so a
                # workflow indented other than the common two spaces still
                # attributes its runs-on lines to the right job — while keys
                # deeper than that (needs, steps, ...) belong to the job's
                # body, and keys under any other top-level key (`on:` among
                # them) are not jobs at all. Top-level keys and job ids may
                # be quoted (`"jobs":`, `"checks":`): a quoted `jobs:` missed
                # here would skip every runs-on in the file — none of them
                # checked, a bare `runs-on: self-hosted` included — and a
                # quoted key missed below would credit its runs-on to the
                # previous job.
                top = re.match(r"""^(['"]?)([A-Za-z0-9_-]+)\1:""", code)
                if code.strip() and not code[0].isspace():
                    # Every top-level line is a plain `key:`. Anything else
                    # (`jobs :`, `? jobs`, a flow mapping's closing brace)
                    # could hide the jobs from this scan.
                    if code.strip() not in ("---", "...") and not PLAIN_KEY.match(code):
                        fail(f"{name}:{lineno}: unreadable top-level line; {HOW}")
                        in_jobs = False
                        job = None
                        job_indent = None
                        continue
                if top:
                    in_jobs = top.group(2) == "jobs"
                    job = None
                    job_indent = None
                    if in_jobs and code[top.end():].strip():
                        fail(f"{name}:{lineno}: jobs: has its jobs on the same line; {HOW}")
                m = re.match(r"""^(\s*)(['"]?)([A-Za-z0-9_-]+)\2:\s*$""", code)
                if in_jobs and code.strip() and not top and not in_scalar:
                    indent = len(code) - len(code.lstrip())
                    if job_indent is None:
                        # The first line under `jobs:` is a job id; everything
                        # at that depth is one, anything deeper is its body.
                        job_indent = indent
                    if indent == job_indent:
                        if m:
                            job = m.group(3)
                        else:
                            job = None
                            fail(f"{name}:{lineno}: unreadable job id; {HOW}")
                            continue
                    elif indent < job_indent:
                        fail(f"{name}:{lineno}: unreadable indentation under jobs; {HOW}")
                where = f"{name}:{lineno} (job {job})"
                m = re.match(r"^\s*runs-on:\s*(.*?)\s*$", code)
                # Only runs-on lines inside `jobs:` matter: a key named
                # `runs-on:` under `on:` (a workflow_dispatch input, say) is
                # not routing. Every one is checked against the allowlist
                # below, and a multi-line runs-on already fails on its first
                # line, so the label appearing elsewhere (a step name, a docs
                # URL in a run string) is not routing.
                if in_jobs and not m and not in_scalar:
                    for pattern, what in UNREAD:
                        if pattern.search(code):
                            fail(f"{where}: {what} is not read by this check; {HOW}")
                            break
                if not in_jobs or not m:
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

    if args.list:
        for key in found:
            print(key)
        return 0

    for key in expected:
        if key in found:
            ok(f"{key} is routed")
        else:
            fail(f"{key} is expected to opt in but does not")
    for key in found:
        if key not in expected:
            fail(f"{key} opts in but is not in the expected list — add it deliberately")

    for needle, why in guards(events, args.dependabot, args.fallback):
        if needle in canonical:
            ok(f"canonical expression has {why}")
        else:
            fail(f"canonical expression lost its {why}")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
