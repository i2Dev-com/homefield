#!/usr/bin/env python3
"""Text helpers for `bin/homefield adopt`, which downloads a repository's
workflow files and needs three things from them: the routing-guard
steps, cache keys that lack the architecture, and the guard step to suggest.
Stdlib only, and no YAML parser: the workflow text is read line by line, which
is enough for the shapes GitHub workflows take and fails safe (a guard it
cannot read counts as no guard, so adopt does not switch the repository on).

A guard is a step that uses ACTION_PATH (the owner and repository compared
without case) at an exact release tag (v0.1.0, v0.2.0, ...) or at a full
commit SHA (accepted with a warning), and that can run on a pull request: see
check_guard. Major-only tags (@v3), branches and any other ref are not
recognized.

  adopt.py guards DIR       one line per step that uses some routing guard:
                            file:line <TAB> status <TAB> label <TAB> blocking
                            <TAB> warnings <TAB> events
                            <TAB> dependabot <TAB> fallback <TAB> job
                            entries (spaces). status is ok (a usable guard),
                            blocked (a recognized routing-guard step that
                            cannot run on pull requests) or source (not an
                            action adopt recognizes). blocking and warnings
                            are texts joined by ";", or "-" when there are
                            none. events (spaces), dependabot and fallback
                            are the step's `with:` values, or the defaults
                            when it sets none; "-" is a value set to
                            nothing. The job entries
                            come last because they may be empty.
  adopt.py cache-keys DIR   one line per cache key that has runner.os and not
                            runner.arch: file:line: text
  adopt.py guard-snippet [--label L] [--events E] [--dependabot D]
                            [--fallback F] [--jobs a.yml:x,b.yml:y]
                            the guard step to add to a workflow; an option
                            appears only when it is not the default
  adopt.py quote TEXT       TEXT percent-encoded for a URL path
"""
import argparse
import os
import re
import sys
import urllib.parse

# The release the snippet adopt prints pins, and that docs/adopting.md and the
# README tell consumers to pin; tests/adopt.sh checks that the docs still say
# it. Bump it when a release is cut.
RELEASE = "v0.1.0"
ACTION_PATH = "i2Dev-com/homefield/routing-guard"
ACTION = f"{ACTION_PATH}@{RELEASE}"
DEFAULT_LABEL = "homefield-ci"
# The routing-guard options besides the label, and their defaults.
DEFAULT_EVENTS = "pull_request"
DEFAULT_DEPENDABOT = "hosted"
DEFAULT_FALLBACK = "ubuntu-latest"

# A step or job `uses:`; group 3 is the raw value.
USES = re.compile(r"^(\s*)(-\s+)?uses:\s*(.*?)\s*$")
# The refs adopt recognizes: an exact release tag, or a full commit SHA.
RELEASE_REF = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")
SHA_REF = re.compile(r"[0-9a-fA-F]{40}")
# What a step that uses some routing guard (any owner, any ref) has in `uses:`.
STEP_MARKER = "/routing-guard@"
ACTION_DIR = "./.github/workflows/"
# The trigger options after which a pull request may not run the workflow.
FILTERS = ("branches", "branches-ignore", "paths", "paths-ignore")
ON_KEY = re.compile(r"^([\"']?)on\1:\s*(.*?)\s*$")
KEY = re.compile(r"^(\s*)(-\s+)?([A-Za-z0-9_-]+):\s*(.*?)\s*$")
CACHE_KEY = re.compile(r"^(\s*)(?:-\s+)?(key|restore-keys):\s*(.*?)\s*$")


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return [line.rstrip("\r\n") for line in fh]


def workflow_files(directory):
    return sorted(n for n in os.listdir(directory) if n.endswith((".yml", ".yaml")))


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank(line):
    s = line.strip()
    return not s or s.startswith("#")


def in_block(line, base):
    """Whether a line belongs to a block scalar whose key is indented `base`:
    blank, or indented deeper. A comment at the key's own depth or less ends
    it (a deeper one is text, as YAML reads it)."""
    return not line.strip() or indent_of(line) > base


def scalar(value):
    """A single-line YAML scalar: no trailing comment, no quotes."""
    value = re.sub(r"\s+#.*$", "", value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    return value


def step_bounds(lines, at):
    """The first and one-past-last line of the step that has its `uses:` on
    line index `at`. A step is a list item; its keys sit two columns right of
    the dash (or on the dash line itself)."""
    m = USES.match(lines[at])
    if m.group(2):
        start, dash = at, len(m.group(1))
    else:
        # `uses:` is a later key of the step: walk up to its `- ` line.
        key_indent = len(m.group(1))
        start = at
        while start > 0:
            line = lines[start]
            if not is_blank(line) and indent_of(line) < key_indent:
                break
            start -= 1
        dash = indent_of(lines[start])
        if not lines[start].lstrip().startswith("-"):
            return at, at + 1
    end = start + 1
    while end < len(lines):
        if not is_blank(lines[end]) and indent_of(lines[end]) <= dash:
            break
        end += 1
    return start, end


def with_values(lines, start, end):
    """The keys of the step's `with:` block, as {key: text}. A block scalar
    (`|`, `>`, with or without - and +) keeps its lines, newline-joined."""
    key_indent = None
    for i in range(start, end):
        m = KEY.match(lines[i])
        if m and m.group(3) == "uses":
            key_indent = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
            break
    if key_indent is None:
        return {}
    values = {}
    i = start
    while i < end:
        m = KEY.match(lines[i])
        here = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0) if m else -1
        if m and m.group(3) == "with" and here == key_indent and not m.group(4):
            child = None
            i += 1
            while i < end:
                line = lines[i]
                if is_blank(line):
                    i += 1
                    continue
                if indent_of(line) <= key_indent:
                    break
                if child is None:
                    child = indent_of(line)
                km = KEY.match(line)
                if km and indent_of(line) == child:
                    name, rest = km.group(3), km.group(4)
                    if re.match(r"^[|>][+-]?\d*\s*(#.*)?$", rest):
                        block = []
                        i += 1
                        while i < end and in_block(lines[i], child):
                            block.append(lines[i].strip())
                            i += 1
                        values[name] = "\n".join(block)
                        continue
                    values[name] = scalar(rest)
                i += 1
            continue
        i += 1
    return values


def parse_triggers(lines):
    """The workflow's `on:` as {event: {"line": n, "filters": [names]}}, n
    1-based. Reads `on: name`, `on: [a, b]`, `on: {a: ..}` on one line, and
    the block forms (`a:` keys with their options nested, or `- a` items),
    with `on`, "on" and 'on'. Anything else gives no events."""
    events = {}
    for i, line in enumerate(lines):
        m = ON_KEY.match(line)
        if not m:
            continue
        rest = re.sub(r"\s+#.*$", "", m.group(2)).strip()
        if rest and rest[0] in "[{":
            is_map = rest[0] == "{"
            names = re.findall(r"([A-Za-z_]+)\s*:", rest) if is_map else re.split(r"[\s,\[\]]+", rest)
            for name in (n.strip("'\"") for n in names if n):
                if name not in FILTERS:
                    events[name] = {"line": i + 1, "filters": []}
            if is_map and "pull_request" in events:
                events["pull_request"]["filters"] = [f for f in FILTERS if re.search(rf"\b{f}\s*:", rest)]
        elif rest:
            for name in (n.strip("'\"") for n in rest.split(",")):
                if name:
                    events[name] = {"line": i + 1, "filters": []}
        else:
            base = None
            j = i + 1
            while j < len(lines):
                cur = lines[j]
                if is_blank(cur):
                    j += 1
                    continue
                if indent_of(cur) == 0:
                    break
                if base is None:
                    base = indent_of(cur)
                if indent_of(cur) == base:
                    text = cur.strip()
                    km = re.match(r"^[\"']?([A-Za-z0-9_-]+)[\"']?:\s*(.*)$", text)
                    if text.startswith("- "):
                        events[scalar(text[2:])] = {"line": j + 1, "filters": []}
                    elif km:
                        filters = []
                        inline = re.sub(r"\s+#.*$", "", km.group(2))
                        filters += [f for f in FILTERS if re.search(rf"\b{f}\s*:", inline)]
                        k = j + 1
                        while k < len(lines) and (is_blank(lines[k]) or indent_of(lines[k]) > base):
                            fm = KEY.match(lines[k])
                            if fm and fm.group(3) in FILTERS:
                                filters.append(fm.group(3))
                            k += 1
                        events[km.group(1)] = {"line": j + 1, "filters": filters}
                j += 1
        break
    return events


def condition(value):
    """How an `if:` reads: "false" when it is the literal false, which keeps
    the step or job from ever running, and "other" for anything else."""
    text = scalar(value)
    m = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", text)
    if m:
        text = m.group(1)
    return "false" if text.strip().lower() == "false" else "other"


def parse_jobs(lines):
    """The jobs of the workflow: id, line (1-based), first and one-past-last
    line index, the job-level `if:` as (line, value), and a job-level
    `uses:` (a reusable workflow it calls). A job-level key sits at the
    indent of the job's first child; a step's keys are deeper."""
    jobs = []
    top = next((i for i, line in enumerate(lines) if re.match(r"^jobs:\s*(#.*)?$", line)), None)
    if top is None:
        return jobs
    base = None
    i = top + 1
    while i < len(lines):
        line = lines[i]
        if is_blank(line):
            i += 1
            continue
        if indent_of(line) == 0:
            break
        if base is None:
            base = indent_of(line)
        m = re.match(r"^[\"']?([^\s:#\"']+)[\"']?:\s*(#.*)?$", line.strip())
        if indent_of(line) == base and m:
            end = i + 1
            while end < len(lines) and (is_blank(lines[end]) or indent_of(lines[end]) > base):
                end += 1
            job = {"id": m.group(1), "line": i + 1, "start": i, "end": end, "if": None, "uses": None}
            child = next((indent_of(lines[k]) for k in range(i + 1, end) if not is_blank(lines[k])), None)
            for k in range(i + 1, end):
                km = KEY.match(lines[k])
                if km and not km.group(2) and len(km.group(1)) == child:
                    if km.group(3) == "if":
                        job["if"] = (k + 1, km.group(4))
                    elif km.group(3) == "uses":
                        job["uses"] = scalar(km.group(4))
            jobs.append(job)
            i = end
            continue
        i += 1
    return jobs


def step_if(lines, at):
    """(line, value) of the `if:` of the step with its `uses:` on line index
    `at`, or None."""
    start, end = step_bounds(lines, at)
    m = USES.match(lines[at])
    key_indent = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
    for i in range(start, end):
        km = KEY.match(lines[i])
        if km and km.group(3) == "if" and len(km.group(1)) + (len(km.group(2)) if km.group(2) else 0) == key_indent:
            return i + 1, km.group(4)
    return None


def check_guard(name, at, files):
    """(blocking, warnings) for the routing-guard step on line index `at` of
    file `name`, given files = {name: {"lines", "events", "jobs"}}: whether it
    can run on a pull request, and what to check when it may not on all of
    them. A workflow with no `pull_request` trigger of its own counts only
    when it is `workflow_call` and a workflow that does trigger on
    `pull_request` calls it from a job (`uses: ./.github/workflows/<file>`).
    That is one level; a deeper chain is not followed, so it fails safe."""
    lines, events, jobs = files[name]["lines"], files[name]["events"], files[name]["jobs"]
    where = f"{name}:{at + 1}"
    blocks, warns = [], []
    job = next((j for j in jobs if j["start"] < at < j["end"]), None)
    conditions = [(step_if(lines, at), "its step")]
    if job:
        conditions.append((job["if"], f"its job {job['id']}"))
    for found, what in conditions:
        if not found:
            continue
        if condition(found[1]) == "false":
            blocks.append(f"the routing-guard step at {where} never runs: {what} has an if: that is false (line {found[0]})")
        else:
            warns.append(f"{name}:{found[0]}: {what} has an if: condition")

    def trigger(owner, event):
        filters = ", ".join(event["filters"])
        if filters:
            warns.append(f"{owner}:{event['line']}: the pull_request trigger has {filters} filters")

    if "pull_request" in events:
        trigger(name, events["pull_request"])
    else:
        callers = []
        if "workflow_call" in events:
            for other, info in sorted(files.items()):
                if other == name or "pull_request" not in info["events"]:
                    continue
                for caller in info["jobs"]:
                    if caller["uses"] == ACTION_DIR + name:
                        callers.append((other, caller))
        usable = []
        for other, caller in callers:
            cwhere = f"job {caller['id']} at {other}:{caller['line']}"
            if caller["if"] and condition(caller["if"][1]) == "false":
                blocks.append(f"the routing-guard step at {where} never runs: {cwhere}, which calls {name}, has an if: that is false")
            else:
                usable.append((other, caller, cwhere))
        for other, caller, cwhere in usable:
            trigger(other, files[other]["events"]["pull_request"])
            if caller["if"]:
                warns.append(f"{other}:{caller['if'][0]}: job {caller['id']}, which calls {name}, has an if: condition")
        if not usable and not callers:
            tail = []
            if "pull_request_target" in events:
                tail.append("it runs on pull_request_target, which runs the base branch's workflow files, so the guard would not check the pull request's own")
            if "workflow_call" in events:
                tail.append(f"{name} is only reusable (workflow_call) and no workflow that runs on pull_request calls it with uses: {ACTION_DIR}{name} (adopt follows one level of calls)")
            if not tail:
                tail.append(f"{name} does not run on pull_request" if events else f"adopt could not read the on: of {name}")
            blocks.append(f"the routing-guard step at {where} does not run on pull requests: " + " and ".join(tail))
    return blocks, warns


def option(values, key, default):
    """The step's `with:` value for `key` as one TSV-safe text: the default
    when the step does not set it, "-" when it sets it to nothing (the guard
    refuses that, and adopt must not read it as the default)."""
    if key not in values:
        return default
    return " ".join(re.split(r"[\s,]+", values[key].strip())) or "-"


def guards(directory):
    """(file:line, status, label, blocking, warnings, events, dependabot,
    fallback, job entries)
    for every step that uses some routing guard. The status is "source" for
    one that is not ACTION_PATH at an exact release tag or a full commit SHA
    (another repository, a branch, a major-only tag), "blocked" for one that
    cannot run on a pull request, and "ok" for a usable guard."""
    files = {}
    for name in workflow_files(directory):
        lines = read_lines(os.path.join(directory, name))
        files[name] = {"lines": lines, "events": parse_triggers(lines), "jobs": parse_jobs(lines)}
    found = []
    for name, info in files.items():
        lines = info["lines"]
        for at, line in enumerate(lines):
            m = USES.match(line)
            value = scalar(m.group(3)) if m else ""
            if line.lstrip().startswith("#") or STEP_MARKER not in value:
                continue
            where = f"{name}:{at + 1}"
            path, _, ref = value.partition("@")
            values = with_values(lines, *step_bounds(lines, at))
            jobs = [e for e in re.split(r"[\s,]+", values.get("jobs", "")) if e]
            label = values.get("label") or DEFAULT_LABEL
            sha = SHA_REF.fullmatch(ref) is not None
            if path.lower() != ACTION_PATH.lower() or not (sha or RELEASE_REF.fullmatch(ref)):
                reason = f"the routing-guard step at {where} uses {value}, but adopt recognizes {ACTION_PATH} at an exact release tag such as {RELEASE}, or at a full commit SHA (docs/adopting.md, step 3)"
                found.append((where, "source", label, [reason], [], DEFAULT_EVENTS, DEFAULT_DEPENDABOT, DEFAULT_FALLBACK, jobs))
                continue
            blocks, warns = check_guard(name, at, files)
            if sha:
                warns.append(f"{where}: pinned to a commit (adopt checks it as it would a release tag)")
            opts = (
                option(values, "events", DEFAULT_EVENTS),
                option(values, "dependabot", DEFAULT_DEPENDABOT),
                option(values, "fallback", DEFAULT_FALLBACK),
            )
            found.append((where, "blocked" if blocks else "ok", label, blocks, warns, *opts, jobs))
    return found


def cache_keys(directory):
    """Cache `key:` and `restore-keys:` text with runner.os and no runner.arch.
    A text heuristic: it does not know which action the key belongs to, only
    that a key built from the OS alone is shared between the hosted x86-64
    runners and the arm64 VM. Block scalars (restore-keys: |) are followed."""
    hits = []
    for name in workflow_files(directory):
        lines = read_lines(os.path.join(directory, name))
        i = 0
        while i < len(lines):
            m = CACHE_KEY.match(lines[i]) if not lines[i].lstrip().startswith("#") else None
            if not m:
                i += 1
                continue
            base, rest = len(m.group(1)), m.group(3)
            checked = [(i, rest)]
            if re.match(r"^([|>][+-]?\d*)?\s*(#.*)?$", rest):
                j = i + 1
                while j < len(lines) and in_block(lines[j], base):
                    if lines[j].strip():
                        checked.append((j, lines[j].strip()))
                    j += 1
                i = j - 1
            for at, text in checked:
                text = re.sub(r"\s+#.*$", "", text)
                if "runner.os" in text and "runner.arch" not in text:
                    hits.append(f"{name}:{at + 1}: {text}")
            i += 1
    return hits


def guard_snippet(label, jobs, events=DEFAULT_EVENTS, dependabot=DEFAULT_DEPENDABOT, fallback=DEFAULT_FALLBACK):
    entries = jobs or ["ci.yml:<job-id>"]
    out = [
        "      - name: Routing guard",
        f"        uses: {ACTION}",
        "        with:",
        "          jobs: |",
    ]
    out += [f"            {e}" for e in entries]
    if label != DEFAULT_LABEL:
        out.append(f"          label: {label}")
    names = [e for e in re.split(r"[\s,]+", events) if e]
    if set(names) != {DEFAULT_EVENTS}:
        out.append(f"          events: {', '.join(names)}")
    if dependabot != DEFAULT_DEPENDABOT:
        out.append(f"          dependabot: {dependabot}")
    if fallback != DEFAULT_FALLBACK:
        out.append(f"          fallback: {fallback}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("guards").add_argument("dir")
    sub.add_parser("cache-keys").add_argument("dir")
    p = sub.add_parser("guard-snippet")
    p.add_argument("--label", default=DEFAULT_LABEL)
    p.add_argument("--events", default=DEFAULT_EVENTS)
    p.add_argument("--dependabot", default=DEFAULT_DEPENDABOT)
    p.add_argument("--fallback", default=DEFAULT_FALLBACK)
    p.add_argument("--jobs", default="")
    sub.add_parser("quote").add_argument("text")
    args = ap.parse_args()

    if args.cmd == "guards":
        for where, status, label, blocks, warns, events, dependabot, fallback, jobs in guards(args.dir):
            joined = [";".join(t.replace(";", ",") for t in texts) or "-" for texts in (blocks, warns)]
            print("\t".join([where, status, label, *joined, events, dependabot, fallback, " ".join(jobs)]))
    elif args.cmd == "cache-keys":
        for hit in cache_keys(args.dir):
            print(hit)
    elif args.cmd == "guard-snippet":
        print(guard_snippet(args.label, [j for j in re.split(r"[\s,]+", args.jobs) if j], args.events, args.dependabot, args.fallback))
    else:
        print(urllib.parse.quote(args.text, safe=""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
