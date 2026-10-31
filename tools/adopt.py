#!/usr/bin/env python3
"""Text helpers for `bin/homefield adopt`, which downloads a repository's
workflow files and needs three things from them: the routing-guard
steps, cache keys that lack the architecture, and the guard step to suggest.
Stdlib only, and no YAML parser: the workflow text is read line by line, which
is enough for the shapes GitHub workflows take and fails safe (a guard it
cannot read counts as no guard, so adopt does not switch the repository on).

A guard is a step that uses ACTION_PATH (the owner and repository compared
without case) at RELEASE, the release whose rules this copy's routing_guard.py
checks, or at a full commit SHA (accepted with a warning), and that can run on
a pull request: see check_guard. Other releases, major-only tags (@v3),
branches and any other ref are not recognized: adopt cannot vouch for rules it
does not have.

  adopt.py guards DIR       one line per step that uses some routing guard:
                            file:line <TAB> status <TAB> label <TAB> blocking
                            <TAB> warnings <TAB> events
                            <TAB> dependabot <TAB> fallback <TAB> arch <TAB> job
                            entries (spaces). status is ok (a usable guard),
                            blocked (a recognized routing-guard step that
                            cannot run on pull requests) or source (not an
                            action adopt recognizes, or a step whose with:
                            adopt cannot read). blocking and warnings
                            are texts joined by ";", or "-" when there are
                            none. events (spaces), dependabot, fallback and
                            arch are the step's `with:` values, or the
                            defaults when it sets none; "-" is a value set to
                            nothing. The job entries
                            come last because they may be empty.
  adopt.py cache-keys DIR   one line per cache key that has runner.os and not
                            runner.arch: file:line: text
  adopt.py guard-snippet [--label L] [--events E] [--dependabot D]
                            [--fallback F] [--jobs a.yml:x,b.yml:y]
                            the guard step to add to a workflow; an option
                            appears only when it is not the default
  adopt.py setup DIR OUT --expression EXPR [--label L] [--events E]
                            [--dependabot D] [--fallback F] [--jobs a.yml:x,...]
                            stage the `homefield adopt --setup` rewrite (route
                            every pull-request job on a GitHub-hosted image,
                            add runner.arch to those files' cache keys, and
                            make the guard list exactly the routed jobs): DIR
                            is read, OUT gets every workflow with the changes
                            applied, and one TAB-separated line is printed per
                            routed job (`ROUTED<TAB>file:job`) and per written
                            file (`FILE<TAB>name`). Exit 1 with the reason on
                            stderr when there is nothing to route.
  adopt.py contents-payload FILE SHA MESSAGE BRANCH
                            the JSON body of a Contents API PUT writing FILE
                            to BRANCH with MESSAGE; SHA is "none" for a new
                            file
  adopt.py quote TEXT       TEXT percent-encoded for a URL path
"""
import argparse
import base64
import json
import os
import re
import shutil
import sys
import urllib.parse

# The release the snippet adopt prints pins, and that docs/adopting.md and the
# README tell consumers to pin; tests/adopt.sh checks that the docs still say
# it. Bump it when a release is cut.
RELEASE = "v0.3.1"
ACTION_PATH = "i2Dev-com/homefield/routing-guard"
ACTION = f"{ACTION_PATH}@{RELEASE}"
DEFAULT_LABEL = "homefield-ci"
# The routing-guard options besides the label, and their defaults.
DEFAULT_EVENTS = "pull_request"
DEFAULT_DEPENDABOT = "hosted"
DEFAULT_FALLBACK = "ubuntu-latest"
# The architecture the guard defaults to, which is the VM adopt sets up:
# bin/homefield refuses a step whose arch is anything else, and checks with the
# step's own value, so what it reports is what CI runs.
DEFAULT_ARCH = "arm64"

# A step or job `uses:`; group 3 is the raw value.
USES = re.compile(r"^(\s*)(-\s+)?uses:\s*(.*?)\s*$")
# An exact release tag other than RELEASE: not recognized, but named as such.
RELEASE_REF = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")
SHA_REF = re.compile(r"[0-9a-fA-F]{40}")
# What a step that uses some routing guard (any owner, any ref) has in `uses:`.
STEP_MARKER = "/routing-guard@"
ACTION_DIR = "./.github/workflows/"
# The workflow `homefield adopt --setup` writes the guard step into when the
# repository has none yet.
SETUP_FILE = "homefield-routing.yml"
# A GitHub-hosted image name as routing_guard.py's HOSTED reads it (keep the
# two in step): what a job must ask for today to be routable by setup.
HOSTED_RUNS = re.compile(
    r"""^(\[\s*)?(['"]?)(ubuntu|windows|macos)-[a-z0-9._-]+\2(?(1)\s*\])$""",
    re.IGNORECASE,
)
# The trigger options after which a pull request may not run the workflow.
FILTERS = ("branches", "branches-ignore", "paths", "paths-ignore")
ON_KEY = re.compile(r"^([\"']?)on\1:\s*(.*?)\s*$")
# A mapping key, plain or quoted (`"continue-on-error": true` is the same key).
KEY = re.compile(r"""^(\s*)(-\s+)?["']?([A-Za-z0-9_-]+)["']?:\s*(.*?)\s*$""")
# A line that opens a block scalar (`key: |`, `- |`, `- key: >-`), as in
# routing_guard.py: group 1 is the indent, 2 the dash, 3 the key.
BLOCK_START = re.compile(r"""^(\s*)(-\s+)?([^\s#][^#]*?:\s+)?(?:[&!]\S*\s+)*[|>][-+0-9]*\s*$""")
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


def block_scalar_lines(lines, keys=None):
    """The indexes of the lines that are the text of a block scalar (a
    `run: |` script, a `with: jobs: |` list): not YAML structure, so a `uses:`
    in one is not a step. Same rule as routing_guard.py: blank, or indented
    deeper than the key that opened it. `keys`, when given, limits this to
    blocks whose opening key is one of them (`run`), leaving other blocks —
    such as a cache step's `restore-keys: |` — out, so their lines stay
    editable."""
    inside = set()
    col = None
    for i, line in enumerate(lines):
        code = line.split("#", 1)[0]
        if col is not None:
            if not line.strip() or indent_of(line) > col:
                inside.add(i)
                continue
            col = None
        start = BLOCK_START.match(code)
        if start and (
            keys is None or (start.group(3) or "").strip().rstrip(":").strip("'\"") in keys
        ):
            col = len(start.group(1)) + (len(start.group(2)) if start.group(2) and start.group(3) else 0)
    return inside


def scalar(value):
    """A single-line YAML scalar: no trailing comment, no quotes."""
    value = re.sub(r"(^|\s+)#.*$", "", value).strip()
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
    """(values, flow) for the step's `with:`: its block keys as {key: text}
    (a block scalar, `|`, `>`, with or without - and +, keeps its lines,
    newline-joined), and flow, the 1-based line of a `with:` written on one
    line (`with: {jobs: ...}`), which is not read, or None."""
    key_indent = None
    for i in range(start, end):
        m = KEY.match(lines[i])
        if m and m.group(3) == "uses":
            key_indent = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
            break
    if key_indent is None:
        return {}, None
    values = {}
    flow = None
    i = start
    while i < end:
        m = KEY.match(lines[i])
        here = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0) if m else -1
        if m and m.group(3) == "with" and here == key_indent and scalar(m.group(4)):
            flow = i + 1
        elif m and m.group(3) == "with" and here == key_indent:
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
    return values, flow


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


def flag(value):
    """How a boolean such as `continue-on-error:` reads: "true" or "false" for
    the literal (`true`, `${{ true }}`), "other" for any expression, which
    adopt cannot evaluate."""
    text = scalar(value)
    m = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", text)
    if m:
        text = m.group(1)
    text = text.strip().lower()
    return text if text in ("true", "false") else "other"


def parse_jobs(lines):
    """The jobs of the workflow: id, line (1-based), first and one-past-last
    line index, the job-level `if:`, `continue-on-error:` and `runs-on:` as
    (line, value), and a job-level `uses:` (a reusable workflow it calls). A
    job-level key sits at the indent of the job's first child; a step's keys
    are deeper."""
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
            job = {"id": m.group(1), "line": i + 1, "start": i, "end": end, "if": None, "coe": None, "uses": None, "runs_on": None}
            child = next((indent_of(lines[k]) for k in range(i + 1, end) if not is_blank(lines[k])), None)
            for k in range(i + 1, end):
                km = KEY.match(lines[k])
                if km and not km.group(2) and len(km.group(1)) == child:
                    if km.group(3) == "if":
                        job["if"] = (k + 1, km.group(4))
                    elif km.group(3) == "continue-on-error":
                        job["coe"] = (k + 1, km.group(4))
                    elif km.group(3) == "uses":
                        job["uses"] = scalar(km.group(4))
                    elif km.group(3) == "runs-on" and job["runs_on"] is None:
                        job["runs_on"] = (k + 1, km.group(4))
            jobs.append(job)
            i = end
            continue
        i += 1
    return jobs


def step_key(lines, at, key):
    """(line, value) of `key:` in the step with its `uses:` on line index
    `at`, or None."""
    start, end = step_bounds(lines, at)
    m = USES.match(lines[at])
    key_indent = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
    for i in range(start, end):
        km = KEY.match(lines[i])
        if km and km.group(3) == key and len(km.group(1)) + (len(km.group(2)) if km.group(2) else 0) == key_indent:
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
    conditions = [(step_key(lines, at, "if"), "its step")]
    if job:
        conditions.append((job["if"], f"its job {job['id']}"))
    for found, what in conditions:
        if not found:
            continue
        if condition(found[1]) == "false":
            blocks.append(f"the routing-guard step at {where} never runs: {what} has an if: that is false (line {found[0]})")
        else:
            warns.append(f"{name}:{found[0]}: {what} has an if: condition")

    # A guard that fails but cannot fail the check is no guard.
    ignored = [(step_key(lines, at, "continue-on-error"), "its step")]
    if job:
        ignored.append((job["coe"], f"its job {job['id']}"))
    for found, what in ignored:
        if not found:
            continue
        kind = flag(found[1])
        if kind == "true":
            blocks.append(f"the routing-guard step at {where} cannot fail the check: {what} has continue-on-error: true (line {found[0]})")
        elif kind == "other":
            warns.append(f"{name}:{found[0]}: {what} has a continue-on-error: condition")

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
        usable, disabled = [], []
        for other, caller in callers:
            cwhere = f"job {caller['id']} at {other}:{caller['line']}"
            if caller["if"] and condition(caller["if"][1]) == "false":
                disabled.append(f"the routing-guard step at {where} never runs: {cwhere}, which calls {name}, has an if: that is false")
            elif caller["coe"] and flag(caller["coe"][1]) == "true":
                disabled.append(f"the routing-guard step at {where} cannot fail the check: {cwhere}, which calls {name}, has continue-on-error: true")
            else:
                usable.append((other, caller, cwhere))
        # One caller that runs is enough: a disabled one beside it is unused.
        if not usable:
            blocks.extend(disabled)
        for other, caller, cwhere in usable:
            trigger(other, files[other]["events"]["pull_request"])
            if caller["if"]:
                warns.append(f"{other}:{caller['if'][0]}: job {caller['id']}, which calls {name}, has an if: condition")
            if caller["coe"] and flag(caller["coe"][1]) == "other":
                warns.append(f"{other}:{caller['coe'][0]}: job {caller['id']}, which calls {name}, has a continue-on-error: condition")
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


def opt_words(text):
    """An option value as a set of words in a fixed order, so `events: push,
    schedule` and `events: schedule push` compare equal the way the guard
    reads them."""
    return " ".join(sorted(t for t in re.split(r"[\s,]+", text or "") if t))


def guards(directory):
    """(file:line, status, label, blocking, warnings, events, dependabot,
    fallback, arch, job entries)
    for every step that uses some routing guard. The status is "source" for
    one that is not ACTION_PATH at RELEASE or a full commit SHA (another
    repository, another release, a branch, a major-only tag), "blocked" for one that
    cannot run on a pull request, and "ok" for a usable guard. A step whose
    `with:` adopt cannot read (written on one line, or a label set to nothing)
    is "source" too: adopt cannot vouch for it. Lines that are the text of a
    block scalar are not steps."""
    files = {}
    for name in workflow_files(directory):
        lines = read_lines(os.path.join(directory, name))
        files[name] = {"lines": lines, "events": parse_triggers(lines), "jobs": parse_jobs(lines)}
    found = []
    for name, info in files.items():
        lines = info["lines"]
        text = block_scalar_lines(lines)
        for at, line in enumerate(lines):
            if at in text:
                continue
            m = USES.match(line)
            value = scalar(m.group(3)) if m else ""
            if line.lstrip().startswith("#") or STEP_MARKER not in value:
                continue
            where = f"{name}:{at + 1}"
            path, _, ref = value.partition("@")
            values, flow = with_values(lines, *step_bounds(lines, at))
            jobs = [e for e in re.split(r"[\s,]+", values.get("jobs", "")) if e]
            label = values["label"] if "label" in values else DEFAULT_LABEL
            sha = SHA_REF.fullmatch(ref) is not None
            if path.lower() != ACTION_PATH.lower() or not (sha or ref == RELEASE):
                reason = f"the routing-guard step at {where} uses {value}, but adopt recognizes {ACTION}, the release this copy of homefield checks with, or a full commit SHA (docs/adopting.md, step 3)"
                if path.lower() == ACTION_PATH.lower() and RELEASE_REF.fullmatch(ref):
                    reason += f". {ref} may have other rules: pin {RELEASE}, or install homefield {ref} (homefield version)"
                found.append((where, "source", label, [reason], [], DEFAULT_EVENTS, DEFAULT_DEPENDABOT, DEFAULT_FALLBACK, DEFAULT_ARCH, jobs))
                continue
            unreadable = None
            if flow:
                unreadable = f"the routing-guard step at {where} has its with: on one line (line {flow}), which adopt does not read. Write each option on its own line under with: (docs/adopting.md, step 3)"
            elif not label:
                unreadable = f"the routing-guard step at {where} sets label: to nothing, which the guard refuses. Remove the line to use {DEFAULT_LABEL}, or name the label (docs/adopting.md, step 3)"
            if unreadable:
                found.append((where, "source", label or "-", [unreadable], [], DEFAULT_EVENTS, DEFAULT_DEPENDABOT, DEFAULT_FALLBACK, DEFAULT_ARCH, jobs))
                continue
            blocks, warns = check_guard(name, at, files)
            if sha:
                warns.append(f"{where}: pinned to a commit (adopt checks it as it would a release tag)")
            opts = (
                option(values, "events", DEFAULT_EVENTS),
                option(values, "dependabot", DEFAULT_DEPENDABOT),
                option(values, "fallback", DEFAULT_FALLBACK),
                option(values, "arch", DEFAULT_ARCH),
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


class SetupError(Exception):
    """Why `homefield adopt --setup` cannot generate a routing pull request;
    its text is what the user sees."""


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def apply_edits(lines, spans):
    """The file text after every (start, end, replacement) span, applied from
    the bottom up so the spans' line indexes stay valid. Refuses overlapping
    spans rather than splicing them: two kinds of edit reaching for the same
    line is a planner bug, not something to merge."""
    by_start = sorted(spans)
    for first, second in zip(by_start, by_start[1:]):
        if first[1] > second[0]:
            raise SetupError(f"the planner produced overlapping edits at lines {first[1]} and {second[0] + 1}")
    out = list(lines)
    for start, end, repl in sorted(spans, key=lambda s: s[0], reverse=True):
        out[start:end] = repl
    return out


def guard_step_lines(lines):
    """Indexes of the `uses:` lines of any routing-guard step (any owner, any
    ref), skipping block-scalar text and comments: the same lines guards()
    looks at."""
    text = block_scalar_lines(lines)
    found = set()
    for at, line in enumerate(lines):
        if at in text or line.lstrip().startswith("#"):
            continue
        m = USES.match(line)
        if m and STEP_MARKER in scalar(m.group(3)):
            found.add(at)
    return found


def run_script_lines(lines):
    """Indexes of the text of `run: |` scripts. A `key:` line inside one is
    script text rather than a cache step's option, so setup leaves it alone;
    the block under `restore-keys: |` is the option itself and stays editable.
    """
    return block_scalar_lines(lines, ("run",))


def guard_jobs_edit(lines, at, entries):
    """(start, end, replacement) that makes the `jobs:` list of the
    routing-guard step whose `uses:` is on line index `at` hold exactly
    `entries`, or None when the step has no `with:` or `jobs:` this rewrite
    can keep. A `jobs: |` block keeps its own entry indentation; an inline
    `jobs: a.yml:x` becomes the block form, which is what adopt reads."""
    start, end = step_bounds(lines, at)
    m = USES.match(lines[at])
    key_indent = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
    i, at_with = start, None
    while i < end:
        km = KEY.match(lines[i])
        here = len(km.group(1)) + (len(km.group(2)) if km.group(2) else 0) if km else -1
        if km and km.group(3) == "with" and here == key_indent:
            at_with = i
            break
        i += 1
    if at_with is None or scalar(lines[at_with].split(":", 1)[1]):
        return None  # no with:, or `with: {…}` on one line
    child = jobs_at = rest = None
    i = at_with + 1
    while i < end:
        if is_blank(lines[i]):
            i += 1
            continue
        ind = indent_of(lines[i])
        if ind <= key_indent:
            break
        if child is None:
            child = ind
        km = KEY.match(lines[i])
        if ind == child and km and km.group(3) == "jobs":
            jobs_at, rest = i, km.group(4)
            break
        i += 1
    if jobs_at is None:
        return None
    if re.match(r"^[|>][+-]?\d*\s*(#.*)?$", rest):
        entry_indent = next(
            (indent_of(lines[k]) for k in range(jobs_at + 1, end) if not is_blank(lines[k]) and indent_of(lines[k]) > child),
            child + 2,
        )
        last = k = jobs_at + 1
        while k < end and (is_blank(lines[k]) or indent_of(lines[k]) > child):
            if not is_blank(lines[k]):
                last = k
            k += 1
        return (jobs_at, last + 1, [lines[jobs_at]] + [" " * entry_indent + e for e in entries])
    if scalar(rest):
        return (jobs_at, jobs_at + 1, [" " * child + "jobs: |"] + [" " * (child + 2) + e for e in entries])
    return None  # a jobs: list continued on following lines in another form


def routing_workflow(label, jobs, events, dependabot, fallback):
    """The workflow `adopt --setup` creates when the repository has no guard:
    one job, on every pull request, that checks out and runs the guard. The
    job itself stays on a GitHub-hosted runner: it is the check, not a
    routed job."""
    return "\n".join(
        [
            "# Checks the routing to the local HomeField runner (docs/adopting.md).",
            "# Created by `homefield adopt --setup`.",
            "name: HomeField routing",
            "on:",
            "  pull_request:",
            "",
            "jobs:",
            "  routing:",
            "    runs-on: ubuntu-latest",
            "    steps:",
            "      - uses: actions/checkout@v5",
            guard_snippet(label, jobs, events, dependabot, fallback),
            "",
        ]
    )


def check_guard_options(row, label, events, dependabot, fallback):
    """Refuse a setup run whose flags disagree with the guard already in the
    repository: setup only lists jobs, it does not re-route on another label
    or with another fallback. A guard on another architecture is refused too,
    as plain adopt refuses it: there is no flag for it, the VM is arm64."""
    where, _status, glabel, _blocks, _warns, gevents, gdependabot, gfallback, garc, _jobs = row
    if garc != DEFAULT_ARCH:
        raise SetupError(
            f"the routing-guard step at {where} uses arch {garc}, but this VM is {DEFAULT_ARCH}: "
            "a guard for another architecture routes its jobs to a runner this Mac does not have (docs/adopting.md, step 3)"
        )
    for opt, got, want in (("label", glabel, label), ("events", gevents, events), ("dependabot", gdependabot, dependabot), ("fallback", gfallback, fallback)):
        if opt_words(got) != opt_words(want):
            raise SetupError(
                f"the routing-guard step at {where} uses {opt} {got}, but this run asks for {want}: setup does not change a guard's options; "
                f"pass --{opt} {got}, or edit the guard (docs/adopting.md, step 3)"
            )


def routable_jobs(info, expression):
    """The jobs of one workflow that setup would route: not a reusable
    workflow call, no always-false `if:`, and a runs-on that already carries
    the canonical expression or asks for a single GitHub-hosted image today —
    except a job that runs the guard, which keeps the runner it was given."""
    out = []
    for job in info["jobs"]:
        if job["uses"] or (job["if"] and condition(job["if"][1]) == "false") or not job["runs_on"]:
            continue
        value = scalar(job["runs_on"][1])
        if value == expression:
            out.append(job)
            continue
        if any(job["start"] < g < job["end"] for g in info["guards"]):
            continue
        if HOSTED_RUNS.match(value):
            out.append(job)
    return out


def setup_plan(directory, out, expression, label, events, dependabot, fallback, only):
    """Stage the `homefield adopt --setup` rewrite of the workflows in DIR into
    OUT: every job of a workflow that runs on pull requests that today asks
    for a GitHub-hosted image gets the canonical expression (with a comment
    pointing at docs/adopting.md), the `runner.os`-only cache keys of the
    routed files get `${{ runner.arch }}`, and the routing guard lists exactly
    the routed jobs — its `jobs:` block updated where a usable guard exists,
    otherwise `.github/workflows/homefield-routing.yml` created. OUT keeps
    every file, changed or not, so routing_guard.py can check the result
    before anything is sent. `only`, when not empty, is the set of file:job
    entries to route instead of all of them. Returns (routed, written), where
    written names the files that differ or are new."""
    files = {}
    for name in workflow_files(directory):
        lines = read_lines(os.path.join(directory, name))
        files[name] = {
            "lines": lines,
            "events": parse_triggers(lines),
            "jobs": parse_jobs(lines),
            "guards": guard_step_lines(lines),
            "scripts": run_script_lines(lines),
        }
    rows = list(guards(directory))
    usable = [row for row in rows if row[1] == "ok"]
    sources = [row for row in rows if row[1] == "source"]
    if len(usable) > 1:
        raise SetupError("there is more than one routing-guard step that runs on pull requests; route the jobs by hand (docs/adopting.md, step 3)")
    if sources:
        # A guard this copy does not recognize would make plain adopt refuse
        # the merged tree, so setup refuses here instead of adding a second
        # guard next to it.
        raise SetupError(
            "; ".join(reason for row in sources for reason in row[3])
            + " setup does not change a guard step it cannot recognize; pin or remove that step, then run again"
        )
    if usable:
        check_guard_options(usable[0], label, events, dependabot, fallback)

    routed = []
    edits = {}

    def edit(name, span):
        edits.setdefault(name, []).append(span)

    for name in sorted(files):
        info = files[name]
        if re.search(r"[\s,]", name):
            # The guard lists jobs as file:job in a text list split on spaces
            # and commas, so a job of such a file can never be listed — it
            # must stay hosted (that is also why adopt --jobs refuses it).
            if routable_jobs(info, expression):
                print(
                    f"setup: {name}: its jobs are not routed: the file name has a space or comma, which a guard jobs: list cannot hold (docs/adopting.md, step 1)",
                    file=sys.stderr,
                )
            continue
        pr_file = "pull_request" in info["events"]
        for job in routable_jobs(info, expression):
            key = f"{name}:{job['id']}"
            value = scalar(job["runs_on"][1])
            if value == expression:
                # Already opted in: the guard's list is exact, so this job
                # stays listed whatever --jobs asks for and whichever events
                # its workflow runs on.
                routed.append(key)
                continue
            if not pr_file or (only and key not in only):
                continue
            routed.append(key)
            line = job["runs_on"][0]
            indent = " " * indent_of(info["lines"][line - 1])
            edit(name, (line - 1, line, [
                f"{indent}# Routed to the local HomeField runner (docs/adopting.md)",
                f"{indent}runs-on: {expression}",
            ]))
    routed = sorted(dict.fromkeys(routed))
    if only:
        missing = sorted(set(only) - set(routed))
        if missing:
            raise SetupError(
                "nothing to route: " + ", ".join(missing)
                + " cannot be routed — it is not a job of a workflow that runs on pull requests carrying"
                " a GitHub-hosted runs-on, or already carrying the expression; no pull request was generated"
            )
    if not routed:
        raise SetupError("nothing to route: no job in a workflow that runs on pull requests carries a GitHub-hosted runs-on (docs/adopting.md, step 1)")

    routed_files = {key.split(":", 1)[0] for key in routed}
    for hit in cache_keys(directory):
        name, _, rest = hit.partition(":")
        if name not in routed_files:
            continue
        at = int(rest.split(":", 1)[0]) - 1
        info = files[name]
        if at in info["scripts"]:
            continue  # key-like text inside a run: script is not a cache step
        old = info["lines"][at]
        new = re.sub(r"\$\{\{\s*runner\.os\s*\}\}", "${{ runner.os }}-${{ runner.arch }}", old, count=1)
        if new != old:
            edit(name, (at, at + 1, [new]))

    guard_new = None
    if usable:
        where = usable[0][0]
        gfile, _, gline = where.rpartition(":")
        span = guard_jobs_edit(files[gfile]["lines"], int(gline) - 1, routed)
        if span is None:
            raise SetupError(f"the routing-guard step at {where} does not have a jobs: list setup can rewrite; edit its jobs: list by hand (docs/adopting.md, step 3)")
        if files[gfile]["lines"][span[0]:span[1]] != list(span[2]):
            edit(gfile, span)
    else:
        guard_new = SETUP_FILE
        if guard_new in files:
            raise SetupError(f".github/workflows/{guard_new} exists but has no routing-guard step; route by hand (docs/adopting.md, step 3)")

    if not edits and guard_new is None:
        raise SetupError("nothing to route: every job that could route already carries the expression, and the guard already lists it")

    os.makedirs(out, exist_ok=True)
    for name in sorted(files):
        if name in edits:
            write_lines(os.path.join(out, name), apply_edits(files[name]["lines"], edits[name]))
        else:
            shutil.copyfile(os.path.join(directory, name), os.path.join(out, name))
    written = sorted(edits)
    if guard_new:
        write_lines(os.path.join(out, guard_new), routing_workflow(label, routed, events, dependabot, fallback).splitlines())
        written.append(guard_new)
    return routed, written


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
    s = sub.add_parser("setup")
    s.add_argument("dir")
    s.add_argument("out")
    s.add_argument("--expression", required=True)
    s.add_argument("--label", default=DEFAULT_LABEL)
    s.add_argument("--events", default=DEFAULT_EVENTS)
    s.add_argument("--dependabot", default=DEFAULT_DEPENDABOT)
    s.add_argument("--fallback", default=DEFAULT_FALLBACK)
    s.add_argument("--jobs", default="")
    c = sub.add_parser("contents-payload")
    c.add_argument("file")
    c.add_argument("sha")
    c.add_argument("message")
    c.add_argument("branch")
    sub.add_parser("quote").add_argument("text")
    args = ap.parse_args()

    if args.cmd in ("guards", "cache-keys", "setup") and not os.path.isdir(args.dir):
        print(f"adopt.py: not a directory: {args.dir}", file=sys.stderr)
        return 1

    if args.cmd == "guards":
        for where, status, label, blocks, warns, events, dependabot, fallback, arch, jobs in guards(args.dir):
            joined = [";".join(t.replace(";", ",") for t in texts) or "-" for texts in (blocks, warns)]
            print("\t".join([where, status, label, *joined, events, dependabot, fallback, arch, " ".join(jobs)]))
    elif args.cmd == "cache-keys":
        for hit in cache_keys(args.dir):
            print(hit)
    elif args.cmd == "guard-snippet":
        print(guard_snippet(args.label, [j for j in re.split(r"[\s,]+", args.jobs) if j], args.events, args.dependabot, args.fallback))
    elif args.cmd == "setup":
        try:
            routed, written = setup_plan(
                args.dir,
                args.out,
                args.expression,
                args.label,
                args.events,
                args.dependabot,
                args.fallback,
                {j for j in re.split(r"[\s,]+", args.jobs) if j},
            )
        except SetupError as err:
            print(err, file=sys.stderr)
            return 1
        for key in routed:
            print(f"ROUTED\t{key}")
        for name in written:
            print(f"FILE\t{name}")
    elif args.cmd == "contents-payload":
        with open(args.file, "rb") as fh:
            body = {
                "message": args.message,
                "content": base64.b64encode(fh.read()).decode("ascii"),
                "branch": args.branch,
            }
        if args.sha != "none":
            body["sha"] = args.sha
        print(json.dumps(body))
    else:
        print(urllib.parse.quote(args.text, safe=""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
